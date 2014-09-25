#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 87;
use Encode qw(decode encode);
use Encode qw(encode_utf8);

BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";
}


BEGIN {
    use_ok 'TntCompat::Msgpack';
}

no warnings 'portable';

is msgpack(undef), pack('C', 0xC0), 'undef';

note 'strings';

is msgpack(''),    pack('C', 0xA0), 'empty string';
is msgpack('a'),   pack('CA*', 0xA1, 'a'), 'a';
is msgpack('привет'),
    pack('CA*', 0xA0 | 12, encode_utf8('привет')), 'привет';


note 'floats';
is msgpack(1.1), pack('Cd>', 0xCB, 1.1), '1.1';

note 'positive integers';

is msgpack(0), pack('C', 0), 'zero';
is msgpack('0'), pack('C', 0), 'string zero';
is msgpack(127), pack('C', 127), 'msgpack 127';
is msgpack(128), pack('CC', 0xCC, 128), 'msgpack 128';
is msgpack(0xFF), pack('CC', 0xCC, 0xFF), 'msgpack 0xFF';
is msgpack(0x100), pack('Cn', 0xCD, 0x100), 'msgpack 0x100';
is msgpack(0xFFFF), pack('Cn', 0xCD, 0xFFFF), 'msgpack 0xFFFF';
is msgpack(0x10000), pack('CN', 0xCE, 0x10000), 'msgpack 0x10000';
is msgpack(0xFFFF_FFFF), pack('CN', 0xCE, 0xFFFF_FFFF), 'msgpack 0xFFFF_FFFF';
is msgpack(0x100000000), pack('CQ>', 0xCF, 0x100000000), 'msgpack 0x10000_0000';


note 'negative integers';
is msgpack(-1), pack('C', 0xE0 | 1), 'msgpack -1';
is msgpack(-0x1F), pack('C', 0xE0 | 0x1F), 'msgpack -0x1F';

is msgpack(-0x20), pack('Cc', 0xD0, -0x20), 'msgpack -0x20';
is msgpack(-0x7F), pack('Cc', 0xD0, -0x7F), 'msgpack -0x7F';
is msgpack(-0x80), pack('Cs>', 0xD1, -0x80), 'msgpack -0x80';
is msgpack(-0x100), pack('Cs>', 0xD1, -0x100), 'msgpack -0x100';
is msgpack(-0x7FFF), pack('Cs>', 0xD1, -0x7FFF), 'msgpack -0x7FFF';
is msgpack(-0x8000), pack('Cl>', 0xD2, -0x8000), 'msgpack -0x8000';
is msgpack(-0x7FFF_FFFF), pack('Cl>', 0xD2, -0x7FFF_FFFF),
    'msgpack -0x7FFF_FFFF';
is msgpack(-0x100000000), pack('Cq>', 0xD3, -0x100000000),
    'msgpack -0x10000_0000';

note 'arrays';
is msgpack([]), pack('C', 0x90), 'empty array';
is msgpack([1,2,3]), pack('CCCC', 0x93, 1, 2, 3), 'msgpack [ 1, 2, 3 ]';
is msgpack([[],2,3]), pack('CCCC', 0x93, 0x90, 2, 3), 'msgpack [ [], 2, 3 ]';
is msgpack([[1],2,3]), pack('CCCCC', 0x93, 0x91, 1, 2, 3),
    'msgpack [ [1], 2, 3 ]';
is msgpack([(1) x 15]), pack('C*', 0x9F, (1)x 15), 'msgpack[(1)x15]';
is msgpack([(1) x 16]), pack('CnC*', 0xDC, 16, (1)x 16), 'msgpack[(1)x16]';
is msgpack([(1) x 0xFFFF]), pack('CnC*', 0xDC, 0xFFFF, (1)x 0xFFFF),
    'msgpack[(1)xFFFF]';
is msgpack([(1) x 0x10000]), pack('CNC*', 0xDD, 0x10000, (1)x 0x10000),
    'msgpack[(1)x10000]';

note 'hashes';
is msgpack({}), pack('C', 0x80), 'empty hash';
is substr(msgpack({ map {($_ => 1)} 1 .. 10 }), 0, 1), pack('C', 0x80 | 10),
        'msgpack { 10 elements }';


#=============================================================================
note 'unpack';


note ' floats';
is_deeply [ msgunpack msgpack 1.7 ], [ 1.7, 1 + 8 ], '1.7';
is_deeply [ msgunpack msgpack -3.2 ], [ -3.2, 1 + 8 ], '-3.2';

note ' positive integers';
is_deeply [ msgunpack(pack('C', 0xC0)) ], [ undef, 1 ], 'nil';
is_deeply [ msgunpack(pack('C', 0xC2)) ], [ 0, 1 ], 'false';
is_deeply [ msgunpack(pack('C', 0xC3)) ], [ 1, 1 ], 'true';
is_deeply [ msgunpack(msgpack(0)) ], [ 0, 1 ], 'zero';
is_deeply [ msgunpack(msgpack(0x7F)) ], [ 0x7F, 1 ], 'msgunpack msgpack 0x7F';
is_deeply [ msgunpack(msgpack(0x80)) ], [ 0x80, 2],  'msgunpack msgpack 0x80';
is_deeply [ msgunpack(msgpack(0xFF)) ], [ 0xFF, 2], 'msgunpack msgpack 0xFF';
is_deeply [ msgunpack(msgpack(0x100)) ], [ 0x100, 3 ],
    'msgunpack msgpack 0x100';
is_deeply [ msgunpack(msgpack(0xFFFF)) ], [ 0xFFFF, 3 ],
    'msgunpack msgpack 0xFFFF';
is_deeply [ msgunpack(msgpack(0x10000)) ], [ 0x10000, 5 ],
    'msgunpack msgpack 0x10000';
is_deeply [ msgunpack(msgpack(0xFFFFFFFF)) ], [ 0xFFFFFFFF, 5 ],
    'msgunpack msgpack 0xFFFF_FFFF';
is_deeply [ msgunpack(msgpack(0x100000000)) ], [ 0x100000000, 9 ],
    'msgunpack msgpack 0x10000_0000';

note ' negative integers';
is_deeply [ msgunpack(msgpack(-1)) ], [ -1, 1 ], 'msgunpack msgpack -1';
is_deeply [ msgunpack(msgpack(-0x1F)) ], [ -0x1F, 1 ],
    'msgunpack msgpack -0x1F';
is_deeply [ msgunpack(msgpack(-0x20)) ], [ -0x20, 2 ],
    'msgunpack msgpack -0x20';
is_deeply [ msgunpack(msgpack(-0xFF)) ], [ -0xFF, 3 ],
    'msgunpack msgpack -0xFF';
is_deeply [ msgunpack(msgpack(-0x100)) ], [ -0x100, 3 ],
    'msgunpack msgpack -0x100';
is_deeply [ msgunpack(msgpack(-0x7FFF)) ], [ -0x7FFF, 3 ],
    'msgunpack msgpack -0x7FFF';
is_deeply [ msgunpack(msgpack(-0x8000)) ], [ -0x8000, 5 ],
    'msgunpack msgpack -0x8000';
is_deeply [ msgunpack(msgpack(-0x7FFFFFFF)) ], [ -0x7FFFFFFF, 5 ],
    'msgunpack msgpack -0x7FFFFFFF';
is_deeply [ msgunpack(msgpack(-0x80000000)) ], [ -0x80000000, 9 ],
    'msgunpack msgpack -0x80000000';

note ' strings';
is_deeply [ msgunpack(msgpack('')) ], [ '', 1 ], 'empty string';
is_deeply [ msgunpack(msgpack('abc')) ], [ 'abc', 4 ],
    'msgunpack msgpack "abc"';
{
    local $TntCompat::Msgpack::UTF8STR = 1;
    is_deeply [ msgunpack(msgpack('тест')) ], [ 'тест', 9 ],
        'msgunpack msgpack "тест" (utf8)';
}
is_deeply [ msgunpack(msgpack('x' x 31) . 'a') ], [ 'x' x 31, 31 + 1 ],
    'msgunpack msgpack 31-octets string';
is_deeply [ msgunpack(msgpack('x' x 31)) ], [ 'x' x 31, 31 + 1 ],
    'msgunpack msgpack 31-octets string';
is_deeply [ msgunpack(msgpack('x' x 32)) ], [ 'x' x 32, 32 + 2 ],
    'msgunpack msgpack 32-octets string';
is_deeply [ msgunpack(msgpack('x' x 255)) ], [ 'x' x 255, 255 + 1 + 1 ],
    'msgunpack msgpack 255-octets string';
is_deeply [ msgunpack(msgpack('x' x 256)) ], [ 'x' x 256, 256 + 1 + 2 ],
    'msgunpack msgpack 256-octets string';
is_deeply [ msgunpack(msgpack('x' x 32767)) ], [ 'x' x 32767, 32767 + 1 + 2 ],
    'msgunpack msgpack 32767-octets string';
is_deeply [ msgunpack(msgpack('x' x 65535)) ], [ 'x' x 65535, 65535 + 1 + 2 ],
    'msgunpack msgpack 65535-octets string';
is_deeply [ msgunpack(msgpack('x' x 65536)) ], [ 'x' x 65536, 65536 + 1 + 4 ],
    'msgunpack msgpack 65536-octets string';

note ' arrays';
is_deeply [ msgunpack msgpack [] ], [ [], 1 ], 'empty array';
is_deeply [ msgunpack msgpack [1, 2, -3] ], [ [1, 2, -3], 4 ], '[1, 2, -3]';
is_deeply [ msgunpack msgpack [[1, [2]], 3 ] ],
                            [ [[1, [2]], 3 ], 6], '[[1, [2]], 3 ]';

is_deeply [ msgunpack msgpack [(1) x 15 ]], [[(1) x 15], 15 + 1], 'array(15)';
is_deeply [ msgunpack msgpack [(1) x 16 ]], [[(1) x 16], 16 + 3], 'array(16)';
is_deeply [ msgunpack msgpack [(1) x 0xFFFF ]], [[(1) x 0xFFFF], 0xFFFF + 3],
    'array(0xFFFF)';
is_deeply [ msgunpack msgpack [(1) x 0x10000 ]], [[(1) x 0x10000], 0x10000 + 5],
    'array(0x10000)';

note ' hashes';
is_deeply [ msgunpack msgpack {} ], [ {}, 1 ], 'empty hash';
is_deeply [ msgunpack msgpack {1 => 2} ], [ {1 => 2}, 1 + 2 ], '{ 1 => 2}';
is_deeply [ msgunpack msgpack {1 => { 2 => { 3 => undef }, 4 => 5 } } ],
    [ {1 => { 2 => { 3 => undef }, 4 => 5 } }, 6 + 3 ],
    '{1 => { 2 => { 3 => undef }, 4 => 5 } }';

is_deeply [ msgunpack msgpack {map {($_ => $_)} 1 .. 15} ],
    [ {map {($_ => $_)} 1 .. 15}, 15 * 2 + 1 ],
    'hashlen=15';
is_deeply [ msgunpack msgpack {map {($_ => $_)} 1 .. 16} ],
    [ {map {($_ => $_)} 1 .. 16}, 16 * 2 + 1 + 2 ],
    'hashlen=16';

is_deeply scalar msgunpack msgpack {map {($_ => $_)} 1 .. 65535},
    {map {($_ => $_)} 1 .. 65535},
    'hashlen=65535';
is_deeply scalar msgunpack msgpack {map {($_ => $_)} 1 .. 65536},
    {map {($_ => $_)} 1 .. 65536},
    'hashlen=65536';


note 'other tests';
is_deeply [ msgunpack "\x82\x02\x01\x00\x40" ], [ { 0 => 64, 2 => 1  }, 5 ],
    'test1';

note 'strings';
is msgpack(string 123), pack('Ca*',   0xA3 , 123),
    'msgpack msgpackstring 123';

is_deeply [ msgunpack msgpack string '123' ],
    [ 123, 4 ], 'msgpackstring';
