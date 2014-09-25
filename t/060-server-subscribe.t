#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 102;
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

    use_ok 'TntCompat::Proto',
        'ping', 'auth', 'master_join', 'master_subscribe';
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
            bootstrap   =>
                catfile(dirname(__FILE__), 'data/1.6/bootstrap.snap'),

            skip_spaces => [],

            schema  => {

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

note 'broken subscribe test';
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


    note 'wrong cluster_uuid';
    my $subscribe = master_subscribe 21,
        $s->server_uuid, uuid_hex, { 1 => 1, 2 => 0 };
    is $sc->write($subscribe), length $subscribe, 'subscribe request was sent';
    my $resp = TntCompat::Server->read_request($sc);
    is $resp->{ERRCODE}, 0x2000_0000 | 63, 'Error code';
    is $resp->{SYNC}, 21, 'sync';
    like $resp->{ERROR},
        qr{Cluster id.*doesn't match cluster}, 'Error message';
}


note 'normal test';
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


    my $auth = auth 17, 'username', 'password', $salt;
    is $sc->write($auth), length $auth, 'auth was sent';

    is_deeply
        [  TntCompat::Server->read_request($sc) ],
        [ { CODE => 0, ERRCODE => 0, SYNC => 17, DATA => [] } ],
        'ok password';


    my $subscribe = master_subscribe 27,
        uuid_hex, $s->cluster_uuid, { 1 => 1, 2 => 22 };
    is $sc->write($subscribe), length $subscribe, 'subscribe request was sent';

    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'INSERT', 'insert';
        is $resp->{LSN}, 2, 'lsn';
        is_deeply $resp->{TUPLE}, [ 1, 2, 3 ], 'tuple';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }
    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'REPLACE', 'insert';
        is $resp->{LSN}, 3, 'lsn';
        is_deeply $resp->{TUPLE}, [ 1, 3, 5 ], 'tuple';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }
    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'UPDATE', 'insert';
        is $resp->{LSN}, 4, 'lsn';
        is_deeply $resp->{TUPLE}, [ [ '=', 2, 4 ] ], 'tuple';
        is_deeply $resp->{KEY}, [ 1 ], 'key';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }

    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'DELETE', 'insert';
        is $resp->{LSN}, 5, 'lsn';
        is_deeply $resp->{KEY}, [ 1 ], 'key';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }
    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'INSERT', 'insert';
        is $resp->{LSN}, 6, 'lsn';
        is_deeply $resp->{TUPLE}, [ 1, 2, 3 ], 'tuple';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }
    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'INSERT', 'insert';
        is $resp->{LSN}, 7, 'lsn';
        is_deeply $resp->{TUPLE}, [ 2, 3, 4 ], 'tuple';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }
    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'INSERT', 'insert';
        is $resp->{LSN}, 8, 'lsn';
        is_deeply $resp->{TUPLE}, [ 3, 4, 5 ], 'tuple';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }
    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'UPDATE', 'insert';
        is $resp->{LSN}, 9, 'lsn';
        is_deeply $resp->{KEY}, [ 3 ], 'key';
        is_deeply $resp->{TUPLE},
            [ ['#', 2, 1 ], ['!', 2, 1869374824 ] ], 'tuple';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }
    {
        my $resp = TntCompat::Server->read_request($sc);
        is $resp->{CODE}, 'UPDATE', 'insert';
        is $resp->{LSN}, 10, 'lsn';
        is_deeply $resp->{KEY}, [ 3 ], 'key';
        is_deeply $resp->{TUPLE},
            [ [':', 2, 2, 1, 'l' ] ], 'tuple';
        is $resp->{SERVER_ID}, 1, 'server_id';
        is $resp->{SYNC}, 27, 'SYNC';
    }

    $sc->timeout(0.3);
    ok !$sc->readable, 'socket is empty';
    $sc->timeout(undef);
}
