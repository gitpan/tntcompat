#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 170;
use Encode qw(decode encode);


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    use_ok 'TntCompat::Server';
    use_ok 'File::Temp', 'tempdir';
    use_ok 'File::Path', 'remove_tree';
    use_ok 'TntCompat::Config';
    use_ok 'File::Spec::Functions', 'catfile', 'rel2abs';
    use_ok 'File::Basename', 'dirname', 'basename';

    use_ok 'Coro';
    use_ok 'Coro::Socket';
    use_ok 'IO::Socket::UNIX';
    use_ok 'AnyEvent::Socket';
    use_ok 'MIME::Base64';
    use_ok 'TntCompat::UUID';

    use_ok 'TntCompat::Proto', 'ping', 'auth', 'master_join';
}


my $dir = tempdir;
ok -d $dir, "$dir was created";
$SIG{INT} = sub {
    if ($dir and -d $dir) {
        remove_tree $dir;
        ok !-d $dir, "$dir was removed";
        $dir = undef;
        exit
    }
};

END { $SIG{INT}(); }

my $socket_path = catfile $dir, 'socket';

my $s = TntCompat::Server->new(
    TntCompat::Config->new_from_hash(
        {
            host            => '127.0.0.1',
            port            => 3456,

            user            => 'username',
            password        => 'password',

            snap_dir        => catfile(dirname(__FILE__), 'data', 'easy'),
            wal_dir         => catfile(dirname(__FILE__), 'data', 'easy'),
            server_uuid     => uuid_hex,
            cluster_uuid    => uuid_hex,
#             bootstrap       =>
#                 catfile(dirname(__FILE__), 'data/1.6/bootstrap.snap'),

            skip_spaces     => [],

            schema          => {

                0   => {
                    fields  => {
                        0   => 'NUM',
                        1   => 'NUM',
                        2   => 'NUM',
                    },

                    indexes => [
                        {
                            fields  => [ 0 ],
                            type    => 'tree',
                        },
                        {
                            fields  => [ 0 ],
                            name    => 'last_index',
                            type    => 'hash',
                        }
                    ]
                }
            }
        }
    )
);


ok -d $s->snap_dir, '-d snap_dir';
ok -d $s->wal_dir,  '-d wal_dir';


isa_ok $s => 'TntCompat::Server';


note 'connect test';
{
    my $sc = Coro::Socket->new(PeerHost => $s->host, PeerPort => $s->port);
    binmode $sc => ':raw';

    my $handshake;
    ok $sc->readable, 'readable';
    diag decode utf8 => $! unless
        is $sc->read($handshake, 128), 128, 'handshake was read';

    like $handshake, qr{^Tarantool 1\.6~compat\n}, 'Handshake title';
    my $salt = unpack 'x[a64]a64', $handshake;

    ok $salt = decode_base64($salt), 'decoded salt';
    is length $salt, 32, '32 bytes in salt';

    ok close $sc, 'close';
}

note 'full test';
{
    my $sc = Coro::Socket->new(PeerHost => $s->host, PeerPort => $s->port);
    binmode $sc => ':raw';

    my $handshake;
    ok $sc->readable, 'readable';
    diag decode utf8 => $! unless
        is $sc->read($handshake, 128), 128, 'handshake was read';

    like $handshake, qr{^Tarantool 1\.6~compat\n}, 'Handshake title';
    my $salt = unpack 'x[a64]a64', $handshake;

    ok $salt = decode_base64($salt), 'decoded salt';
    is length $salt, 32, '32 bytes in salt';


    my $ping = ping(11);
    is $sc->write($ping), length $ping, 'ping was sent';

    ok $sc->readable(1), 'response was received';


    is_deeply [ TntCompat::Server->read_request($sc) ],
        [ { CODE => 0, ERRCODE => 0, SYNC => 11 } ], 'pong';


    my $auth = auth 12, 'username', 'password1', $salt;
    is $sc->write($auth), length $auth, 'auth was sent';

    ok $sc->readable(1), 'auth response was received';

    is_deeply
        [  TntCompat::Server->read_request($sc) ],
        [
            {
                'CODE'      => 0x2000_0000 | 42,
                'ERRCODE'   => 0x2000_0000 | 42,
                'ERROR'     => 'Wrong password for user username',
                'SYNC'      => 12
            }
        ],
        'wrong password';
    
    $auth = auth 17, 'username', 'password', $salt;
    is $sc->write($auth), length $auth, 'auth was sent';

    ok $sc->readable(1), 'auth response was received';

    is_deeply
        [  TntCompat::Server->read_request($sc) ],
        [ { CODE => 0, ERRCODE => 0, SYNC => 17, DATA => [] } ],
        'ok password';


    my $server_uuid = uuid_hex;
    my $join = master_join 21, $server_uuid;
    is $sc->write($join), length $join, 'join was sent';
    ok $sc->readable(1), 'join response was received';


    note 'receive bootstrap.snap';
    for (1 .. 4096) {
        my $r = TntCompat::Server->read_request($sc);
        is $r->{LSN}, $_, 'LSN';
        like $r->{CODE}, qr{INSERT}, 'CODE, space: ' . $r->{SPACE_ID};
        is $r->{SERVER_ID}, 0, 'SERVER_ID';
        ok($r, 'bootstrap request is read');


        if ($r->{SPACE_ID} == TntCompat::Proto::SC_SCHEMA_ID) {
            next unless $r->{TUPLE}[0] eq 'cluster';
            diag explain $r unless
                is_deeply $r->{TUPLE}, [ 'cluster' => $s->cluster_uuid ],
                    'cluster_uuid';
            next;
        }

        next unless $r->{SPACE_ID} == TntCompat::Proto::SC_CLUSTER_ID;
        is_deeply $r->{TUPLE}, [ 1 => $s->server_uuid ], 'uuid';
        last;
    }

    note 'schema';
    {
        my $r = TntCompat::Server->read_request($sc);
        is_deeply $r->{TUPLE},
            [ 0, 1, 'space_0', 'memtx', 0, '' ], 'space record';
        $r = TntCompat::Server->read_request($sc);
        is_deeply $r->{TUPLE},
            [ 0, 0, 'pk', 'tree', 1, 1, 0, 'num' ], 'index 0 record';

        $r = TntCompat::Server->read_request($sc);
        is_deeply $r->{TUPLE},
            [ 0, 1, 'last_index', 'hash', 0, 1, 0, 'num' ], 'index 1 record';
    }

    note 'snapshot';
    {
        my $r = TntCompat::Server->read_request($sc);
        is_deeply $r->{TUPLE}, [ 1, 2, 3  ], 'record 0';
        
        $r = TntCompat::Server->read_request($sc);
        is_deeply $r->{TUPLE}, [ 2, 3, 4 ], 'record 1';

        $r = TntCompat::Server->read_request($sc);
        is_deeply $r->{TUPLE}, [ 3, 4, 5 ], 'record 2';
    }

    note 'cluster';
    {
        my $r = TntCompat::Server->read_request($sc);
        is_deeply $r->{TUPLE}, [ 2, $server_uuid ],  'cluster ID';
    }

    note 'vclock';
    {
        my $r = TntCompat::Server->read_request($sc);
        is_deeply $r, { 
            'CODE' => 0,
            'ERRCODE' => 0,
            'SYNC' => 21,
            'VCLOCK' => {
                '1' => 8,
                '2' => 0
            }
        }, 'vclock response';
    }

}
