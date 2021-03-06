use v5.24.0;
package Synergy::Role::HasPreferences;

use MooseX::Role::Parameterized;

use Scalar::Util qw(blessed);
use Try::Tiny;
use utf8;

use experimental qw(signatures);
use namespace::clean;

parameter namespace => (
  isa => 'Str',
);

role {
  my $p = shift;

  has preference_namespace => (
    is => 'ro',
    isa => 'Str',
    lazy => 1,
    default => sub { $p->namespace // $_[0]->name },
  );

  my %pref_specs;

  # This could be better, but we'll access it through methods to keep the
  # dumbness isolated.
  # {
  #   alice => { pref1 => val1, pref2 => val2, ... },
  #   bob   => { ... },
  # }
  my %all_user_prefs;

  method user_preferences    => sub             { +{ %all_user_prefs }      };
  method _load_preferences   => sub ($, $prefs) { %all_user_prefs = %$prefs };
  method preference_names    => sub             { sort keys %pref_specs     };
  method is_known_preference => sub ($, $name)  { exists $pref_specs{$name} };

  method describe_user_preference => sub ($self, $user, $pref_name) {
    my $val = try { $self->get_user_preference($user, $pref_name) };

    my $full_name = $self->preference_namespace . q{.} . $pref_name;
    my $desc = $pref_specs{$pref_name}->{describer}->( $val );
    return "$full_name: $desc";
  };

  # spec is (for now) {
  #   name      => 'pref_name',
  #   default   => value,
  #   validator => sub ($val) {},
  #   describer => sub ($val) {},
  #   after_set => sub ($self, $username, $value) {},
  # }
  #
  # The validator sub will receive the raw text value from the user, and is
  # expected to return an actual value. If the validator returns undef, we'll
  # give a reasonable error message.
  method add_preference => sub ($class, %spec) {
    confess("Missing required pref. attribute 'name'") unless $spec{name};
    confess("Missing required pref. attribute 'validator'") unless $spec{validator};

    my $name = delete $spec{name};

    $spec{describer} //= sub ($value) { return $value // '<undef>' };
    $spec{after_set} //= sub ($self, $username, $value) {};

    $pref_specs{$name} = \%spec;
  };


  method set_preference => sub ($self, $event, $pref_name, $value) {
    unless ($self->is_known_preference($pref_name)) {
      my $full_name = $self->preference_namespace . q{.} . $pref_name;
      $event->reply("I don't know about the $full_name preference");
      $event->mark_handled;
      return;
    }

    my $spec = $pref_specs{ $pref_name };
    my ($actual_value, $err) = $spec->{validator}->($value);

    my $full_name = $self->preference_namespace . q{.} . $pref_name;

    if ($err) {
      $event->reply("I don't understand the value you gave for $full_name: $err.");
      $event->mark_handled;
      return;
    }

    my $user = $event->from_user;
    my $got = $self->set_user_preference($user, $pref_name, $actual_value);
    my $desc = $self->describe_user_preference($user, $pref_name);

    $event->reply("Your $full_name setting is now $desc.");
    $event->mark_handled;
  };

  method user_has_preference => sub ($self, $user, $pref_name) {
    my $username = blessed $user ? $user->username : $user;
    my $user_prefs = $all_user_prefs{$username};
    return exists $user_prefs->{$pref_name} && defined $user_prefs->{$pref_name};
  };

  method get_user_preference => sub ($self, $user, $pref_name) {
    die 'unknown pref' unless $self->is_known_preference($pref_name);

    my $username = blessed $user ? $user->username : $user;
    my $user_prefs = $all_user_prefs{$username};

    return unless $user_prefs && exists $user_prefs->{$pref_name};

    return $user_prefs->{$pref_name};
  };

  method set_user_preference => sub ($self, $user, $pref_name, $value) {
    die 'unknown pref' unless $self->is_known_preference($pref_name);

    my $username = blessed $user ? $user->username : $user;
    my $spec = $pref_specs{ $pref_name };

    $all_user_prefs{$username} //= {};

    my $uprefs = $all_user_prefs{$username};
    $uprefs->{$pref_name} = $value // $spec->{default};

    $spec->{after_set}->($self, $username, $value);

    $self->save_state;

    return $value;
  };
};

1;
