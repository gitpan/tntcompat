#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 15;
use Encode qw(decode encode);


require_ok 'List::MoreUtils';
require_ok 'AnyEvent::Socket';
require_ok 'Carp';
require_ok 'Coro';
require_ok 'Coro::AnyEvent';
require_ok 'Coro::Handle';
require_ok 'Data::Dumper';
require_ok 'Digest::SHA';
require_ok 'Encode';
require_ok 'Errno';
require_ok 'JSON::XS';
require_ok 'MIME::Base64';
require_ok 'Scalar::Util';
require_ok 'Time::HiRes';
require_ok 'UUID';
