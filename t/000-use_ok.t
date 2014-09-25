#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 2;
use Encode qw(decode encode);


require_ok 'Filesys::Notify::Simple';
require_ok 'List::MoreUtils';

