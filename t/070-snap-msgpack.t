#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 4;
use Encode qw(decode encode);
use File::Spec::Functions 'catfile', 'rel2abs';
use File::Basename 'dirname';


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    use_ok 'TntCompat::Cat::SnapMsgpack';
}

my $reader = TntCompat::Cat::SnapMsgpack->new;
isa_ok $reader => 'TntCompat::Cat::SnapMsgpack';

my $snap = catfile dirname(__FILE__), 'data/1.6/bootstrap.snap';
ok -r $snap, "-r $snap";


# read snapshot
{
    open my $f, '<:raw', $snap or die "Can't open file $snap: $!\n";
    local $/;
    $snap = <$f>;
    close $f;
}

my @res;
$reader->on_row(sub {
    my ($lsn, $type, $space, $row) = @_;
    push @res => [ $lsn, $type, $space, $row ]
});

for (my $i = 0; $i < length $snap; $i++) {
    my $char = substr $snap, $i, 1;
    $reader->data($char);
}


is_deeply \@res,
[
  [ 1, 'insert', 272, [ 'version', 1, 6 ] ],
  [ 2, 'insert', 280, [ 272, 1, '_schema', 'memtx', 0 ] ],
  [ 3, 'insert', 280, [ 280, 1, '_space', 'memtx', 0 ] ],
  [ 4, 'insert', 280, [ 288, 1, '_index', 'memtx', 0 ] ],
  [ 5, 'insert', 280, [ 296, 1, '_func', 'memtx', 0 ] ],
  [ 6, 'insert', 280, [ 304, 1, '_user', 'memtx', 0 ] ],
  [ 7, 'insert', 280, [ 312, 1, '_priv', 'memtx', 0 ] ],
  [ 8, 'insert', 280, [ 320, 1, '_cluster', 'memtx', 0 ] ],
  [ 9, 'insert', 288, [ 272, 0, 'primary', 'tree', 1, 1, 0, 'str' ] ],
  [ 10, 'insert', 288, [ 280, 0, 'primary', 'tree', 1, 1, 0, 'num' ] ],
  [ 11, 'insert', 288, [ 280, 1, 'owner', 'tree', 0, 1, 1, 'num' ] ],
  [ 12, 'insert', 288, [ 280, 2, 'name', 'tree', 1, 1, 2, 'str' ] ],
  [ 13, 'insert', 288,
        [ 288, 0, 'primary', 'tree', 1, 2, 0, 'num', 1, 'num' ] ],
  [ 14, 'insert', 288, [ 288, 2, 'name', 'tree', 1, 2, 0, 'num', 2, 'str' ] ],
  [ 15, 'insert', 288, [ 296, 0, 'primary', 'tree', 1, 1, 0, 'num' ] ],
  [ 16, 'insert', 288, [ 296, 1, 'owner', 'tree', 0, 1, 1, 'num' ] ],
  [ 17, 'insert', 288, [ 296, 2, 'name', 'tree', 1, 1, 2, 'str' ] ],
  [ 18, 'insert', 288, [ 304, 0, 'primary', 'tree', 1, 1, 0, 'num' ] ],
  [ 19, 'insert', 288, [ 304, 1, 'owner', 'tree', 0, 1, 1, 'num' ] ],
  [ 20, 'insert', 288, [ 304, 2, 'name', 'tree', 1, 1, 2, 'str' ] ],
  [ 21, 'insert', 288,
        [ 312, 0, 'primary', 'tree', 1, 3, 1, 'num', 2, 'str', 3, 'num' ] ],
  [ 22, 'insert', 288, [ 312, 1, 'owner', 'tree', 0, 1, 1, 'num' ] ],
  [ 23, 'insert', 288, [ 312, 2, 'object', 'tree', 0, 2, 2, 'str', 3, 'num' ] ],
  [ 24, 'insert', 288, [ 320, 0, 'primary', 'tree', 1, 1, 0, 'num' ] ],
  [ 25, 'insert', 288, [ 320, 1, 'uuid', 'tree', 1, 1, 1, 'str' ] ],
  [ 26, 'insert', 304, [ 0, 1, 'guest', 'user' ] ],
  [ 27, 'insert', 304, [ 1, 1, 'admin', 'user' ] ],
  [ 28, 'insert', 304, [ 2, 1, 'public', 'role' ] ],
  [ 29, 'insert', 320, [ 1, '3dc7b72d-d335-4fdd-81fa-90b36c9b8baf' ] ]
], 'result';

