use utf8;
use strict;
use warnings;

package TntCompat::UUID;
use base qw(Exporter);
use UUID;

our @EXPORT = qw(uuid_hex);

sub uuid_hex() {
    my $uuid;
    no utf8;
    UUID::generate $uuid;
    for ($uuid) {
        s/./sprintf '%02x', ord $&/ges;
        s/^(.{8})(.{4})(.{4})(.{4})/$1-$2-$3-$4-/;
    }
    $uuid;
}

1;
