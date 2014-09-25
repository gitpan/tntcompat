use utf8;
use strict;
use warnings;

package TntCompat::Server;

use Coro;
use Coro::AnyEvent;
use AnyEvent::Socket;
use TntCompat::Config;
use TntCompat::Debug;
use Coro::Handle;
use Errno qw(EAGAIN EINTR EINPROGRESS);
use TntCompat::Proto;
use TntCompat::Msgpack;
use MIME::Base64;
use Encode qw(decode encode);
use Data::Dumper;
use Carp;
use File::Spec::Functions 'catfile';

use TntCompat::Cat::SnapMsgpack;
use TntCompat::Cat::Snap;
use TntCompat::Cat::Xlog;
use JSON::XS;
use File::Basename 'basename';
use feature 'state';


sub strhex($) {
    my ($str) = @_;
    $str =~ s/./sprintf '.%02x', ord $&/ges;
    return $str;
}

sub new {
    my ($class, $cfgfile) = @_;
    my $cfg;
    if (ref $cfgfile) {
        $cfg = $cfgfile;
    } else {
        $cfg = TntCompat::Config->new($cfgfile) unless ref $cfgfile;
    }
    $cfg->_set_defaults;


    my $self = bless {
        cfg         => $cfg,
        lsn         => {},
        wbuf        => {},
        enable_wbuf => {},
    } => ref($class) || $class;

    $self->{skip} = { map {( $_ => 1 )} @{ $self->{cfg}->get('skip_spaces') }};


    my $server;
    DEBUGF 'Create server at %s:%s',
        $cfg->get('host') || '', $cfg->get('port') || '';
    $self->{guard} =
        tcp_server $cfg->get('host'), $cfg->get('port'), $self->on_connect;

    unless ($self->{guard}) {
        die $!;
    }
    

    return $self;
}


sub is_space_skip {
    my ($self, $space) = @_;
    return 0 unless exists $self->{skip}{$space};
    return 1;
}


sub host            { $_[0]->{cfg}->get('host') }
sub port            { $_[0]->{cfg}->get('port') }
sub wal_dir         { $_[0]->{cfg}->get('wal_dir') }
sub snap_dir        { $_[0]->{cfg}->get('snap_dir') }
sub bootstrap       { $_[0]->{cfg}->get('bootstrap_data') }
sub server_uuid     { $_[0]->{cfg}->get('server_uuid') }
sub cluster_uuid    { $_[0]->{cfg}->get('cluster_uuid') }


sub lsn {
    my ($self, $fd) = @_;
    $fd ||= 0;
    $fd = fileno $fd if ref $fd;
    $self->{lsn}{$fd} = 0 unless $self->{lsn}{$fd};
    $self->{lsn}{$fd}++;
    return $self->{lsn}{$fd};
}

sub clean_lsn {
    my ($self, $fd) = @_;
    $fd ||= 0;
    $fd = fileno $fd if ref $fd;
    $self->{lsn}{$fd} = 0;
}

sub schema      {
    my ($self, $sno) = @_;
    my $schema = $self->{cfg}->get('schema');
    return $schema unless @_ > 1;
    croak "Unknown space number: $sno" unless exists $schema->{$sno};
    return $schema->{$sno};
}

sub run {
    Coro::schedule;
}

sub on_connect {
    my ($self) = @_;
    sub {
        my ($fh, $host, $port) = @_;
        binmode $fh => ':raw';
        DEBUGF 'Connection from %s:%s', $host // '', $port // '';
        async { $self->downlink(Coro::Handle->new_from_fh($fh)); }
    }
}


sub read_request {
    my ($self, $fh) = @_;

    my $r = '';


    while($fh->readable) {
        my $len = 5;
        if (length $r) {

            my ($dlen, $doff) = msgunpack $r;
            if (defined $doff) {
                $len = $doff  + $dlen; # total len
                $len = $len - length $r;
            } else {
                $len = 5 - length $r;
                if ($len <= 0) {
                    DEBUGF 'Broken request length';
                    return;
                }
            }
        }

        my $rd = sysread $fh, $r, $len, length $r;
        if (defined $rd) {
            next unless $rd == $len;

            my ($dlen, $doff) = msgunpack $r;
            next unless $doff  + $dlen == length $r;
            return TntCompat::Proto::parse_response $r;
        } else {
            DEBUGF 'Error reading socket: %s', decode utf8 => $!;
            return;
        }
    }
}


sub send_response {
    my ($self, $fh, $resp) = @_;

    my $no = fileno $fh;
    if ($self->{enable_wbuf}{$no}) {

        $self->{wbuf}{$no} //= '';
        if (length $self->{wbuf}{$no} < 50_000) {
            $self->{wbuf}{$no} .= $resp;
            return 1;
        }
    }

    $resp = delete($self->{wbuf}{$no}) . $resp if defined $self->{wbuf}{$no};

    while($fh->writable and length $resp) {
        my $rc = syswrite $fh, $resp;
        unless (defined $rc) {
            DEBUGF 'Can not send response: %s', decode utf8 => $!;
            last;
        }

        return 1 if $rc == length $resp;
        substr $resp, 0, $rc, '';
    }
    return 0;
}


sub enable_wbuf {
    my ($self, $fh) = @_;
    my $no = fileno $fh;

    $self->{enable_wbuf}{$no} = 1;
}

sub disable_wbuf {
    my ($self, $fh) = @_;
    my $no = fileno $fh;
    delete $self->{enable_wbuf}{$no};
}


sub ping {
    my ($self, $fh, $request) = @_;
    # pong
    my $pkt = TntCompat::Proto::make_response($request->{SYNC}, 0);
    if ($self->send_response($fh, $pkt)) {
        DEBUGF 'Client <- pong';
        return 1;
    }
    return 0;
}

sub auth {
    my ($self, $fh, $request, $salt) = @_;

    my ($retval, $code, $message) = (-1, 0x2000_0000 | 42, 'Auth error');


    unless (ref($request->{TUPLE}) eq 'ARRAY') {
        $code = 0x2000_0000 | 22;
        $message = 'Tuple/Key must be MsgPack array';
        goto ERROR;
    }

    unless ($request->{TUPLE}[0] and $request->{TUPLE}[0] eq 'chap-sha1') {
        $code = 0x2000_0000 | 42;
        $message = 'Unknown chap-type: ' . $request->{TUPLE}[0] // 'undef';
        goto ERROR;
    }

    unless($request->{TUPLE}[1] and length $request->{TUPLE}[1] == 20) {
        $code = 0x2000_0000 | 42;
        $message = 'Wrong length of password hash';
        if ($request->{TUPLE}[1]) {
            $message .= ': ' . length $request->{TUPLE}[1];
        }
        goto ERROR;
    }

    unless (defined $request->{USER_NAME}) {
        $code = 0x2000_0000 | 42;
        $message = 'No username in request';
        goto ERROR;
    }

    unless ($self->{cfg}->get('user') eq $request->{USER_NAME}) {
        $code = 0x2000_0000 | 42;
        $message = 'Wrong username in request';
        goto ERROR;
    }

    my $chk = TntCompat::Proto::check_auth(
        $request->{TUPLE}[1], $salt, $self->{cfg}->get('password'));

    unless ($chk) {
        $code = 0x2000_0000 | 42;
        $message = sprintf 'Wrong password for user %s', $request->{USER_NAME};
        goto ERROR;
    }

    $code = 0;
    $message = [];
    $retval = 1;

    ERROR:
        DEBUGF 'Can not auth client: %s', $message if $code;
        my $pkt = TntCompat::Proto::make_response(
                            $request->{SYNC}, $code, $message);
        return 0 unless $self->send_response($fh, $pkt);
        return $retval;
}


sub _join_bootstrap {
    DEBUGF 'Send bootstrap';
    my ($self, $fh, $request) = @_;
    my $bootstrap = TntCompat::Cat::SnapMsgpack->new;

    my $send = 1;
    $bootstrap->on_row(sub {
        my ($lsn, $type, $space, $row) = @_;

        # skip _cluster space
        if ($space == TntCompat::Proto::SC_CLUSTER_ID) {
            return;
        }

        # skip 'cluster' record in _schema
        if ($space == TntCompat::Proto::SC_SCHEMA_ID) {
            return if $row->[0] and $row->[0] eq 'cluster';
        }

        my $pkt = TntCompat::Proto::insert
            $request->{SYNC},
            $self->lsn($fh),
            $space, $row, { server_id => 0 };

        unless ($self->send_response($fh, $pkt)) {
            DEBUGF "Can't send bootstrap row for space %s", $space;
            $send = 0;
            return;
        }
        DEBUGF 'Sent bootstrap row space: %s', $space;
    });

    $bootstrap->data($self->bootstrap);
    return 0 unless $send;



    my $pkt = TntCompat::Proto::insert
                    $request->{SYNC},
                    $self->lsn($fh),
                    TntCompat::Proto::SC_SCHEMA_ID,
                    [ 'cluster' => $self->cluster_uuid ],
                    { server_id => 0 };
    return 0 unless $self->send_response($fh, $pkt);

    $pkt = TntCompat::Proto::insert
                    $request->{SYNC},
                    $self->lsn($fh),
                    TntCompat::Proto::SC_CLUSTER_ID,
                    [ 1, $self->server_uuid ],
                    { server_id => 0 };
    return 0 unless $self->send_response($fh, $pkt);

    return 1;
}


sub _join_schema {
    DEBUGF 'Send schema';
    my ($self, $fh, $request) = @_;

    for my $sno (keys %{ $self->schema }) {
        my $space = $self->schema($sno);

        my $pkt = TntCompat::Proto::insert($request->{LSN}, $self->lsn($fh),
            TntCompat::Proto::SC_SPACE_ID, [
                $sno,                                   # space_id
                1,                                      # uid
                $space->{name} // 'space_' . $sno,      # space_name
                'memtx',                                # engine
                0,                                      # fields_count
                '',                                     # options
            ],
            { server_id => 0 }
        );

        return 0 unless $self->send_response($fh, $pkt);
        DEBUGF 'Space record about space %s was sent', $sno;

        for (my $ino = 0; $ino < @{ $space->{indexes} }; $ino++) {
            my $idx = $space->{indexes}[$ino];


            my $type = lc($idx->{type} || 'tree');
            $type = 'num' if $type eq 'num64';

            my $unique = $idx->{unique} ? 1 : 0;
            $unique = 1 if $ino == 0;
            my $name = $idx->{name} // 'idx_' . $ino;
            $name = 'pk' if $ino == 0 and !defined $idx->{name};

            my $ituple = [
                $sno,
                $ino,
                $name,
                $type,
                $unique,
                int(@{ $idx->{fields} } / 2),
                @{ $idx->{fields} }
            ];

            $pkt = TntCompat::Proto::insert
                $request->{LSN}, $self->lsn($fh),
                TntCompat::Proto::SC_INDEX_ID,
                $ituple,
                { server_id => 0 };
            return 0 unless $self->send_response($fh, $pkt);
            DEBUGF 'Index record about space[%s].index[%s] was sent',
                $sno, $ino;
        }
    }
    return 1;
}


sub _join_snapshot {
    DEBUGF 'Send snapshot';

    my ($self, $fh, $request) = @_;
    my $last_snap = [ sort glob catfile $self->snap_dir, '*.snap' ]->[-1];

    unless ($last_snap) {
        DEBUGF 'No one snapshot in %s', $self->snap_dir;
        return;
    }

    my $reader = TntCompat::Cat::Snap->new;


    my $last_lsn = $last_snap;
    for ($last_lsn) {
        s{.*/}{};
        s/^0+//;
        s/\.snap$//;
    }

    DEBUGF 'Send snapshot %s to client (lsn: %s)', $last_snap, $last_lsn;

    open my $fhb, '<:raw', $last_snap
        or die sprintf "Can't open snapshot file %s\n", $last_snap;

    my $send = 1;

    my $space_debug = -1;
    $reader->on_row(sub {
        my ($lsn, $type, $space, $row) = @_;


        # skip some spaces
        return if $self->is_space_skip($space);

        $row = $self->convert_row($space, $row);

        $lsn = $self->lsn($fh);

        my $pkt = TntCompat::Proto::insert
            $request->{SYNC}, $lsn, $space, $row, { server_id => 0 };

        DEBUGF 'Sending space[%s]...', $space unless $space == $space_debug;
        $space_debug = $space;

#         DEBUGF 'Sending snapshot row space: %s (lsn: %s)...', $space, $lsn;
        unless ($self->send_response($fh, $pkt)) {

            DEBUGF "Can't send snapshot row for space %s", $space;
            $send = undef;
            return;
        }
        DEBUGF 'Sent lsn = %s snapshot row', $lsn
            if $lsn % 10000 == 0;
    });

    while($send and sysread $fhb, my $data, 4096) {
        next unless length $data;
        $reader->data($data);
    }

    DEBUGF 'Snapshot was send fully';
    return 0 unless defined $send;
    return $last_lsn;
}

sub _join_cluster {
    DEBUGF 'Send cluster id';
    my ($self, $fh, $request) = @_;

    my $pkt = TntCompat::Proto::insert(
        $request->{SYNC},
        $self->lsn($fh),
        TntCompat::Proto::SC_CLUSTER_ID,
        [ 2, $request->{SERVER_UUID} ],
        { server_id => 0 }
    );
    return $self->send_response($fh, $pkt);
}


sub _join_vclock {
    my ($self, $fh, $request, $lsn) = @_;

    my $vclock = {
        1   => $lsn,
        2   => 0
    };

    my $pkt = TntCompat::Proto::vclock(
        $request->{SYNC}, $vclock, { server_id => 0 });
    return $self->send_response($fh, $pkt);
}

sub convert_row {
    my ($self, $space, $row) = @_;

    my $schema = $self->schema;
    my @res = @$row;

    return \@res unless exists $schema->{$space};
    
    for (my $fno = 0; $fno < @res; $fno++) {
        if (exists $schema->{$space}{fields}{$fno}) {
            my $ftype = $schema->{$space}{fields}{$fno}{type}
                || $schema->{$space}{default_field_type} || 'STR';

            if ('NUM' eq uc $ftype) {
                $res[ $fno ] = unpack 'L', $res[ $fno ];
            } elsif ('MONEY' eq uc $ftype) {
                $res[ $fno ] = unpack 'L', $res[ $fno ];
                $res[ $fno ] /= 100;
            } elsif ('NUM64' eq uc $ftype) {
                if (length $res[ $fno ] == 4) {
                    $res[ $fno ] = unpack 'L', $res[ $fno ];
                } else {
                    $res[ $fno ] = unpack 'Q', $res[ $fno ];
                }
            } elsif ('JSON' eq uc $ftype) {

                # TODO: decode str
                $res[ $fno ] = JSON::XS->new->decode($res[ $fno ] );

            } elsif ('STR' eq uc $ftype) {
                # force all unknown items as strings
                $res[ $fno ] = string $res[ $fno ];
            }
        }
    }

    return \@res;
}


sub convert_pk {
    my ($self, $space, $row) = @_;
    my @res = @$row;
    my $schema = $self->schema;

    return \@res unless exists $schema->{$space};
    return \@res unless exists $schema->{$space}{indexes};
    return \@res unless my $idx = $schema->{$space}{indexes}[0];
    return \@res unless my $fields = $idx->{fields};


    croak "Inconsistent primary key" unless @$fields  == @res * 2;

    for (my ($i, $fno) = (0, 0); $i < @$fields; $i += 2, $fno++) {
        
        my $type = $fields->[$i + 1]
                || $schema->{$space}{default_field_type} || 'STR';

        if ('NUM' eq uc $type) {
            $res[ $fno ] = unpack 'L', $res[ $fno ];
        } elsif ('MONEY' eq uc $type) {
            $res[ $fno ] = unpack 'L', $res[ $fno ];
            $res[ $fno ] /= 100;
        } elsif ('NUM64' eq uc $type) {
            if (length $res[ $fno ] == 4) {
                $res[ $fno ] = unpack 'L', $res[ $fno ];
            } else {
                $res[ $fno ] = unpack 'Q', $res[ $fno ];
            }
        } else {
            $res[ $fno ] = string $res[ $fno ];
        }
    }

    return \@res;
}

sub convert_ops {
    my ($self, $space, $oplist) = @_;
    my @res = @$oplist;
    my $schema = $self->schema;
    return \@res unless exists $schema->{$space};

    for (@res) {
        my $op  = $_->[0];
        my $fno = $_->[1];
        
        my $type = $schema->{$space}{fields}{$fno}{type} ||
            $schema->{$space}{default_field_type} || 'STR';

        # numbers (by opcopde)
        if ($op =~ /[+&|^]/) {
            if (length $_->[2] == 4) {
                $_->[2] = unpack 'L', $_->[2];
            } elsif(length $_->[2] == 8) {
                $_->[2] = unpack 'Q', $_->[2];
            } else {
                DEBUGF "Corrupted update in xlog (opcode: %s, space: %s)",
                    $op, $space;
            }
            $_->[2] /= 100 if 'MONEY' eq uc $type;
        
        } elsif ($op eq '=' or $op eq '!') {
            if ('NUM' eq uc $type) {
                $_->[2] = unpack 'L', $_->[2];
            } elsif ('MONEY' eq uc $type) {
                $_->[2] = unpack 'L', $_->[2];
                $_->[2] /= 100;
            } elsif ('NUM64' eq uc $type) {
                if (length $_->[2] == 4) {
                    $_->[2] = unpack 'L', $_->[2];
                } elsif (length $_->[2] == 8) {
                    $_->[2] = unpack 'Q', $_->[2];
                } else {
                    $_->[2] = string $_->[2];
                }
            } elsif ('JSON' eq uc $type) {

                # TODO: decode str
                $_->[2] = JSON::XS->new->decode($_->[2] );

            } else {
                $_->[2] = string $_->[2];
            }
        } elsif ($op eq '#') {
            $_->[2] = 1;
        } elsif ($op eq ':') {
            $_->[4] = string $_->[4];
        } else {
            DEBUGF "Unknown update opcode: `%s' (space: %s)", $op, $space;
        }
    }
    return \@res;
}


sub join_snapshot {
    my ($self, $fh, $request) = @_;

    eval {
        $self->enable_wbuf($fh);
        return unless $self->_join_bootstrap($fh, $request);
        return unless $self->_join_schema($fh, $request);
        my $lsn = $self->_join_snapshot($fh, $request);
        return unless $lsn;
        return unless $self->_join_cluster($fh, $request);

        $self->disable_wbuf($fh);
        return unless $self->_join_vclock($fh, $request, $lsn);
        DEBUGF 'Finished join';
    };
    if ($@) {
        DEBUGF 'Error while join: %s', $@;
        my $pkt = TntCompat::Proto::make_response($request->{SYNC},
            0x2000_0000 | 42,
            'error: ' . $@
        );
        unless ($self->send_response($fh, $pkt)) {
            DEBUGF "Can't send response to client";
        }
    }
}


sub subscribe {
    my ($self, $fh, $request) = @_;

    if ($request->{CLUSTER_UUID} ne $self->cluster_uuid) {
        my $pkt = TntCompat::Proto::make_response(
                            $request->{SYNC}, 0x2000_0000 | 63,
            sprintf "Cluster id of the replica %s doesn't ".
                "match cluster id of the master %s",
                $request->{CLUSTER_UUID} // 'undef',
                $self->cluster_uuid
        );

        $self->send_response($fh, $pkt);
        return 0;
    }


    unless (exists $request->{VCLOCK} and exists $request->{VCLOCK}{1}) {
        my $pkt = TntCompat::Proto::make_response(
                            $request->{SYNC}, 0x2000_0000 | 63,
                            "Invalid vclock"
        );

        $self->send_response($fh, $pkt);
        return 0
    }

    my $lsn = $request->{VCLOCK}{1};
    DEBUGF 'Client subscribe since LSN=%s', $lsn;

    my ($file, $prev_file);
    while(1) {
        $file = $self->_wait_xlog($lsn, $prev_file);
        next unless $file;
        $prev_file = $file;
        
        DEBUGF 'Send %s xlog file to client', $file;



        my $f;
        unless (open $f, '<:raw', $file) {
            DEBUGF "Can't open file %s: %s", $file, decode utf8 => $!;
            next;
        }
        
        my $send = 1;
        my $xlog = new TntCompat::Cat::Xlog;
        $xlog->on_row(sub {
            my ($rlsn, $type, $space, $row, @args) = @_;
            return unless $send;

            # SKIP old lsns
            return if $rlsn <= $lsn;


#             DEBUGF 'Send record for space %s.%s (lsn=%s)', $space, $type, $rlsn;
            if ($rlsn > $lsn + 1) {
                DEBUGF 'LSN hole from lsn %s to lsn %s', $lsn, $rlsn;
                $send = 0;
                return;
            }
            $lsn = $rlsn;


            my $pkt;

            if ($type eq 'insert') {
                $pkt = TntCompat::Proto::insert
                    $request->{SYNC},
                    $lsn,
                    $space,
                    $self->convert_row($space, $row),
                    { server_id => 1 }
                ;
            } elsif ($type eq 'replace') {
                $pkt = TntCompat::Proto::replace
                    $request->{SYNC},
                    $lsn,
                    $space,
                    $self->convert_row($space, $row),
                    { server_id => 1 }
                ;
            } elsif ($type eq 'update') {
                $pkt = TntCompat::Proto::update
                    $request->{SYNC},
                    $lsn,
                    $space,
                    $self->convert_pk($space, $row),
                    $self->convert_ops($space, $args[0]),
                    { server_id => 1 }
                ;
            } elsif ($type eq 'delete') {
                $pkt = TntCompat::Proto::del
                    $request->{SYNC},
                    $lsn,
                    $space,
                    $self->convert_pk($space, $row),
                    { server_id => 1 }
                ;
            }

            unless (defined $pkt) {
                croak "Can't convert $type command";
            }

            if ($self->is_space_skip($space)) {
                DEBUGF 'Skip space %s.%s record', $space, $type;
            } else {
                unless ($self->send_response($fh, $pkt)) {
                    DEBUGF "Can't send xlog row for space %s, lsn: %s",
                        $space, $lsn;
                    $send = 0;
                    return;
                }
                DEBUGF 'Sent xlog row space: %s, lsn: %s', $space, $lsn
                    if $lsn % 10000 == 0;
            }
        });

        READ_PROCESS: while($send) {

            while($send) {
                my $rd = sysread $f, my $data, 4096;
                unless (defined $rd) {
                    DEBUGF "Can't read file %s: %s", $file, decode utf8 => $!;
                    last READ_PROCESS;
                }

                last unless length $data;
                $xlog->data($data);
            }

            return 0 unless $send;

            my @xlogs = sort glob catfile $self->wal_dir, '*.xlog';
            for (@xlogs) {
                next if $_ le $file;
                last READ_PROCESS;
            }
            Coro::AnyEvent::sleep .5;
        }
    }
}

sub _wait_xlog {
    my ($self, $lsn, $file) = @_;

    my $do_wait = 1;
    my @xlogs = glob catfile $self->wal_dir, '*.xlog';

CHECK:
    goto WAIT unless @xlogs;
    @xlogs = sort @xlogs;

    while(my $xlog = shift @xlogs) {
        # skip file that was already sent
        next if $file and $xlog eq $file;

        my $xlog_lsn = basename $xlog, '.xlog';
        $xlog_lsn =~ s/^0+//;
        goto WAIT unless $xlog_lsn <= $lsn + 1;
        return $xlog unless @xlogs;


        my $next_xlog = $xlogs[0];
        my $next_xlog_lsn = basename $next_xlog, '.xlog';
        $next_xlog_lsn =~ s/^0+//;

        return $xlog if $next_xlog_lsn > $lsn + 1;
    }


WAIT:
    return unless $do_wait;
    $do_wait = 0;
    Coro::AnyEvent::sleep .2;
    @xlogs = glob catfile $self->wal_dir, '*.xlog';
    goto CHECK;
}

sub downlink {
    my ($self, $fh) = @_;

    $self->clean_lsn($fh);

    my $salt = '';
    $salt .= chr int rand 256 for 1 .. 32;
    my $salthex = encode_base64($salt, '');

    my $handshake = pack 'a64a64', "Tarantool 1.6~compat\n", "$salthex\n";

    my $wrd = $fh->syswrite($handshake);
    unless ($wrd and $wrd == 128) {
        DEBUGF 'Can not write handshake %s', $!;
        close $fh;
        return;
    }

    my $authen;

    DEBUGF 'Wait requests';
    while (my $request = $self->read_request($fh)) {
        unless ($request) {
            DEBUGF 'Close connection after error';
            last;
        }


        if ($request->{CODE} eq 'PING') {
            DEBUGF 'Client -> pings';
            last unless $self->ping($fh, $request);
            next;
        }

        if ($request->{CODE} eq 'AUTH') {
            DEBUGF 'Client -> auth';
            my $authen_ok = $self->auth($fh, $request, $salt);
            last unless $authen_ok;
            $authen = 1 if $authen_ok and $authen_ok != -1;
            DEBUGF 'Client is %sauthentificated', $authen ? '' : 'not ';
            next;
        }

        if ($request->{CODE} eq 'JOIN') {
            DEBUGF 'Client -> join';
            $self->join_snapshot($fh, $request);
            last;
        }


        if ($request->{CODE} eq 'SUBSCRIBE') {
            DEBUGF 'Client -> subscribe';
            $self->subscribe($fh, $request);
            last;
        }

        DEBUGF 'Unsupported request %s', Dumper $request;
    }

    DEBUGF 'Closing connection';
    close $fh;
}

1;

# bootstrap
__DATA__

