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

    use_ok 'TntCompat::Cat::Snap';
}

my $reader = TntCompat::Cat::Snap->new;
isa_ok $reader => 'TntCompat::Cat::Snap';

my $snap = catfile dirname(__FILE__), 'data/easy/00000000000000000008.snap';
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

is_deeply \@res, [
    [ 0, 'insert', 0, [ map { pack 'L<', $_ } 1, 2, 3 ]],
    [ 0, 'insert', 0, [ map { pack 'L<', $_ } 2, 3, 4 ]],
    [ 0, 'insert', 0, [ map { pack 'L<', $_ } 3, 4, 5 ]],

], 'result';

