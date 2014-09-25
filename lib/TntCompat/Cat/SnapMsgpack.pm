use utf8;
use strict;
use warnings;

package TntCompat::Cat::SnapMsgpack;
use base qw(TntCompat::Cat);
use TntCompat::Debug;
use Carp;
use Data::Dumper;
use TntCompat::Msgpack;

use constant    IPROTO_TYPE     => 0;
use constant    IPROTO_INSERT   => 2;
use constant    IPROTO_LSN      => 3;
use constant    IPROTO_SPACE_ID => 0x10;
use constant    IPROTO_TUPLE    => 0x21;


sub _check_data {
    my ($self) = @_;

    return if $self->{state} eq 'eof';

    if ($self->{state} eq 'init') {
        my ($hdr, $eof) = $self->{data} =~ /^(.*?)(\n\n|\r\n\r\n)/s;
        return unless $hdr;
        substr $self->{data}, 0, length($hdr) + length($eof), '';

        ($self->{type}, $self->{version}) = split /\n|\r\n/, $hdr, 3;
        croak "Unknown file type: " . ($self->{type} // 'undef')
            unless $self->{type} eq 'SNAP';
        croak "Unknown version: " . ($self->{version} // 'undef')
            unless $self->{version} eq '0.12';

        $self->{state} = 'rows';
    }



    my $skip_mode = 0;
    while(1) {
        
        return unless length($self->{data}) >= 4;
        my $marker = unpack 'L>', $self->{data};
        if ($marker == 0xd510aded) {
            DEBUGF 'Found end marker';
            $self->{state} = 'eof';
            return;
        }
        unless ($marker == 0xd5ba0bab) {
            unless ($skip_mode) {
                DEBUGF 'Broken marker (0x%08X), seek until valid marker',
                    $marker;
                $skip_mode = 1;
            }
            substr $self->{data}, 0, 1, '';
            next;
        }

        return unless length $self->{data} >= 19;

        my ($hdr, $offset) = msgunpack substr $self->{data}, 19;
        return unless defined $offset;

        my ($body, $boffset) = msgunpack substr $self->{data}, 19 + $offset;
        return unless defined $boffset;

        substr $self->{data}, 0, $offset + $boffset + 19, '';


        die "Broken row header in snapshot" unless ref $hdr eq 'HASH';
        die "Broken row body in snapshot" unless ref $body eq 'HASH';

        die "Not 'insert' command in snapshot: " . $hdr->{IPROTO_TYPE()}
            unless $hdr->{IPROTO_TYPE()} == IPROTO_INSERT;
        
        my $space = $body->{IPROTO_SPACE_ID()};
        die "Undefined space no in 'insert' command in snapshot"
            unless defined $space;

        my $tuple = $body->{IPROTO_TUPLE()};
        die "No tuple in 'insert' command in snapshot"
            unless ref $tuple eq 'ARRAY';
        
        my $lsn = $hdr->{IPROTO_LSN()};
        die "No lsn in row header" unless defined $lsn;
        $self->on_row->($lsn, insert => $space, $tuple);
    }
}

1;

