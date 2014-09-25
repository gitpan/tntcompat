use utf8;
use strict;
use warnings;

package TntCompat::Config;
use File::Spec::Functions 'catfile';
use Carp;
use Data::Dumper;
use TntCompat::Debug;
use Scalar::Util 'looks_like_number';
use MIME::Base64;
use Encode qw(decode);
use feature 'state';

sub new {
    my ($class, $name) = @_;
    die "File $name not found" unless -r $name;
    my $cfg = do $name;
    die $@ if $@;
    my $self = bless { data => $cfg, name => $name } => ref($class) || $class;
    $self;
}

sub new_from_hash {
    my ($class, $hash) = @_;
    my $self = bless { data => $hash, name => 'hash' } => ref($class) || $class;
    $self;
}

sub get {
    my ($self, $path) = @_;

    my @sp = split /\./, $path;
    my $o = $self->{data};
    my $fpath = '';

    for (@sp) {
        $fpath .= '.' if length $fpath;
        $fpath .= $_;
        croak "Path '$fpath' is not found in config file $self->{name}"
            unless exists $o->{$_};
        $o = $o->{$_};
    }
    return $o;
}


sub _set_defaults {
    my ($self) = @_;
    my $data = $self->{data};

    DEBUGF 'Check config file and apply defaults';

    $data->{skip_spaces} ||= [];


    for (qw(host port user password snap_dir wal_dir)) {
        die "$_ is not defined in config\n" unless exists $data->{$_};
    }

    for (qw(server_uuid cluster_uuid)) {
        die "$_ is not defined in config" unless defined $data->{$_};
        $data->{$_} =~ s/^(.{8})(.{4})(.{4})(.{4})/$1-$2-$3-$4-/
            if $data->{$_} =~ /^[0-9a-fA-F]{32}$/;
        die "invalid format of uuid ($_): $data->{$_}\n"
            unless $data->{$_} =~
                /^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/;
    }

    unless (exists $data->{bootstrap}) {
        $data->{bootstrap} = undef;

        state $bs;
        unless (defined $bs) {
            local $/;
            $bs = <DATA>;
            $bs = MIME::Base64::decode $bs;
        }

        $data->{bootstrap_data} = $bs;

    } else {
        die "Can't find bootstrap: $data->{bootstrap}\n"
            unless -r $data->{bootstrap};

        open my $fh, '<:raw', $data->{bootstrap}
            or die "Can't read bootstrap file $data->{bootstrap}: " .
                decode utf8 => $!;
        local $/;
        my $bs = <$fh>;
        close $fh;
        $data->{bootstrap_data} = $bs;
    }

    my $schema = $data->{schema};
    die "schema is not defined in config\n" unless 'HASH' eq ref $schema;


    for (keys %$schema) {
        die "Wrong space number $_" unless /^\d+$/;
    }

    for (sort { $a <=> $b } keys %$schema) {
        DEBUGF 'Check config space %s', $_;
        unless (exists $schema->{$_}{name}) {
            DEBUGF 'space[%s].name is not defined, use space_%s', $_, $_;
            $schema->{$_}{name} = "space_$_";
        }

        unless ($schema->{$_}{default_field_type}) {
            DEBUGF 'use default_field_type for space %s as STR', $_;
            $schema->{$_}{default_field_type} = 'STR';
        }


        if ('ARRAY' eq ref $schema->{$_}{fields}) {
            my $sno = $_;
            my %fields =
                map {($_ => $schema->{$sno}{fields}[$_]) }
                    0 .. $#{ $schema->{$sno}{fields} };

            for (keys %fields) {
                $fields{$_} = { name => $fields{$_} } unless ref $fields{$_};
            }
            $schema->{$_}{fields} = \%fields;
        }


        if ('HASH' eq ref $schema->{$_}{fields}) {
            for my $fno (keys %{ $schema->{$_}{fields} }) {
                die "Wrong field no ($fno) in space $_\n"
                    unless $fno =~ /^\d+$/;

                if (!ref $schema->{$_}{fields}{$fno}) {
                    $schema->{$_}{fields}{$fno} = {
                        type    => $schema->{$_}{fields}{$fno},
                    }
                } elsif ('HASH' ne ref $schema->{$_}{fields}{$fno}) {
                    die "Wrong field ($fno) definition in space $_\n";
                }

                $schema->{$_}{fields}{$fno}{type} ||= 'STR';
                $schema->{$_}{fields}{$fno}{name} ||= "field_$fno";
                $schema->{$_}{fields}{$fno}{no} = $fno;


                my $type = uc $schema->{$_}{fields}{$fno}{type};

                die "Wrong space[$_].field[$fno] type: $type\n"
                    unless $type =~ /^(NUM|NUM64|STR|JSON|MONEY)$/
            }
        } else {
            die "Wrong space[$_].fields\n";
        }


        my $idxs = $schema->{$_}{indexes};
        die "Undefined section 'indexes' for space $_\n"
            unless $idxs and 'ARRAY' eq ref $idxs;


        for (my $i = 0; $i < @$idxs; $i++) {
            my $idx = $idxs->[$i];

            die "space[%s].index[%s].fields is not defined\n", $_, $i
                unless exists $idx->{fields};

            $idx->{fields} = [ $idx->{fields} ] unless ref $idx->{fields};



            my @idef;
            for my $fd (@{ $idx->{fields} }) {
                if (looks_like_number $fd) {
                    my $type =
                        $schema->{$_}{fields}{$fd} ?
                            $schema->{$_}{fields}{$fd}{type}
                                || $schema->{$_}{default_field_type} || 'STR' :                                     $schema->{$_}{default_field_type} || 'STR';
                    $type = lc $type;
                    $type = 'num' if $type eq 'num64';
                    $type = 'num' if $type eq 'money';
                    die "Wrong index type: $type\n"
                        unless $type =~ /^(num|str)$/;

                    push @idef => ($fd => $type);
                } else {
                    my ($fdef) = grep { $_->{name} eq $fd  }
                        values %{ $schema->{$_}{fields} };
                    die "field '$fd' is not found in config.space[$_]\n"
                        unless $fdef;

                    my $no = $fdef->{no};
                    my $type =
                        $schema->{$_}{fields}{$no} ?
                            $schema->{$_}{fields}{$no}{type}
                                || $schema->{$_}{default_field_type} || 'STR' :                                     $schema->{$_}{default_field_type} || 'STR';

                    $type = lc $type;
                    $type = 'num' if $type eq 'num64';
                    $type = 'num' if $type eq 'money';
                    push @idef => ( $no => $type );

                }
            }

            $idx->{fields} = \@idef;

            DEBUGF 'space[%s].index[%s].def = [%s]',
                $_, $i, join ', ', @idef;

        }
    }

    return $self;
}


use base qw(Exporter);
our @EXPORT = qw(cfg);

my $cfgimport;

sub import {
    my ($package, @args) = @_;
    if (@args == 1) {
        my $file = shift @args;
        $cfgimport = $package->new($file);
    }
    $package->export_to_level(1, $package, @args);
}

sub cfg($) { return $cfgimport->get($_[0]) }

1;

# bootstrap.snap - is empty database of tarantool1.6
# here is base64 dump of the file
# base64 ./t/data/1.6/bootstrap.snap
__DATA__
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
EK3t
