use v5.24.0;
package Synergy::Reactor::Page;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor', 'Synergy::Role::EasyListening';

use experimental qw(signatures);
use namespace::clean;
use List::Util qw(first);

has page_channel_name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub start ($self) {
  my $name = $self->page_channel_name;
  my $channel = $self->hub->channel_named($name);
  confess("no page channel ($name) configured, cowardly giving up")
    unless $channel;
}

__PACKAGE__->add_command(
  page => { help => "page WHO: MESSAGE -- send a page" }
);

sub cmd_page ($self, $event, $arg) {
  $event->mark_handled;

  my ($who, $what) = $arg->{rest} =~ m/^@?([a-z]+):\s+(.*)/is;

  unless (length $who and length $what) {
    $event->reply("usage: page USER: MESSAGE");
    return;
  }

  my $user = $self->hub->user_directory->user_by_name($who);

  unless ($user) {
    $event->reply("I don't know who '$who' is. Sorry :confused:");
    return;
  }

  unless ($user->identities->{ $self->page_channel_name } || $user->has_phone) {
    $event->reply("I don't know how to page $who, sorry.");
    return;
  }

  my $page_channel = $self->hub->channel_named($self->page_channel_name);

  my $from = $event->from_user ? $event->from_user->username
                               : $event->from_address;

  $page_channel->send_message_to_user($user, "$from says: $what");
  $event->reply("Page sent!");
}

1;
