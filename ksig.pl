#!/usr/bin/perl
# Copyright (c) 2009, Kulag <g.kulag@gmail.com>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use utf8;
use warnings;

use Carp qw(carp croak);
use Config::YAML;
use File::HomeDir;

mkdir File::HomeDir->my_home . "/.ksig" if !-d File::HomeDir->my_home . "/.ksig";

my $conf = Config::YAML->new(
	config => "/usr/share/ksig/config",
	output => File::HomeDir->my_home . "/.ksig/config",
	pixiv_username => undef,
	pixiv_password => undef,
	danbooru_username => undef,
	danbooru_password => undef,
	irc_nick => "ksig",
	irc_servers => {
		"irc.exampleserver.net" => { "#channel" => "key" },
	},
	output_folder => File::HomeDir->my_home . "/ksig",
	admins => [],
);
$conf->read(File::HomeDir->my_home . "/.ksig/config") if -f File::HomeDir->my_home . "/.ksig/config";

$conf->write;