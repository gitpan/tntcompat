use utf8;
use strict;
use warnings;

package TntCompat::Cat;
use Carp;

sub new {
    my ($class, %opts) = @_;
    my $self = bless \%opts => ref($class) || $class;
    $self->{data} = '';
    $self->{state} = 'init';
    $self;
}


sub on_row {
    my ($self, $cb) = @_;
    return $self->{on_row} || sub {  } if @_ < 2;
    $self->{on_row} = $cb;
    return $self->{on_row};
}

sub data {
    my ($self, $data) = @_;
    return unless defined $data;
    return unless length $data;
    $self->{data} .= $data;
    $self->_check_data;
    $self;
}


sub _check_data {
    my ($class) = @_;
    $class = ref $class if ref $class;
    croak "Unimplemented $class\->_check_data method";
}

1;

