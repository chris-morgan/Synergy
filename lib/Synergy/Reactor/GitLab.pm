use v5.24.0;
package Synergy::Reactor::GitLab;

use Moose;
with 'Synergy::Role::Reactor',
     'Synergy::Role::HasPreferences';

use experimental qw(signatures);
use namespace::clean;
use DateTime::Format::ISO8601;
use DateTimeX::Format::Ago;
use Digest::MD5 qw(md5_hex);
use JSON 2 ();
use List::Util qw(uniq);
use MIME::Base64;
use YAML::XS;
use Synergy::Logger '$Logger';

my $JSON = JSON->new->utf8->canonical;

has api_token => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has api_uri => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has url_base => (
  is      => 'ro',
  isa     => 'Str',
  lazy    => 1,
  default => sub { $_[0]->api_uri =~ s|/api$||r; },
);

has project_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has user_config => (
  is => 'ro',
  isa => 'HashRef',
  traits  => [ 'Hash' ],
  lazy => 1,
  default => sub { {} },
  writer => '_set_user_config',
  handles => {
    set_user   => 'set',
    user_pairs => 'kv',
  },
);

has project_shortcuts => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  writer => '_set_shortcuts',
  handles => {
    is_known_project => 'exists',
    project_named    => 'get',
    all_shortcuts    => 'keys',
  }
);

has _shortcut_lookup => (
  is => 'ro',
  isa => 'HashRef',
  traits => ['Hash'],
  lazy => 1,
  default => sub ($self) {
    my %lookup;
    for my $shortcut ($self->all_shortcuts) {
      my $proj = $self->project_named($shortcut);
      $lookup{ $proj->{name} } = $shortcut;
    }
    return \%lookup;
  },
  handles => {
    shortcut_for => 'get',
  },
);

after register_with_hub => sub ($self, @) {
  if (my $state = $self->fetch_state) {
    # Backcompat: the user config used to be the only thing in state, and it's
    # not any more. This can go away eventually -- michael, 2018-08-13
    my $user_config = exists $state->{users} ? $state->{users} : $state;
    $self->_set_user_config($user_config);

    if (my $prefs = $state->{preferences}) {
      $self->_load_preferences($prefs);
    }

    for my $pair ($self->user_pairs) {
      my ($username, $uconfig) = @$pair;
      $self->hub->user_directory->reload_user($username, $uconfig);
    }

    my $repo_state = $state->{repos} // {};
    $self->_set_shortcuts($repo_state);
  }
};

sub start ($self) {
  my $timer = IO::Async::Timer::Countdown->new(
    delay => 60,
    on_expire => sub {
      $Logger->log("fetching user config from GitLab");

      my ($ok, $errors) = $self->_reload_all;

      $Logger->log([
        "error doing initial user config load from GitLab: %s",
        $errors,
      ]) unless $ok;

      my ($repo_ok, $repo_error) = $self->_reload_repos;
    }
  );

  $timer->start;
  $self->hub->loop->add($timer);
}

sub state ($self) {
  return {
    users => $self->user_config,
    repos => $self->project_shortcuts,
    preferences => $self->user_preferences,
  };
}

sub listener_specs {
  return (
    {
      name      => 'reload',
      method    => 'handle_reload',
      exclusive => 1,
      predicate => sub ($self, $e) {
        $e->was_targeted &&
        $e->text =~ /^reload\s+(?!shortcuts)/in;
      },
    },
    {
      name => 'mention-mr',
      method => 'handle_merge_request',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /(^|\s)[a-z]+!\d+(\W|$)/in;

        my $base = $self->reactor->url_base;
        return 1 if $e->text =~ /\Q$base\E.*?merge_requests/;
      }
    },
    {
      name => 'mr-report',
      method => 'handle_mr_report',
      predicate => sub ($self, $e) {
        $e->was_targeted && $e->text =~ /^\s*mr report\s*\z/i;
      }
    },
    {
      name => 'mention-commit',
      method => 'handle_commit',
      predicate => sub ($self, $e) {
        return $e->text =~ /(^|\s)[a-z]+\@[0-9a-f]{7,40}(\W|$)/in;
      }
    },
  );
}

sub handle_reload ($self, $event) {
  $event->mark_handled;

  return $event->reply("Sorry, I don't know who you are.")
    unless $event->from_user;

  my $text = $event->text;
  my ($what) = $text =~ /^\s*reload\s+(.*)/i;
  $what &&= lc $what;

  $what =~ s/^\s*|\s*$//g;

  return $self->handle_my_config($event)  if $what eq 'my config';
  return $self->handle_all_config($event) if $what eq 'all user config';
  return $self->handle_repos($event)      if $what eq 'repos';

  return $event->reply("I don't know how to reload <$what>");
}

sub handle_my_config ($self, $event) {
  my $username = $event->from_user->username;
  my ($ok, $error) = $self->_update_user_config($username);

  return $event->reply("your configuration has been reloaded") if $ok;
  return $event->reply("error reloading config: $error");
}

sub handle_all_config ($self, $event) {
  return $event->reply("Sorry, only the master user can do that")
    unless $event->from_user->is_master;

  my ($ok, $errors) = $self->_reload_all;
  return $event->reply("user config reloaded") if $ok;

  my $who = join ', ', sort @$errors;
  return $event->reply("encounted errors while reloading following users: $who");
}

sub handle_repos ($self, $event) {
  my ($ok, $error) = $self->_reload_all;
  return $event->reply("repo shortcuts reloaded") if $ok;
  return $event->reply("encounted error while reloading repos: $error");
}

sub _reload_all ($self) {
  my @errors;

  for my $username ($self->hub->user_directory->usernames) {
    my ($ok, $error) = $self->_update_user_config($username);
    next if $ok;

    push @errors, "$username: $error";
    $Logger->log([
      "error while fetching user config for %s: %s",
      $username,
      $error
    ]);
  }

  return (1, undef) unless @errors;
  return (0, \@errors);
}

sub _update_user_config ($self, $username) {
  my $url = sprintf("%s/v4/projects/%s/repository/files/%s.yaml?ref=master",
    $self->api_uri,
    $self->project_id,
    $username,
  );

  my $res = $self->hub->http_get(
    $url,
    'PRIVATE-TOKEN' => $self->api_token,
  );

  unless ($res->is_success) {
    if ($res->code == 404) {
      $self->hub->user_directory->reload_user($username, {});
      return (undef, "no config in git");
    }

    $Logger->log([ "Error: %s", $res->as_string ]);
    return (undef, "error retrieving config")
  }

  my $content = eval {
    decode_base64( $JSON->decode( $res->decoded_content )->{content} );
  };

  return (undef, "error with GitLab response") unless $content;

  my $uconfig = eval { YAML::XS::Load($content) };
  return (undef, "error with YAML in config") unless $uconfig;

  $self->hub->user_directory->reload_user($username, $uconfig);
  $self->hub->load_preferences_from_user($username);
  $self->set_user($username => $uconfig);
  $self->save_state;
  return (1, undef);
}

sub _reload_repos ($self) {
  my $url = sprintf("%s/v4/projects/%s/repository/files/repos.yaml?ref=master",
    $self->api_uri,
    $self->project_id,
  );

  my $res = $self->hub->http_get(
    $url,
    'PRIVATE-TOKEN' => $self->api_token,
  );

  unless ($res->is_success) {
    $Logger->log([ "Error: %s", $res->as_string ]);
    return (undef, "error retrieving config")
  }

  my $content = eval {
    decode_base64( $JSON->decode( $res->decoded_content )->{content} );
  };

  return (undef, "error with GitLab response") unless $content;

  my $repos = eval { YAML::XS::Load($content) };
  return (undef, "error with YAML in config") unless $repos;

  $self->_set_shortcuts($repos);
  $self->save_state;
}

sub id_for_project ($self, $shortcut) {
  return unless $self->is_known_project($shortcut);
  return $self->project_named($shortcut)->{id};
}

sub name_for_project ($self, $shortcut) {
  return unless $self->is_known_project($shortcut);
  return $self->project_named($shortcut)->{name};
}

sub handle_merge_request ($self, $event) {
  my @mrs = $event->text =~ /(?:^|\s)([a-z]+!\d+)(?=\W|$)/g;
  state $dt_formatter = DateTimeX::Format::Ago->new(language => 'en');

  state $base = $self->url_base;
  my %found = $event->text =~ m{\Q$base\E/(.*?/.*?)/merge_requests/([0-9]+)};

  for my $key (keys %found) {
    my $shortcut = $self->shortcut_for($key);
    next unless $shortcut;
    push @mrs, $shortcut . q{!} . $found{$key};
  }

  @mrs = uniq @mrs;

  for my $mr (@mrs) {
    my ($proj, $num) = split /!/, $mr, 2;

    next unless $self->is_known_project($proj);

    my $url = sprintf("%s/v4/projects/%d/merge_requests/%d",
      $self->api_uri,
      $self->id_for_project($proj),
      $num,
    );

    my $res = $self->hub->http_get(
      $url,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    unless ($res->is_success) {
      $Logger->log([ "Error: %s", $res->as_string ]);
      next;
    }

    my $data = $JSON->decode($res->decoded_content);

    my $state = $data->{state};

    my $reply = "$mr [$state, created by $data->{author}->{username}]: ";
    $reply   .= "$data->{title} ($data->{web_url})";

    my $color = $state eq 'opened' ? '#1aaa4b'
              : $state eq 'merged' ? '#1f78d1'
              : $state eq 'closed' ? '#db3b21'
              : undef;

    my @fields;
    if ($state eq 'opened') {
      my $assignee = $data->{assignee}{name} // 'nobody';
      push @fields, {
        title => "Assigned",
        value => $assignee,
        short => \1
      };

      my $created = DateTime::Format::ISO8601->parse_datetime($data->{created_at});

      push @fields, {
        title => "Opened",
        value => $dt_formatter->format_datetime($created),
        short => \1,
      };
    } else {
      my $date = $data->{merged_at} // $data->{closed_at};
      my $dt = DateTime::Format::ISO8601->parse_datetime($date);
      push @fields, {
        title => ucfirst $state,
        value => $dt_formatter->format_datetime($dt),
        short => \1,
      };
    }

    my $slack = {
      text        => "",
      attachments => $JSON->encode([{
        fallback    => "$mr: $data->{title} [$data->{state}] $data->{web_url}",
        author_name => $data->{author}->{name},
        author_icon => $data->{author}->{avatar_url},
        title       => "$mr: $data->{title}",
        title_link  => "$data->{web_url}",
        color       => $color,
        fields      => \@fields,
      }]),
    };

    $event->reply($reply, { slack => $slack });
    $event->mark_handled;
  }
}

sub handle_commit ($self, $event) {
  my @commits = $event->text =~ /(?:^|\s)([a-z]+\@[0-9a-fA-F]{7,40})(?=\W|$)/g;

  for my $commit (@commits) {
    my ($proj, $sha) = split /\@/, $commit, 2;

    next unless $self->is_known_project($proj);

    my $url = sprintf("%s/v4/projects/%d/repository/commits/%s",
      $self->api_uri,
      $self->id_for_project($proj),
      $sha,
    );

    my $res = $self->hub->http_get(
      $url,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    unless ($res->is_success) {
      $Logger->log([ "Error: %s", $res->as_string ]);
      next;
    }

    my $data = $JSON->decode($res->decoded_content);

    my $commit_url = sprintf("%s/%s/commit/%s",
      $self->url_base,
      $self->name_for_project($proj),
      $data->{short_id},
    );

    my $reply = "$commit [$data->{author_name}]: $data->{title} ($commit_url)";
    my $slack = sprintf("<%s|%s>: %s [%s]",
      $commit_url,
      $commit,
      $data->{title},
      $data->{author_name},
    );

    my $author_icon = sprintf("https://www.gravatar.com/avatar/%s?s=16",
      md5_hex($data->{author_email}),
    );

    $slack = {
      text        => '',
      attachments => $JSON->encode([{
        fallback    => "$data->{author_name}: $data->{short_id} $data->{title} $commit_url",
        author_name => $data->{author_name},
        author_icon => $author_icon,
        text        => "<$commit_url|$data->{short_id}> $data->{title}",
      }]),
    };

    $event->reply($reply, { slack => $slack });
    $event->mark_handled;
  }
}

sub handle_mr_report ($self, $event) {
  $event->mark_handled;

  my $user_id = $self->get_user_preference($event->from_user, 'user-id');

  unless (defined $user_id) {
    return $event->reply("I can't check your MR status, you don't have an user-id preference set!");
  }

  my %result;

  for my $pair (
    # TODO: Cope with pagination for real. -- rjbs, 2018-08-17
    [ filed => sprintf("%s/v4/merge_requests/?scope=all&author_id=%s&state=opened&per_page=100",
        $self->api_uri, $user_id) ],
    [ assigned => sprintf("%s/v4/merge_requests/?scope=all&assignee_id=%s&state=opened&per_page=100",
        $self->api_uri, $user_id) ],
  ) {
    my ($type, $uri) = @$pair;

    my $res = $self->hub->http_get(
      $uri,
      'PRIVATE-TOKEN' => $self->api_token,
    );

    unless ($res->is_success) {
      $Logger->log([ "Error: %s", $res->as_string ]);
      return $event->reply(
        "Something when wrong when trying to get your $type merge requests.",
      );
    }

    my $data = $JSON->decode($res->decoded_content);
    for my $mr (@$data) {
      $mr->{_isBacklogged} = 1
        if grep {; lc $_ eq 'backlogged' } $mr->{labels}->@*;

      $mr->{_isSelfAssigned} = 1
        if $mr->{assignee} && $mr->{assignee}{id} == $user_id;
    }
    $result{$type} = $data;
  }

  my $template = <<'EOT';
Open merge requests you filed: %s (%s backlogged)
Open merge request assigned to you: %s (%s backlogged)
Open merge requests in both groups: %s (%s backlogged)
EOT

  $event->reply(sprintf
    $template,
    0 + $result{filed}->@*,
    0 + (grep { $_->{_isBacklogged} } $result{filed}->@*),
    0 + $result{assigned}->@*,
    0 + (grep { $_->{_isBacklogged} } $result{assigned}->@*),
    0 + (grep { $_->{_isSelfAssigned} } $result{filed}->@*),
    0 + (grep { $_->{_isSelfAssigned} && $_->{_isBacklogged} }
          $result{filed}->@*),
  );
}

__PACKAGE__->add_preference(
  name      => 'user-id',
  validator => sub ($value) {
    return $value if $value =~ /\A[0-9]+\z/;
    return (undef, "Your user-id must be a positive integer.")
  },
  default   => undef,
);

1;
