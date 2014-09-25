use utf8;
use strict;
use warnings;

package TntCompat::Proto;
use TntCompat::Msgpack;
use base qw(Exporter);
our @EXPORT_OK = qw(
    insert
    replace
    update
    del
    ping
    auth
    check_auth

    master_join
    master_subscribe
    
    make_response
    parse_response
);
use Carp;
use Time::HiRes qw(time);
use Data::Dumper;
use Digest::SHA 'sha1';

use constant SC_SCHEMA_ID   => 272;
use constant SC_SPACE_ID    => 280;
use constant SC_INDEX_ID    => 288;
use constant SC_FUNC_ID     => 296;
use constant SC_USER_ID     => 304;
use constant SC_PRIV_ID     => 312;
use constant SC_CLUSTER_ID  => 320;


our $DECODE_UTF8    = 1;

my (%resolve, %tresolve);

my %iter = (
    EQ                  => 0,
    REQ                 => 1,
    ALL                 => 2,
    LT                  => 3,
    LE                  => 4,
    GE                  => 5,
    GT                  => 6,
    BITS_ALL_SET        => 7,
    BITS_ANY_SET        => 8,
    BITS_ALL_NOT_SET    => 9
);

my %riter = reverse %iter;

BEGIN {
    my %types = (
        IPROTO_SELECT              => 1,
        IPROTO_INSERT              => 2,
        IPROTO_REPLACE             => 3,
        IPROTO_UPDATE              => 4,
        IPROTO_DELETE              => 5,
        IPROTO_CALL                => 6,
        IPROTO_AUTH                => 7,
        IPROTO_DML_REQUEST_MAX     => 8,
        IPROTO_PING                => 64,
        IPROTO_JOIN                => 65,
        IPROTO_SUBSCRIBE           => 66,
    );
    my %attrs = (
        IPROTO_CODE                => 0x00,
        IPROTO_SYNC                => 0x01,
        IPROTO_SERVER_ID           => 0x02,
        IPROTO_LSN                 => 0x03,
        IPROTO_TIMESTAMP           => 0x04,
        IPROTO_SPACE_ID            => 0x10,
        IPROTO_INDEX_ID            => 0x11,
        IPROTO_LIMIT               => 0x12,
        IPROTO_OFFSET              => 0x13,
        IPROTO_ITERATOR            => 0x14,
        IPROTO_KEY                 => 0x20,
        IPROTO_TUPLE               => 0x21,
        IPROTO_FUNCTION_NAME       => 0x22,
        IPROTO_USER_NAME           => 0x23,

        IPROTO_SERVER_UUID         => 0x24,
        IPROTO_CLUSTER_UUID        => 0x25,
        IPROTO_VCLOCK              => 0x26,

        IPROTO_DATA                => 0x30,
        IPROTO_ERROR               => 0x31,
    );

    use constant;
    while (my ($n, $v) = each %types) {
        constant->import($n => $v);
        $n =~ s/^IPROTO_//;
        $tresolve{$v} = $n;
    }
    while (my ($n, $v) = each %attrs) {
        constant->import($n => $v);
        $n =~ s/^IPROTO_//;
        $resolve{$v} = $n;
    }
}

sub _request($$$;$) {
    my ($sync, $hdr, $body, $opts) = @_;

    $opts ||= {};

    # hardcode for tntcompat
    if ($hdr->{IPROTO_LSN()}) {
        # TODO: fix it
        $hdr->{IPROTO_SERVER_ID()} ||= 0;
        $hdr->{IPROTO_SERVER_ID()} = $opts->{server_id}
            if exists $opts->{server_id};
        $hdr->{IPROTO_TIMESTAMP()} ||= double time;
    }
    $hdr->{IPROTO_SYNC()} = $sync if defined $sync;

    $hdr = msgpack $hdr;
    $body = msgpack $body;
    my $len = msgpack length($body) + length $hdr;
    my $pkt = $len . $hdr . $body;

    return $pkt;
}


sub master_join($$;$) {
    my ($sync, $uuid, $opts) = @_;
    return _request $sync,
        {
            IPROTO_CODE()           => IPROTO_JOIN,
            IPROTO_SERVER_UUID()    => $uuid,
        },
        {

        },
        $opts
    ;
}

sub master_subscribe($$$$;$) {
    my ($sync, $server_uuid, $cluster_uuid, $vclock, $opts) = @_;

    return _request $sync,
    {
        IPROTO_CODE()           => IPROTO_SUBSCRIBE,
        IPROTO_SERVER_UUID()    => $server_uuid,
        IPROTO_CLUSTER_UUID()   => $cluster_uuid,
    },
    {
        IPROTO_VCLOCK()         => $vclock,
    },
    $opts
}


sub insert {
    my ($sync, $lsn, $spaceno, $tuple, $opts) = @_;

    return _request $sync,
        {
            IPROTO_CODE()       => IPROTO_INSERT,
            IPROTO_LSN()        => $lsn,
        },
        {
            IPROTO_SPACE_ID()   => $spaceno,
            IPROTO_TUPLE()      => $tuple,
        },
        $opts
    ;
}

sub replace {
    my ($sync, $lsn, $spaceno, $tuple, $opts) = @_;

    return _request $sync,
        {
            IPROTO_CODE()       => IPROTO_REPLACE,
            IPROTO_LSN()        => $lsn,
        },
        {
            IPROTO_SPACE_ID()   => $spaceno,
            IPROTO_TUPLE()      => $tuple,
        },
        $opts
    ;
}

sub del {
    my ($sync, $lsn, $spaceno, $tuple, $opts) = @_;

    return _request $sync,
        {
            IPROTO_CODE()       => IPROTO_DELETE,
            IPROTO_LSN()        => $lsn,
        },
        {
            IPROTO_SPACE_ID()   => $spaceno,
            IPROTO_KEY()        => $tuple,
        },
        $opts
    ;
}


sub update {
    my ($sync, $lsn, $spaceno, $pk, $ops, $opts) = @_;
    return _request $sync,
        {
            IPROTO_CODE()       => IPROTO_UPDATE,
            IPROTO_LSN()        => $lsn,
        },
        {
            IPROTO_SPACE_ID()   => $spaceno,
            IPROTO_KEY()        => $pk,
            IPROTO_TUPLE()      => $ops,
        },
        $opts
}


sub ping($;$) {
    my ($sync, $lsn) = @_;
    return _request $sync,
        {
            IPROTO_CODE()       => IPROTO_PING,
            defined($lsn) ? (IPROTO_LSN() => $lsn) : ()
        },
        {
        }
    ;
}


sub strxor($$) {
    my ($x, $y) = @_;

    my @x = unpack 'C*', $x;
    my @y = unpack 'C*', $y;
    $x[$_] ^= $y[$_] for 0 .. $#x;
    return pack 'C*', @x;
}


sub auth {
    my ($sync, $user, $password, $salt, $opts) = @_;
    my $hpasswd = sha1 $password;
    my $hhpasswd = sha1 $hpasswd;
    $salt = substr $salt, 0, 20;
    my $scramble = sha1 $salt . $hhpasswd;
    my $hash = strxor $hpasswd, $scramble;

    _request $sync,
        {
            IPROTO_CODE()   => IPROTO_AUTH,
        },
        {
            IPROTO_USER_NAME()  => $user,
            IPROTO_TUPLE()      => [  'chap-sha1', $hash ],
        },
        $opts
    ;
}


sub check_auth($$$) {
    my ($hash, $salt, $password) = @_;

    my $hpasswd = sha1 $password;
    my $hhpasswd = sha1 $hpasswd;
    $salt = substr $salt, 0, 20;
    my $scramble = sha1 $salt . $hhpasswd;
    my $hash_orig = strxor $hpasswd, $scramble;

    return 0 unless $hash eq $hash_orig;
    return 1;
}


sub make_response($;$$) {
    my ($sync, $code, $data, $opts) = @_;
    $code ||= 0;
    return _request $sync,
        {
            IPROTO_CODE()       => $code,
        },
        {
            $code   ? 
                ( IPROTO_ERROR() => $data // "Undefined internal error" ):
                ( ref $data ? (IPROTO_DATA() => $data ) : () )
        },
        $opts
    ;
}

sub vclock($$;$) {
    my ($sync, $vclock, $opts) = @_;

    return _request $sync,
        {
            IPROTO_CODE()       => 0,
        },
        {
            IPROTO_VCLOCK()     => $vclock
        },
        $opts
    ;
}

sub parse_response {
    my ($octets) = @_;
    return undef unless defined $octets;
    return undef unless length $octets;

    my ($len, $off, $hdr, $body) = @_;

    ($len, $off) = msgunpack $octets;
    return undef unless defined $off;

    my $total_len = $off + $len;
    my $total_off = $off;
    return undef unless $total_len >= length $octets;

    my $str = $octets;
    $str =~ s/./sprintf ' 0x%02X', ord $&/ge;

    ($hdr, $off) = msgunpack substr $octets, $total_off;
    return undef unless defined $off;
    $total_off += $off;

    if ($off < $total_len) {
        ($body, $off) = msgunpack substr $octets, $total_off;
        return undef unless defined $off;
        $total_off += $off;
    } else {
        $body = {};
    }

    my $res = {};

    while(my ($k, $v) = each %$hdr) {
        my $name = $resolve{$k};
        $name = $k unless defined $name;
        $res->{$name} = $v;
    }
    while(my ($k, $v) = each %$body) {
        my $name = $resolve{$k};
        $name = $k unless defined $name;
        $res->{$name} = $v;
    }

    if (defined $res->{CODE}) {
        $res->{ERRCODE} = $res->{CODE};
        my $n = $tresolve{ $res->{CODE} };
        $res->{CODE} = $n if defined $n;
    }

    if (defined $res->{ITERATOR}) {
        my $n = $riter{ $res->{ITERATOR} };
        $res->{ITERATOR} = $n if defined $n;
    }

    return $res;
}


1;
