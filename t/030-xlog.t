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

    use_ok 'TntCompat::Cat::Xlog';
}

my $reader = TntCompat::Cat::Xlog->new;
isa_ok $reader => 'TntCompat::Cat::Xlog';

my $snap = catfile dirname(__FILE__), 'data/easy/00000000000000000002.xlog';
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
    my ($lsn, $type, $space, $key, $ops) = @_;
    push @res => [ $lsn, $type, $space, $key, $ops ]
});

for (my $i = 0; $i < length $snap; $i++) {
    my $char = substr $snap, $i, 1;
    $reader->data($char);
}


is_deeply \@res, [
  [2,  'insert', 0, [ pack('L<', 1), pack('L<', 2), pack('L<', 3) ], undef],
  [3,  'replace', 0, [ pack('L<', 1), pack('L<', 3), pack('L<', 5) ], undef],
  [4,  'update',  0, [ pack('L<', 1) ], [ [ '=', 2, pack('L<', 4) ] ]],
  [5,  'delete', 0, [ pack('L<', 1) ], undef],
  [6,  'insert', 0, [ pack('L<', 1), pack('L<', 2), pack('L<', 3) ], undef],
  [7,  'insert', 0, [ pack('L<', 2), pack('L<', 3), pack('L<', 4) ], undef],
  [8,  'insert', 0, [ pack('L<', 3), pack('L<', 4), pack('L<', 5) ], undef],
  [9,  'update', 0, [ pack('L<', 3) ], [ [ '#', 2, 1 ], [ '!', 2, 'helo' ] ]],
  [10, 'update', 0, [ pack('L<', 3) ], [ [ ':', 2, 2, 1, 'l' ] ]]
], 'result';

