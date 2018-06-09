use v5.24.0;
package Synergy::Reactor::Help;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor', 'Synergy::Role::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first uniq);

__PACKAGE__->add_command(
  help => {
    help => [
      "help -- see a list of known help topics",
      "help TOPIC -- learn about a topic",
    ]
  }
);

sub cmd_help ($self, $event, $arg) {
  $event->mark_handled;

  my @help = map {; $_->help_entries }
             map {; $_->listeners }
             $self->hub->reactors;

  unless ($arg->{rest}) {
    my $help_str = join q{, }, uniq sort map {; $_->{title} } @help;
    $event->reply("Help entries: $help_str");
    return;
  }

  @help = grep {; fc $_->{title} eq fc $arg->{rest} } @help;

  unless (@help) {
    $event->reply("Sorry, I don't have any help on that topic.");
    return;
  }

  $event->reply(join qq{\n}, sort map {; $_->{text} } @help);
  return;
}

1;
