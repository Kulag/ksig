# Copyright (c) 2010, Kulag <g.kulag@gmail.com>
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
package ksig::conf;
use common::sense;
use Moose;
use Moose::Util::TypeConstraints;
use Readonly;
with qw(MooseX::Getopt MooseX::SimpleConfig);

Readonly my $appdir => File::HomeDir->my_home . '/.ksig';
mkdir $appdir if !-d $appdir;

has '+configfile' => (default => "$appdir/config.yml", documentation => 'Default: ~/.ksig/config.yml');

has 'cookies_file' => (is => 'rw', isa => 'Str', required => 1, default => "$appdir/cookies", documentation => 'Path to the cookies file. Default: ~/cookies.');
has 'database' => (is => 'rw', isa => 'Str', required => 1, default => "dbi:SQLite:$appdir/db", documentation => 'DBI path. Default: dbi:SQLite:~/.ksig/db.');
has [qw(danbooru_password danbooru_username)] => (is => 'rw', isa => 'Str', lazy_build => 1, documentation => 'Username and password for Danbooru. ksig cannot download images from danbooru without this.');
has 'file_timestamps_use_mtime' => (is => 'rw', isa => 'Bool', required => 1, default => 0, documentation => 'Enabling this sets the modification time on the file to the time the event that caused it to be downloaded happened instead of putting it in the filename.');
has [qw(pixiv_password pixiv_username)] => (is => 'rw', isa => 'Str', lazy_build => 1, documentation => 'Username and password for pixiv. Without this, ksig can only download basic image links, no manga, R-18 content, or any of the other pages are supported.');
has 'http_concurrent_requests' => (is => 'rw', isa => 'Int', required => 1, default => 5, documentation => 'The number of requests the http module may execute concurrently. Default: 5. Note: This default was chosen not for performance reasons, but simply because that was the number of requests that fit on one line of my terminal in the status line. YMMV.');
has 'irc_admins' => (is => 'rw', isa => 'ArrayRef', required => 1, default => sub { [] }, documentation => 'IRC masks of users allowed to send commands to the bot.');
has 'irc_ignore_skipped_urls' => (is => 'rw', isa => 'Bool', required => 1, default => 1, documentation => 'Ignore urls preceded by a !skip on an IRC line. Default: True.');
has 'irc_nick' => (is => 'rw', isa => 'Str', required => 1, default => 'ksig', documentation => 'The nick to try to use on IRC. Default: ksig.');
has 'irc_quitmsg' => (is => 'rw', isa => 'Str', required => 1, default => 'ksig is shutting down.', documentation => 'The message to send to the IRC server when quitting. Default: ksig is shutting down.');
has 'irc_servers' => (is => 'rw', isa => 'HashRef[HashRef]', required => 1, default => sub { {} }, documentation => 'The IRC servers to connect to, along with the channels to join with their keys. Must be of the form {"irc.example.com" => {"#channel" => "key"}}. Key must be "" if there is no key.');
has 'log_file' => (is => 'rw', isa => 'Str', predicate => 'has_log_file', documentation => 'Where to log stuff.');
has 'output_folder' => (is => 'rw', isa => 'Str', required => 1, default => File::HomeDir->my_home . '/ksig', documentation => 'The folder to put downloaded files in. Default: ~/ksig');
has 'screen_output_level' => (is => 'rw', isa => 'Str', required => 1, default => 'info', documentation => 'How detailed information to output to the terminal. Default: info. Options: debug info notice warning error critical alert emergency.');
has 'stats_speed_average_window' => (is => 'rw', isa => 'Int', required => 1, default => 4000, documentation => 'How large a window (in milliseconds) to use for the current speed calculation.');
has 'stats_update_frequency' => (is => 'rw', isa => 'Num', required => 1, default => 0.1, documentation => 'How often (in seconds) to update the stats line at the bottom of the terminal.');
has 'timezone' => (is => 'rw', isa => 'Str', required => 1, default => 'UTC', documentation => "The timezone to use for dates in the downloaded files' filenames.");

1;