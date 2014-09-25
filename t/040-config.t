#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 4;
use Encode qw(decode encode);

use File::Basename 'dirname';
use File::Spec::Functions 'catfile', 'rel2abs';

my $file;

BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    use_ok 'TntCompat::Config';

    $file = catfile dirname(__FILE__), 'data/sample.cfg';
    ok -r $file, "-r $file";
}


my $cfg = TntCompat::Config->new($file);
ok $cfg, 'File was read';
is $cfg->get('access.user'), 'vasya', 'get argument';



