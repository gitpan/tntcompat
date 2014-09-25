use utf8;
use strict;
use warnings;

package TntCompat::Debug;
use base qw(Exporter);
our @EXPORT = qw(DEBUGF);
use POSIX;

our $DEBUG = $ENV{DEBUG};

sub DEBUGF($;@) {
    my ($fmt, @args) = @_;
    return unless $DEBUG;

    my $str = @args ? sprintf($fmt, @args) : $fmt;
    $str =~ s/\s*$/\n/;
    printf "%s: %s", POSIX::strftime('%F %T', localtime), $str;
}

1;
