use utf8;
use strict;
use warnings;

package TntCompat::Cat::Snap;
use base qw(TntCompat::Cat);
use TntCompat::Debug;
use Carp;
use Data::Dumper;


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
            unless $self->{version} eq '0.11';

        $self->{state} = 'rows';
    }

    my $skip_mode = 0;
    while(1) {

        return unless length($self->{data}) >= 4;
        my $marker = unpack 'L<', $self->{data};
        if ($marker == 0x10adab1e) {
            DEBUGF 'Found end marker';
            $self->{state} = 'eof';
            return;
        }
        unless ($marker == 0xba0babed) {
            unless ($skip_mode) {
                DEBUGF 'Broken marker (0x%08X), seek until valid marker',
                    $marker;
                $skip_mode = 1;
            }
            substr $self->{data}, 0, 1, '';
            next;
        }


        return unless length($self->{data}) >= 4 + 4 + 8 + 8 + 4 + 4 + 2 + 8;

        my ($hcrc32, $lsn, $tm, $len, $crc32, $tag, $cookie, $data) =
            unpack 'x[L] L< Q< d< L< L< S< Q< a*', $self->{data};

        $len -=  2 + 8; # tag and cookie are in len
        
        return unless length($data) >= $len;

        my $tuple = substr $data, 0, $len, '';
        $self->{data} = $data;

        my ($space, $tsize, $dsize, @fields) = unpack 'L L L (w/a*)*', $tuple;
        $self->on_row->($lsn, 'insert', $space, \@fields);
    }
}

1;

