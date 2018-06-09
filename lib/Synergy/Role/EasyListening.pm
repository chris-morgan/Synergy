use v5.24.0;
package Synergy::Role::EasyListening;

use MooseX::Role::Parameterized;

use experimental qw(signatures);
use Params::Util qw(_HASHLIKE _CODELIKE);
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

  method add_command => sub {
    my $self = shift;
    my $name = shift;

    my $arg;
    $arg = _HASHLIKE($_[0]) ? shift : {};

    my $method = _CODELIKE($_[0])       ? shift
               : ($_[0] && ! ref $_[0]) ? shift
               :                          "cmd_$name";

    Carp::confess("weird-o leftover arguments when adding $name command: @_")
      if @_;

    my @help;
    if ($arg->{help}) {
      @help = map {; { title => $name, text => $_ } }
              (ref $arg->{help} ? $arg->{help}->@* : $arg->{help});
    }

    my $listener = Synergy::Listener->new({
      name      => $name,
      exclusive => 1,
      predicate => sub ($self, $e) {
        return $e->was_targeted && $e->text =~ /\A\Q$name\E(\s|\z)/ni;
      },
      method    => sub ($self, $e) {
        my ($cmd, $rest) = split /\s+/, $e->text, 2;
        $self->$method($e, { cmd => $cmd, rest => $rest });
      },
      (@help ? (help_entries => \@help) : ()),
    });

    push @listeners, $listener;
  };

  method listeners => sub ($self) {
    return @listeners;
  };
};

1;
