use v5.24.0;
package Synergy::Role::EasyListening;

use MooseX::Role::Parameterized;

use experimental qw(signatures);
use namespace::clean;

role {
  # A new collection for every composing reactor! -- rjbs, 2018-04-16
  my @listeners;

  method add_listener => sub ($self, $listener) {
    if (blessed $listener) {
      push @listeners, $listener;
    } else {
      push @listeners, Synergy::Listener->new($listener);
    }
  };

  method add_command => sub ($self, $name, $x1, $x2 = undef) {
    my ($code, $arg) = defined $x2 ? ($x2, $x1) : ($x1, $x2);

    my $listener = Synergy::Listener->new({
      name      => $name,
      exclusive => 1,
      predicate => sub ($self, $e) {
        return $e->was_targeted && $e->text =~ /\A\Q$name\E(\s|\z)/ni;
      },
      method    => sub ($self, $e, $rch) {
        my ($cmd, $rest) = split /\s+/, $e->text, 2;
        $code->($self, $e, $rch, { cmd => $cmd, rest => $rest });
      },
      help_entries => [
        $arg->{help} ? { title => $name, text => $arg->{help} } : ()
      ],
    });

    push @listeners, $listener;
  };

  method listeners => sub ($self) {
    return @listeners;
  };
};

1;
