use utf8;
use strict;
use warnings;

package TntCompat::Msgpack::String;
use Encode qw(encode);

sub new {
    my ($class, $str) = @_;
    return undef unless defined $str;
    my $self = bless \$str => ref($class) || $class;
    return $self;
}

sub pack :method {
    my ($self) = @_;

    my $s = $$self;
    utf8::encode $s if utf8::is_utf8 $s;

    return pack 'CN/a*', 0xDB, $s  if length($s) > 0xFFFF;
    return pack 'Cn/a*', 0xDA, $s  if length($s) > 0xFF;
    return pack 'CC/a*', 0xD9, $s  if length($s) > 0x1F;
    return pack 'Ca*',   (0xA0 | length $s), $s;
}


package TntCompat::Msgpack::Double;

sub new {
    my ($class, $value) = @_;
    return undef unless defined $value;
    my $self = bless \$value => ref($class) || $class;
    return $self;
}

sub pack :method {
    my ($self) = @_;
    return pack 'Cd>', 0xCB, $$self;
}


package TntCompat::Msgpack;
use Encode qw(decode encode);
use base qw(Exporter);
our @EXPORT = qw(msgpack msgunpack string double);
use Scalar::Util qw(looks_like_number);
use Carp;
use Data::Dumper;


sub _msgpack_scalar($);
sub _msgpack_array($);
sub _msgpack_hash($);
sub msgpack($);
sub msgunpack($);

our $UTF8STR   = 0;


sub _msgpack_scalar($) {
    my ($s) = @_;
    return pack 'C', 0xC0 unless defined $s;

    if (looks_like_number $s) {
        if ($s == int $s) {
            return pack 'CQ>', 0xCF, $s if $s > 0xFFFF_FFFF;
            return pack 'CN',  0xCE, $s if $s > 0xFFFF;
            return pack 'Cn',  0xCD, $s if $s > 0xFF;
            return pack 'CC',  0xCC, $s if $s > 0x7F;
            return pack 'C',   $s       if $s >= 0;

            # negative values
            return pack 'Cq>', 0xD3, $s if $s < -0x7FFF_FFFF;
            return pack 'Cl>', 0xD2, $s if $s < -0x7FFF;
            return pack 'Cs>', 0xD1, $s if $s < -0x7F;
            return pack 'Cc',  0xD0, $s if $s < -0x1F;
            return pack 'C',   0xE0 | (-$s);

            croak "I don't know how to pack integer: $s";
        }

        return pack 'Cd>', 0xCB, $s;
    }


    my $as_string = utf8::is_utf8 $s;

    unless ($as_string) {
        local $SIG{__WARN__} = sub {  };
        my $su = $s;
        if (eval { utf8::decode $su; 1 }) {
            $as_string = 1 if $s eq $su;

        }
    }

    if ($as_string or !length $s) {
        utf8::encode $s if utf8::is_utf8 $s;

        return pack 'CN/a*', 0xDB, $s  if length $s > 0xFFFF;
        return pack 'Cn/a*', 0xDA, $s  if length $s > 0xFF;
        return pack 'CC/a*', 0xD9, $s  if length $s > 0x1F;
        return pack 'Ca*',   (0xA0 | length $s), $s;
    }

    return pack 'CN/a*', 0xC6, $s  if length $s > 0xFFFF;
    return pack 'Cn/a*', 0xC5, $s  if length $s > 0xFF;
    return pack 'CC/a*', 0xC4, $s;
}


sub _msgpack_array($) {
    my ($ary) = @_;
    my $res = '';
    if (@$ary < 16) {
        $res .= pack 'C', (0x90 | scalar @$ary);
    } elsif (@$ary <= 0xFFFF) {
        $res .= pack 'Cn', 0xDC, scalar @$ary;
    } else {
        $res .= pack 'CN', 0xDD, scalar @$ary;
    }
    $res .= msgpack($_) for @$ary;
    return $res;
}


sub _msgpack_hash($) {
    my ($h) = @_;
    my $res = '';
    if (keys(%$h) < 16) {
        $res .= pack 'C', 0x80 | scalar keys %$h;
    } elsif (keys(%$h) < 0xFFFF) {
        $res .= pack 'Cn', 0xDE, scalar keys %$h;
    } else {
        $res .= pack 'CN', 0xDF, scalar keys %$h;
    }
    while(my ($k, $v) = each %$h) {
        $res .= msgpack $k;
        $res .= msgpack $v;
    }
    return $res;
}


sub msgpack($) {
    my ($o) = @_;
    return _msgpack_scalar $o unless ref $o;
    return _msgpack_array  $o if 'ARRAY' eq ref $o;
    return _msgpack_hash   $o if 'HASH'  eq ref $o;
    croak "Can't msgpack type: " . ref $o unless $o->can('pack');
    $o->pack;
}


sub string($) {
    my ($str) = @_;
    return $str unless defined $str;
#     return "$str" unless looks_like_number $str;
    TntCompat::Msgpack::String->new($str);
}


sub double($) {
    my ($value) = @_;
    TntCompat::Msgpack::Double->new($value);
}

sub _unpack_res($$) {
    my ($res, $off) = @_;
    return $res unless wantarray;
    return $res, $off;
}

sub _decode_str($) {
    my ($str) = @_;
    return $str unless $UTF8STR;
    my $res = eval { decode utf8 => $str };
    $res = $str if $@;
    return $res;
}


sub msgunpack($) {
    my ($o) = @_;

    no utf8;

    return _unpack_res undef, undef unless length $o;

    my $cf = unpack 'C', $o;

    return _unpack_res undef, 1 if $cf eq 0xC0;     # nil
    return _unpack_res 1, 1 if $cf eq 0xC3;         # true
    return _unpack_res 0, 1 if $cf eq 0xC2;         # false


    # double float
    if ($cf == 0xCB) {
        return _unpack_res undef, undef unless length $o >= 1 + 8;
        $cf = unpack 'x[C]d>', $o;
        return _unpack_res $cf, 1 + 8;
    }

    # float
    if ($cf == 0xCA) {
        return _unpack_res undef, undef unless length $o >= 1 + 4;
        $cf = unpack 'x[C]f>', $o;
        return _unpack_res $cf, 1 + 4;
    }


    # fixuint
    return _unpack_res $cf, 1 if $cf >= 0 and $cf <= 0x7F;

    # uint8
    if ($cf == 0xCC) {
        return _unpack_res undef, undef unless length $o >= 1 + 1;
        $cf = unpack 'x[C]C', $o;
        return _unpack_res $cf, 1 + 1;
    }

    # uint16
    if ($cf == 0xCD) {
        return _unpack_res undef, undef unless length $o >= 1 + 2;
        $cf = unpack 'x[C]n', $o;
        return _unpack_res $cf, 1 + 2;
    }

    # uint32
    if ($cf == 0xCE) {
        return _unpack_res undef, undef unless length $o >= 1 + 4;
        $cf = unpack 'x[C]N', $o;
        return _unpack_res $cf, 1 + 4;
    }

    # uint64
    if ($cf == 0xCF) {
        return _unpack_res undef, undef unless length $o >= 1 + 8;
        $cf = unpack 'x[C]Q>', $o;
        return _unpack_res $cf, 1 + 8;
    }

    # fixint
    return _unpack_res -($cf & ~0xE0), 1 if (($cf & 0xE0) == 0xE0);

    # int8
    if ($cf == 0xD0) {
        return _unpack_res undef, undef unless length $o >= 1 + 1;
        $cf = unpack 'x[C]c', $o;
        return _unpack_res $cf, 1 + 1;
    }

    # int16
    if ($cf == 0xD1) {
        return _unpack_res undef, undef unless length $o >= 1 + 2;
        $cf = unpack 'x[C]s>', $o;
        return _unpack_res $cf, 1 + 2;
    }

    # int32
    if ($cf == 0xD2) {
        return _unpack_res undef, undef unless length $o >= 1 + 4;
        $cf = unpack 'x[C]l>', $o;
        return _unpack_res $cf, 1 + 4;
    }

    # int64
    if ($cf == 0xD3) {
        return _unpack_res undef, undef unless length $o >= 1 + 8;
        $cf = unpack 'x[C]q>', $o;
        return _unpack_res $cf, 1 + 8;
    }

    # fixstr
    if (($cf & 0xE0) == 0xA0) {
        my $len = $cf & ~0xA0;
        return _unpack_res '', 1 unless $len;
        return _unpack_res undef, undef unless length $o >= 1 + $len;
        $cf = unpack "x[C]a$len", $o;
        return _unpack_res _decode_str($cf), 1 + $len;
    }

    # bin8 and str8
    if ($cf == 0xC4 or $cf == 0xD9) {
        return _unpack_res undef, undef unless length($o) >= 1 + 1;
        my $len = unpack 'x[C]C', $o;
        return _unpack_res undef, undef unless length($o) >= $len + 1 + 1;
        my $str = $len ? unpack "x[C]x[C]a$len", $o : '';
        $str = _decode_str $str if $cf == 0xD9;
        return _unpack_res $str, $len + 1 + 1;
    }

    # bin16 and str16
    if ($cf == 0xC5 or $cf == 0xDA) {
        return _unpack_res undef, undef unless length($o) >= 1 + 2;
        my $len = unpack 'x[C]n', $o;
        return _unpack_res undef, undef unless length($o) >= $len + 1 + 2;
        my $str = $len ? unpack "x[C]x[n]a$len", $o : '';
        $str = _decode_str $str if $cf == 0xDA;
        return _unpack_res $str, $len + 1 + 2;
    }

    # bin32 and str32
    if ($cf == 0xC6 or $cf == 0xDB) {
        return _unpack_res undef, undef unless length($o) >= 1 + 4;
        my $len = unpack 'x[C]N', $o;
        return _unpack_res undef, undef unless length($o) >= $len + 1 + 4;
        my $str = $len ? unpack "x[C]x[N]a$len", $o : '';
        $str = _decode_str $str if $cf == 0xDB;
        return _unpack_res $str, $len + 1 + 4;
    }

    # arrays
    {
        my ($len, $hsize) = (0, 0);
        if (($cf & 0xF0) == 0x90) {
            ($len, $hsize) = ($cf & 0x0F, 1);
            goto UNPACK_ARRAY;
        }
        if ($cf == 0xDC) {  # array16
            $hsize = 1 + 2;
            return _unpack_res undef, undef unless length $o >= 1 + 2;
            $len = unpack 'x[C]n', $o;
            goto UNPACK_ARRAY;
        }
        if ($cf == 0xDD) { # arrays32
            $hsize = 1 + 4;
            return _unpack_res undef, undef unless length $o >= 1 + 4;
            $len = unpack 'x[C]N', $o;
            goto UNPACK_ARRAY;
        }

        last;
        UNPACK_ARRAY:
            my @result;
            my $size = 0;
            for (my $i = 0; $i < $len; $i++) {
                my ($aitem, $osize) = msgunpack(substr $o, $size + $hsize);
                return _unpack_res undef, undef unless defined $osize;
                push @result => $aitem;
                $size += $osize;
            }
            return _unpack_res \@result, $size + $hsize;
    }

    # hashes
    {
        my ($len, $hsize) = (0, 0);
        if (($cf & 0xF0) == 0x80){      # fixmap
            ($len, $hsize) = (($cf & 0x0F), 1);
            goto UNPACK_HASH;
        }

        if ($cf == 0xDE) {  # map16
            $hsize = 1 + 2;
            return _unpack_res undef, undef unless length $o >= 1 + 2;
            $len = unpack 'x[C]n', $o;
            goto UNPACK_HASH;
        }

        if ($cf == 0xDF) { # map32
            $hsize = 1 + 4;
            return _unpack_res undef, undef unless length $o >= 1 + 4;
            $len = unpack 'x[C]N', $o;
            goto UNPACK_HASH;
        }

        last;
        UNPACK_HASH:
            my %result;
            my $size = 0;
            for (my $i = 0; $i < $len; $i++) {
                my ($kitem, $ksize) = msgunpack(substr $o, $size + $hsize);
                return _unpack_res undef, undef unless defined $ksize;
                $size += $ksize;

                my ($vitem, $vsize) = msgunpack(substr $o, $size + $hsize);
                return _unpack_res undef, undef unless defined $vsize;
                $size += $vsize;

                $result{$kitem} = $vitem;
            }
            return _unpack_res \%result, $size + $hsize;
    }

    croak sprintf "Can't unpack type code 0x%02X", $cf;
}

1;
