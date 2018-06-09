use v5.24.0;
package Synergy::Reactor::Who;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor', 'Synergy::Role::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

use Synergy::Logger '$Logger';

__PACKAGE__->add_command(
  who => { help => "who is USER -- look up a user by name" },
  'handle_who'
);

sub handle_who ($self, $event, $arg) {
  my $what = $arg->{rest};

  return unless length $what && $what =~ s/\A(is|am|are)\s+//n;

  $what =~ s/\s*\?*\z//;

  $event->mark_handled;

  if ($what =~ /\A(you|synergy)\s*\z/i) {
    return $event->reply(
        qq!I am Synergy, a holographic computer designed to be the ultimate !
      . qq!audio-visual entertainment synthesizer.  I also help out with the !
      . qq!timekeeping.!
    );
  }

  my $who = $self->resolve_name($what, $event->from_user);
  return $event->reply(qq!I don't know who "$what" is.!) if ! $who;

  my $whois = sprintf "%s (%s)", $who->username, $who->realname;

  if ($what eq $who->username) {
    return $event->reply(qq{"$what" is $whois.});
  }

  $event->reply(qq["$what" is an alias for $whois.]);
}

1;
