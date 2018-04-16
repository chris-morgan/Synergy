use v5.24.0;
package Synergy::Role::Reactor;

use Moose::Role;

use experimental qw(signatures);
use namespace::clean;

use Synergy::Listener;

with 'Synergy::Role::HubComponent';

# has listeners => (
#   isa => 'ArrayRef',
#   traits  => [ 'Array' ],
#   handles => { listeners => 'elements' },
#   default => sub ($self, @) {
#     # { name, predicate, exclusive, method }
#     my @listeners;
#     for my $spec ($self->listener_specs) {
#       push @listeners, Synergy::Listener->new({
#         map {; exists $spec->{$_} ? ($_ => $spec->{$_}) : () }
#           qw( name predicate exclusive method help_entries )
#       });
#     }
#
#     return \@listeners;
#   },
# );

sub start ($self) { }

sub resolve_name ($self, $name, $resolving_user) {
  $self->hub->user_directory->resolve_name($name, $resolving_user);
}

no Moose::Role;
1;
