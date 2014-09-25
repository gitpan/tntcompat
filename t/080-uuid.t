#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 4;
use Encode qw(decode encode);


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    use_ok 'TntCompat::UUID';
}

ok uuid_hex, 'uuid is generated';
like uuid_hex, qr/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/, 'format';
isnt uuid_hex, uuid_hex, "two uuids aren't the same";

