use v5.24.0;
package Synergy::Reactor::Help;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor', 'Synergy::Role::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first uniq);

__PACKAGE__->add_listener({
  name      => 'help',
  method    => 'handle_help',
  exclusive => 1,
  predicate => sub ($self, $e) { $e->was_targeted && $e->text eq 'help' },
  help_entries => [
    { title => "help", text => "provides help with using the bot" },
  ],
});

sub handle_help ($self, $event, $rch) {
  $event->mark_handled;

  my @help = map {; $_->help_entries }
             map {; $_->listeners }
             $self->hub->reactors;

  my $help_str = join q{, }, sort map {; $_->{title} } @help;
  $rch->reply("Help entries: $help_str");
  return;
}

1;
