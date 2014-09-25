use utf8;
use strict;
use warnings;

package TntCompat::Cat::Xlog;
use TntCompat::Debug;
use Carp;
use Data::Dumper;
use base qw(TntCompat::Cat);


my %ops = (
    13  => 'insert',
    19  => 'update',
    21  => 'delete'
);

my %operation = (
    0   => '=',     # set
    1   => '+',     # add
    2   => '&',     # and
    3   => '^',     # xor
    4   => '|',     # or
    5   => ':',     # substr
    6   => '#',     # delete
    7   => '!',     # insert
);


sub _check_data {
    my ($self) = @_;

    return if $self->{state} eq 'eof';

    if ($self->{state} eq 'init') {
        my ($hdr, $eof) = $self->{data} =~ /^(.*?)(\n\n|\r\n\r\n)/s;
        return unless $hdr;
        substr $self->{data}, 0, length($hdr) + length($eof), '';

        ($self->{type}, $self->{version}) = split /\n|\r\n/, $hdr, 3;
        croak "Unknown file type: " . ($self->{type} // 'undef')
            unless $self->{type} eq 'XLOG';
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





        my ($op, $space, $flags, @fields) =
            unpack 'S< L< L< L< / (w / a*) a*', $tuple;


        unless ($ops{$op}) {
            DEBUGF 'Unknown operation code: %s (0x%02X)', $op, $op;
            return;

        }
        $op = $ops{$op};

        $op = 'replace' if $op eq 'insert' and !($flags & 0x02);

        my @args;

        if ($op eq 'update') {
            my $o = pop @fields;
            my @olist = unpack 'L< / (L< C w / a*)', $o;

            my @converted_ops;
            while(@olist) {
                my $fno = shift @olist;
                my $op = shift @olist;
                unless (defined $op) {
                    DEBUGF 'Unknown update operation code: 0x%02X', $op;
                    return;
                }

                $op = $operation{ $op };
                
                my $arg = shift @olist;
    
                if ($op eq ':') {
                    my ($offset, $limit, $str) = unpack 'w/a* w/a* w/a*', $arg;
                    for ($offset, $limit) {
                        if (length $_ == 4) {
                            $_ = unpack 'L<', $_;
                        } elsif (length $_ == 8) {
                            $_ = unpack 'Q<', $_;
                        } else {
                            DEBUGF "Unknown length of ".
                                "offset/limit in splice: %s",
                            length $_;
                            return;
                        }
                    }
                    push @converted_ops => [ $op, $fno, $offset, $limit, $str ];

                } else {
                    $arg = 1 if $op eq '#'; # delete
                    push @converted_ops => [ $op, $fno, $arg ];
                }
            }
            push @args => \@converted_ops;
        } else {
            pop @fields;
        }

        $self->on_row->($lsn, $op, $space, \@fields, @args);
    }
}

1;


