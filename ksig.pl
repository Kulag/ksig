#!/usr/bin/env perl
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

use strict;
use utf8;
use warnings;

use Carp qw(carp croak);
use Config::YAML;
use Data::Dumper;
use DateTime;
use DBI::SpeedySimple;
use Digest::SHA1 qw(sha1_hex);
use Encode;
use File::Path qw(make_path);
use HTTP::Cookies;
use File::HomeDir;
use HTTP::Request;
use HTTP::Request::Common;
use List::Util qw(max min);
use POE qw(Component::Client::HTTP Component::IRC::State Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::Connector Component::IRC::Plugin::NickReclaim);
use POSIX qw(ceil floor);
use Time::HiRes;
use XML::Simple;

use constant CONCURRENT_REQS => 5;
use constant SPEED_AVG_WINDOW => 4000; # milliseconds, integer
use constant STATS_LINE_UPDATE_FREQ => 0.1; # seconds, float

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
	timezone => 'UTC',
	pixiv_bookmark_new_illust_last_id => 0,
);
$conf->read(File::HomeDir->my_home . "/.ksig/config") if -f File::HomeDir->my_home . "/.ksig/config";

my $db = DBI::SpeedySimple->new("dbi:SQLite:" . File::HomeDir->my_home . "/.ksig/db");
$db->{dbh}->do("CREATE TABLE IF NOT EXISTS fetchqueue (qid integer primary key autoincrement, `type` text, `id` text, `domain` text, `when` int, `count`, int, `nick` text, `text` text, `desc` text, `uri` text, `from` text, `file_name_ending` text, `file_dir` text, recurse int);");

POE::Component::Client::HTTP->spawn(
	Alias => 'http',
	Timeout => 45,
	Streaming => 4096,
	FollowRedirects => 2,
	ConnectionManager => POE::Component::Client::Keepalive->new(
		keep_alive    => 30,
		max_open      => 100,
		max_per_host  => 20,
		timeout       => 10,
	),
	CookieJar => HTTP::Cookies->new(
		file => File::HomeDir->my_home . "/.ksig/cookies",
		autosave => 1,
	),
);

POE::Session->create(
	inline_states => {
		_start => sub {
			my($kernel, $heap) = @_[KERNEL, HEAP];
			
			for my $url (keys %{$conf->{irc_servers}}) {
				my $irc = POE::Component::IRC::State->spawn(
					Nick => $conf->{irc_nick},
					Server => $url,
				);
				
				$irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(Channels => $conf->{irc_servers}->{$url}, RejoinOnKick => 1, Retry_when_banned => 1));
				$irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new(servers => \($url)));
				$irc->plugin_add('NickReclaim', POE::Component::IRC::Plugin::NickReclaim->new());
				
				$kernel->post($irc => register => qw(public msg));
				$kernel->post($irc => connect => {});
			}
			
			$heap->{fetchqueue} = [];
			$heap->{informqueue} = [];
			$heap->{downloaderactive} = 0;
			$heap->{statsactive} = 0;
			$heap->{last_stats_line_len} = 0;
		},
		irc_public => sub {
			my($kernel, $who, $where, $what) = @_[KERNEL, ARG0, ARG1, ARG2];
			my $count = 0;
			my $nick = (split /!/, $who)[0];
			my $q = {text => ""};
			$what = decode_utf8($what);
			my $queue = sub {
				if(defined $q->{type}) {
					$q->{from} = $where->[0];
					$q->{when} = time;
					$q->{count} = ($count++);
					$q->{nick} = $nick;
					$kernel->yield(queue => $q);
					$q = {text => ""};
				}
			};
			
			for(split / /, $what) {
				if(/http:\/\/(?:www\.)?pixiv\.net\/member_illust\.php\?mode=(?:medium|big)&illust_id=(\d+)/i) {
					$queue->();
					$q->{type} = "pixivimage";
					$q->{id} = $1;
				} elsif(/http:\/\/(?:www\.)?pixiv\.net\/member_illust\.php\?mode=manga&illust_id=(\d+)/i) {
					$queue->();
					$q->{type} = "pixivmanga";
					$q->{id} = $1;
				} elsif(/http:\/\/(?:www\.)?(danbooru\.donmai\.us|konachan\.(?:com|net)|moe.imouto.org)\/post\/show\/(\d+)/i) {
					$queue->();
					$q->{type} = "danbooruimage";
					$q->{domain} = $1;
					$q->{id} = $2;
				} elsif(/http:\/\/(?:www\.)?.*?(?:png|jpg|jpeg|bmp|gif)$/i) {
					$queue->();
					$q->{type} = "file";
					$q->{uri} = $_;
				} else {
					$q->{text} .= $_ . " ";
				}
			}
			$queue->();
		},
		irc_msg => sub {
			my($kernel, $sender, $who, $where, $what) = @_[KERNEL, SENDER, ARG0, ARG1, ARG2];
			my $allowed = 0;
			for(@{$conf->{admins}}) {
				if($who =~ $_->{regex}) {
					$allowed = $_;
					last;
				}
			}
			return if !$allowed;
			
			my $nick = (split /!/, $who)[0];
			$what = decode_utf8($what);
			
			my $command;
			($command, $what) = split(/ /, $what, 2);
			if($command eq 'grab') {
				for(split / /, $what) {
					if(/http:\/\/(?:www\.)?pixiv\.net\/member_illust\.php\?mode=(?:medium|big)&illust_id=(\d+)/i) {
						$kernel->yield(queue => {from => $who, type => "pixivimage", id => $1});
					} elsif(/http:\/\/(?:www\.)?pixiv\.net\/member_illust\.php\?mode=manga&illust_id=(\d+)/i) {
						$kernel->yield(queue => {from => $who, type => "pixivmanga", id => $1});
					} elsif(/http:\/\/(?:www\.)?(danbooru\.donmai\.us|konachan\.(?:com|net)|moe.imouto.org)\/post\/show\/(\d+)/i) {
						my $domain = $1;
						$kernel->yield(queue => {from => $who, type => "danbooruimage", domain => $domain, id => $2});
					} elsif(/http:\/\//i) {
						$kernel->yield(queue => {from => $who, type => "file", uri => $what});
					} elsif(/^pixivbni(?:#(\d+))?/i) {
						my $id = (defined $1 ? int($1) : $conf->{pixiv_bookmark_new_illust_last_id});
						$kernel->yield(queue => {from => $who, type => "pixiv_bookmark_new_illust", id => $id});
					} elsif(/^http:\/\/www\.pixiv\.net\/member_illust.php\?id=(\d+)/ or $what =~ /pixiv member illust (\d+)/) {
						$kernel->yield(queue => {from => $who, type => "pixiv_member_illust", id => $1});
					} else {
						$kernel->post($sender => privmsg => $nick => "Don't know how to grab '$what'.");
					}
				}
			} elsif($command eq 'hi') {
				$kernel->post($sender => privmsg => $nick => "Hi there!");
			} else {
				$kernel->post($sender => privmsg => $nick => "Unrecognized command '$command'.");
			}
		},
		queue => sub {
			my($kernel, $heap, $q) = @_[KERNEL, HEAP, ARG0];
			
			$db->insert("fetchqueue", $q);
			my $qid = $db->{dbh}->last_insert_id('', '', 'fetchqueue', 'qid');
			push @{$heap->{fetchqueue}}, $qid;
			
			my @infos = ($qid, $q->{type});
			push @infos, $q->{id} if defined $q->{id};
			push @infos, $q->{uri} if defined $q->{uri};
			$kernel->yield(inform => "Queued #" . join(":", @infos));
			
			if(!$heap->{downloaderactive}) {
				$heap->{downloaderactive} = 1;
				$kernel->yield("proc_fetchqueue");
			}
		},
		requeue => sub {
			my($kernel, $heap, $q, $newq) = @_[KERNEL, HEAP, ARG0, ARG1];
			$newq = {} if !defined $newq;
			for(qw(type id from nick when text count desc file_dir uri file_name_ending domain)) {
				$newq->{$_} = $q->{$_} if defined $q->{$_} and !defined $newq->{$_};
			}
			$kernel->yield(queue => $newq);
		},
		proc_fetchqueue => sub {
			my($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
			
			if(!scalar @{$heap->{fetchqueue}}) {
				$heap->{downloaderactive} = 0;
				return;
			}
			
			if(scalar(keys %{$heap->{activequeries}}) < CONCURRENT_REQS) {
				my $qid = shift(@{$heap->{fetchqueue}});
				my $q = $db->fetch("fetchqueue", ["*"], {qid => $qid}, 1);
				
				if($kernel->call($session => "download_$q->{type}" => $q)) {
					my @infos = ($qid, $q->{type});
					push @infos, $q->{id} if defined $q->{id};
					push @infos, $q->{uri} if defined $q->{uri};
					$kernel->yield(inform => "Get #" . join(":", @infos));
					
					$q->{starttime} = Time::HiRes::time();
					$q->{completed_length} = 0 if !defined $q->{completed_length};
					$q->{startpos} = $q->{completed_length};
					$heap->{activequeries}->{$qid} = $q;
				} else {
					push @{$heap->{fetchqueue}}, $qid;
					$heap->{downloaderactive} = 1;
				}
			}
		
			$kernel->delay(proc_fetchqueue => 0.5);
		},
		download_file => sub {
			my($kernel, $q) = @_[KERNEL, ARG0];
			
			my $file_dir = encode_utf8("$conf->{output_folder}/$q->{from}" . (defined $q->{file_dir} ? "/$q->{file_dir}" : ""));
			$q->{file_name} = make_file_name($q, $file_dir) if !defined $q->{file_name};
			make_path($file_dir) if !-d $file_dir;
			$q->{file_path} = "$file_dir/" . encode_utf8($q->{file_name});
			
			
			my $r = GET $q->{uri};
			$r->header(Accept_Ranges => "bytes");
			if(-f $q->{file_path}) {
				$r->header(Range => "bytes=" . (-s $q->{file_path}) . "-");
				$q->{completed_length} = -s $q->{file_path};
			}
			$r->header(Referer => 'http://pixiv.net') if($q->{uri} =~ /^http:\/\/img\d+\.pixiv.net/);
			$kernel->post("http", "request", "stream_file", $r, $q->{qid});
			return 1;
		},
		download_pixivlogin => sub {
			my($kernel, $q) = @_[KERNEL, ARG0];
			$kernel->post(http => request => "stream_file", POST('http://www.pixiv.net/index.php', Content => {mode => 'login', pixiv_id => $conf->{pixiv_username}, pass => $conf->{pixiv_password}, skip => 1}), $q->{qid});
			return 1;
		},
		handle_pixivlogin_completion => sub {
			my($kernel, $heap, $q) = @_[KERNEL, HEAP, ARG0];
			my $buf = decode_utf8($q->{buf});
			croak "Pixiv login failed" if($buf =~ /value="login"/);
			$kernel->yield(inform => "Logged in to pixiv.");
			$heap->{pixivloggingin} = 0;
		},
		download_pixivrelogin => sub {
			my($kernel, $q) = @_[KERNEL, ARG0];
			$kernel->post(http => request => "stream_file", POST('http://www.pixiv.net/logout.php'), $q->{qid});
			return 1;
		},
		handle_pixivrelogin_completion => sub {
			my($kernel, $heap, $q) = @_[KERNEL, HEAP, ARG0];
			$kernel->yield(queue => {type => "pixivlogin"});
		},
		check_pixiv_login => sub {
			my($kernel, $heap, $q, $buf) = @_[KERNEL, HEAP, ARG0, ARG1];
			
			# Ensure we're logged in.
			if($buf =~ /value="login"/) {
				if(!$heap->{pixivloggingin}) {
					$heap->{pixivloggingin} = 1;
					$kernel->yield(queue => {type => "pixivlogin"});
				}
				$kernel->yield(requeue => $q);
				return 0;
			}
			
			# mypage.php is shown when a session times out. Simply loading it refreshes the session, so all we need to do is reload the desired page.
			if($buf =~ /プロフィール確認/) { # As far as I know, this string is unique to this page.
				$kernel->yield(requeue => $q);
				return 0;
			}
			
			if($buf =~ /エラーが発生しました/) { # An error has occured.
				if(!$heap->{pixivloggingin}) {
					$heap->{pixivloggingin} = 1;
					$kernel->yield(queue => {type => "pixivrelogin"});
				}
				$kernel->yield(requeue => $q);
				return 0;
			}
			return 1;
		},
		download_pixivimage => sub {
			my($kernel, $heap, $q) = @_[KERNEL, HEAP, ARG0];
			return 0 if $heap->{pixivloggingin};
			$kernel->post("http", "request", "stream_file", GET("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=$q->{id}"), $q->{qid});
			return 1;
		},
		handle_pixivimage_completion => sub {
			my($kernel, $heap, $session, $q) = @_[KERNEL, HEAP, SESSION, ARG0];
			if(!defined $q->{buf}) {
				$kernel->yield(inform => "$q->{qid}'s buff was undef.");
				$kernel->yield(requeue => $q);
				return;
			}
			my $buf = decode_utf8($q->{buf});
			return if !$kernel->call($session => check_pixiv_login => $q, $buf);
			return $kernel->yield(requeue => $q) if $buf !~ /<\/html>/;
			
			if($conf->{pixiv_username}) {
				if($buf =~ /あなたが18/) {
					$kernel->yield(inform => "Ignoring #$q->{qid}, it's R-18 and the user has disabled R-18.");
					return;
				}
				if($buf =~ /エラーが発生しました/) { # An error has occured.
					if(!$heap->{pixivloggingin}) {
						$heap->{pixivloggingin} = 1;
						$kernel->yield(queue => {type => "pixivrelogin"});
					}
					$kernel->yield(requeue => $q);
					return;
				}
				if($buf =~ /該当イラストは削除されたか、存在しないイラストIDです。/) { # Either the corresponding illustration has been deleted, or the illustration ID does not exist.
					$kernel->yield(inform => "#$q->{qid} was deleted before we got to it.");
					return;
				}
				if($buf =~ /member_illust.php\?mode=manga&illust_id=$q->{id}/) {
					$kernel->yield(requeue => $q, {type => "pixivmanga", id => $q->{id}});
				} elsif($buf =~ /<title>(.*?)のイラスト \[pixiv\]<\/title>.*?http:\/\/(img\d+)\.pixiv\.net\/img\/(.*?)\/$q->{id}_m.(\w+)/s) {
					$kernel->yield(requeue => $q, {type => "file", uri => "http:\/\/$2.pixiv.net\/img\/$3\/$q->{id}.$4", file_name_ending => "pixiv:$q->{id} $1.$4"});
				} else {
					open F, ">pixivimageregex-failed-$q->{id}";
					F->printflush(encode_utf8($buf));
					close F;
					croak "pixivimage regex failed on $q->{id}";
				}
			} else {
				if($buf =~ /<title>(.*?) \[pixiv\]<\/title>.*?http:\/\/(img\d+)\.pixiv\.net\/img\/(.*?)\/$q->{id}_s.(\w+)/s) {
					$kernel->yield(requeue => $q, {type => "file", uri => "http:\/\/$2.pixiv.net\/img\/$3\/$q->{id}.$4", file_name_ending => "pixiv:$q->{id} $1.$4"});
				}
				# Otherwise, it's probably R-18, but pixiv doesn't return anything to tell us that if we aren't logged in.
			}
		},
		download_pixivmanga => sub {
			my($kernel, $heap, $q) = @_[KERNEL, HEAP, ARG0];
			return 0 if $heap->{pixivloggingin};
			$kernel->post("http", "request", "stream_file", GET("http://www.pixiv.net/member_illust.php?mode=manga&illust_id=$q->{id}" . (defined $q->{uri} ? "&p=$q->{uri}" : "")), $q->{qid});
			return 1;
		},
		handle_pixivmanga_completion => sub {
			my($kernel, $heap, $session, $q) = @_[KERNEL, HEAP, SESSION, ARG0];
			my $buf = decode_utf8($q->{buf});
			return if !$kernel->call($session => check_pixiv_login => $q, $buf);
			
			my $title;
			if($buf =~ /<title>(.*?)の漫画 \[pixiv\]<\/title>/) {
				$title = $1;
			} else {
				open F, ">pixivmangaregex-title-failed-$q->{id}.html";
				F->printflush(encode_utf8($buf));
				close F;
				carp "pixivmanga regex title failed on $q->{id}";
			}
			
			my $pagecount;
			if($buf =~ /1 \/ (\d+) p/) {
				$pagecount = int($1);
			} else {
				open F, ">pixivmangaregex-pagecount-failed-$q->{id}.html";
				F->printflush(encode_utf8($buf));
				close F;
				carp "pixivmanga regex pagecount failed on $q->{id}";
			}
			
			my @imageurls;
			while($buf =~ /<img src="http:\/\/(img\d+)\.pixiv\.net\/img\/(.*?)\/$q->{id}_p(\d+)\.(\w+)">/g) {
				push @imageurls, [$1, $2, $3, $4];
			}
			if(scalar(@imageurls) != $pagecount) {
				open F, ">pixivmangaregex-imageurls-failed-$q->{id}.html";
				F->printflush(encode_utf8($buf));
				close F;
				carp "pixivmanga regex imageurls failed on $q->{id}";
			}
			
			for my $imageurl (@imageurls) {
				$kernel->yield(requeue => $q, {type => "file", uri => "http:\/\/$imageurl->[0].pixiv.net\/img\/$imageurl->[1]\/$q->{id}_p$imageurl->[2].$imageurl->[3]", file_name_ending => "pixiv:$q->{id} $title P$imageurl->[2].$imageurl->[3]"});
			}
		},
		download_pixiv_bookmark_new_illust => sub {
			my($kernel, $heap, $q) = @_[KERNEL, HEAP, ARG0];
			return 0 if $heap->{pixivloggingin};
			my $r = GET("http://www.pixiv.net/bookmark_new_illust.php?mode=new&p=" . (defined $q->{uri} ? $q->{uri} : 1));
			$r->header(Referer => "http://www.pixiv.net/mypage.php") if !defined $q->{uri};
			$kernel->post("http", "request", "stream_file", $r, $q->{qid});
			return 1;
		},
		handle_pixiv_bookmark_new_illust_completion => sub {
			my($kernel, $heap, $session, $q) = @_[KERNEL, HEAP, SESSION, ARG0];
			my $buf = decode_utf8($q->{buf});
			return if !$kernel->call($session => check_pixiv_login => $q, $buf);
			
			while($buf =~ /src="http:\/\/img\d+.pixiv.net\/img\/.+?\/(\d+)_s.\w+" alt=".+?"/g) {
				$heap->{pixiv_bni_last_id} = int($1) if !defined $heap->{pixiv_bni_last_id} or int($1) > $heap->{pixiv_bni_last_id};
				if(int($1) <= $q->{id}) {
					$conf->{pixiv_bookmark_new_illust_last_id} = $heap->{pixiv_bni_last_id};
					return;
				}
				#$kernel->yield(requeue => $q, {type => "file", uri => "http:\/\/$1.pixiv.net\/img\/$2\/$3.$4", file_name_ending => "$3 $5.$4", file_dir => "pixiv_bookmark_new_illust_from_$q->{id}"});
				$kernel->yield(requeue => $q, {type => "pixivimage", id => $1, file_dir => "pixiv_bookmark_new_illust_from_$q->{id}"});
			}
			$kernel->yield(requeue => $q, {uri => (defined $q->{uri} ? int($q->{uri}) + 1 : 2)});
		},
		download_pixiv_member_illust => sub {
			my($kernel, $heap, $q) = @_[KERNEL, HEAP, ARG0];
			return 0 if $heap->{pixivloggingin};
			$kernel->post("http", "request", "stream_file", GET("http://www.pixiv.net/member_illust.php?id=$q->{id}" . (defined $q->{uri} ? "&p=$q->{uri}" : "")), $q->{qid});
			return 1;
		},
		handle_pixiv_member_illust_completion => sub {
			my($kernel, $heap, $session, $q) = @_[KERNEL, HEAP, SESSION, ARG0];
			my $buf = decode_utf8($q->{buf});
			return if !$kernel->call($session => check_pixiv_login => $q, $buf);
			
			my $page = int($q->{uri} ? $q->{uri} : 1);
			
			if($page == 1) {
				$buf =~ /投稿数：(\d+)件/; #Post count: \d+ items
				my $items = int($1);
				my $pages = ceil($items / 20);
				if($pages > 1) {
					$kernel->yield(requeue => $q, {type => "pixiv_member_illust", id => $q->{id}, uri => $_}) for 2..$pages;
				}
			}
			
			while($buf =~ /member_illust\.php\?mode=medium&illust_id=(\d+)"><img src="http:\/\/img\d+.pixiv.net\/img\/.*?\/\d+_s/g) {
				$kernel->yield(requeue => $q, {type => "pixivimage", id => $1, file_dir => "pixiv_member_illust_$q->{id}"});
			}
		},
		download_danbooruimage => sub {
			my($kernel, $session, $q) = @_[KERNEL, SESSION, ARG0];
			$kernel->post("http", "request", "stream_file", make_danbooru_request($q->{domain}, "post/index", {tags => "id:$q->{id}"}), $q->{qid});
			return 1;
		},
		handle_danbooruimage_completion => sub {
			my($kernel, $q) = @_[KERNEL, ARG0];
			my $r = (XMLin(decode_utf8($q->{buf})))->{post};
			
			$r->{file_url} =~ /\/([^\/]+)$/;
			my $fne = $1;
			$fne =~ s/%20(\d+).*?\.(\w+)$/moe #$1.$2/ if $q->{domain} eq 'moe.imouto.org';
			
			$kernel->yield(requeue => $q, {type => "file", desc => $r->{tags}, uri => $r->{file_url}, file_name_ending => $fne});
		},
		stream_file => sub {
			my($kernel, $session, $heap, $req, $qid, $res, $chunk) = (@_[KERNEL, SESSION, HEAP], @{$_[ARG0]}, @{$_[ARG1]});
			
			if(!defined $heap->{activequeries}->{$qid}) {
				$kernel->yield(inform => "#$qid no longer active.");
				return;
			}
			
			my $q = $heap->{activequeries}->{$qid};
			
			if(!$res->is_success) {
				if($res->code == 400 or $res->code == 408 or $res->code == 500) {
					return if $res->content =~ /request canceled/;
					$kernel->yield(requeue => $q);
				} else {
					$kernel->yield(inform => "#$qid HTTP failure: " . $res->status_line);
				}
				delete $heap->{activequeries}->{$qid};
				return;
			}
			
			if(defined $chunk) {
				if(!defined $q->{total_length} and defined $res->header('Content-Length')) {
					$q->{content_length} = $res->header('Content-Length');
					if($res->code == 200) {
						$q->{total_length} = int($res->header('Content-Length'));
						if($q->{completed_length} == $q->{total_length}) {
							$kernel->call(http => cancel => $req);
							$kernel->yield(inform => "$qid is already done.");
							$kernel->yield(download_finished => $q, 1);
							return;
						}
						if(defined $q->{file_path} and !defined $q->{outfh}) {
							open($q->{outfh}, '>', $q->{file_path}) or croak $!;
						}
					} elsif($res->code == 206) {
						$res->header("Content-Range") =~ /bytes (\d+)-(\d+)\/(\d+)/;
						croak("restarted at wrong location: " . Dumper($res)) if int($1) != $q->{completed_length};
						$q->{total_length} = int($3);
						if(defined $q->{file_path} and !defined $q->{outfh}) {
							open($q->{outfh}, '>>', $q->{file_path}) or croak $!;
						}
					}
				}
				
				if($q->{outfh}) {
					syswrite($q->{outfh}, $chunk) or croak $!;
				} else {
					$q->{buf} .= $chunk;
				}
				
				$q->{completed_length} += length($chunk);
				my $now = int(Time::HiRes::time() * 1000);
				$q->{timelens}->{$now} = $q->{completed_length};
				
				for(keys %{$q->{timelens}}) {
					delete $q->{timelens}->{$_} if $now - SPEED_AVG_WINDOW > $_;
				}
				
				if(!$heap->{statsactive}) {
					$heap->{statsactive} = 1;
					$kernel->yield("update_stats");
				}
			} else {
				$kernel->yield(download_finished => $q, 1);
			}
		},
		download_finished => sub {
			my($kernel, $heap, $q, $success) = @_[KERNEL, HEAP, ARG0, ARG1];
			
			close $q->{outfh} if $q->{outfh};
			delete $heap->{activequeries}->{$q->{qid}};
			$db->remove("fetchqueue", {qid => $q->{qid}});
			
			if($success) {
				my $transfer_timedelta = Time::HiRes::time() - $q->{starttime};
				$kernel->yield(inform => sprintf("Finished #%d. %s transferred in %s (avg %s/s).", $q->{qid}, fmt_size($q->{completed_length} - $q->{startpos}), fmt_timedelta($transfer_timedelta), fmt_size($q->{completed_length} / $transfer_timedelta)));
				$kernel->yield("handle_$q->{type}_completion" => $q);
			}
		},
		inform => sub {
			my($heap, $message) = @_[HEAP, ARG0];
			
			if($heap->{statsactive}) {
				push @{$heap->{informqueue}}, $message;
			} else {
				print $message . "\n";
			}
		},
		update_stats => sub {
			my($kernel, $heap) = @_[KERNEL, HEAP];
			
			# First blank the last stats line to prevent trailing garbage.
			STDOUT->printflush("\r" . (" " x $heap->{last_stats_line_len}) . "\r");
			
			# Print out any new lines since the last update.
			while($_ = shift(@{$heap->{informqueue}})) {
				STDOUT->printflush($_ . "\n");
			}
			
			# Stop updating if there's nothing going on.
			if(!scalar(keys %{$heap->{activequeries}})) {
				STDOUT->printflush("Queue finished.\n");
				$heap->{last_stats_line_len} = 0;
				$heap->{statsactive} = 0;
				return;
			}
			
			my %totals = (
				completed_length => 0,
				len => 0,
				speed => 0,
			);
			my $stats_line = "";
			my $now = int(Time::HiRes::time() * 1000);
			
			for(sort(keys %{$heap->{activequeries}})) {
				my $q = $heap->{activequeries}->{$_};
				
				if(defined $q->{total_length}) {
					my $speed = calc_speed($q);
					my $percent = $q->{completed_length} * 10000 / $q->{total_length};
					
					$totals{completed_length} += $q->{completed_length};
					$totals{len} += $q->{total_length};
					$totals{speed} += $speed;
					
					$stats_line .= sprintf("[%d %s/%s %2d.%02d%%]", $q->{qid}, fmt_size($q->{completed_length}), fmt_size($q->{total_length}), $percent / 100, $percent % 100);
				} else {
					$stats_line .= "[$q->{qid} Connecting]";
				}
			}
			
			$stats_line = sprintf("Active: %d/%d %s/s ", scalar(keys %{$heap->{activequeries}}), scalar(@{$heap->{fetchqueue}}) + scalar(keys %{$heap->{activequeries}}), fmt_size($totals{speed})) . $stats_line;
			$heap->{last_stats_line_len} = length($stats_line);
			STDOUT->printflush($stats_line);
			
			$kernel->delay(update_stats => STATS_LINE_UPDATE_FREQ);
		},
	}
);

$conf->write;

sub calc_speed {
	my($q) = @_;
	my $speed = 0;
	my @timelens_keys = keys %{$q->{timelens}};
	
	if(scalar(@timelens_keys)) {
		my($min_timelens_key, $max_timelens_key) = (min(@timelens_keys), max(@timelens_keys));
		$speed = ($q->{timelens}->{$max_timelens_key} - $q->{timelens}->{$min_timelens_key}) / (SPEED_AVG_WINDOW / 1000);
	}
	return $speed;
}

my @fmt_sizes = ('', 'K', 'M', 'G', 'T', 'P', 'E', 'Z', 'Y');
sub fmt_size {
	my $bytes = shift;
	return "$bytes B" if $bytes < 1024;
	for($_ = $#fmt_sizes; $_ >= 0; $_--) {
		return sprintf("%.2f %sB", ($bytes / 1024**$_), $fmt_sizes[$_]) if $bytes >= 1024**$_;
	}
}

sub fmt_timedelta {
	my $ms = floor((shift(@_)*1000)+0.5);
	my $h = int($ms / 3_600_000);
	$ms = $ms % 3_600_000;
	my $m = int($ms / 60_000);
	$ms = $ms % 60_000;
	my $s = int($ms / 1_000);
	$ms = $ms % 1_000;
	return sprintf("%02d:%02d:%02d.%03d", $h, $m, $s, $ms);
}

sub make_danbooru_request {
	my($domain, $func, $options) = @_;
	if($domain eq 'danbooru.donmai.us' and defined $conf->{danbooru_username}) {
		$options->{login} = $conf->{danbooru_username};
		$options->{password_hash} = sha1_hex("choujin-steiner--$conf->{danbooru_password}--");
	}
	return HTTP::Request->new(GET => sprintf("http://%s/%s.xml?%s", $domain, $func, join("&", map { "$_=$options->{$_}" } keys %{$options})));
}

sub make_file_name {
	my($q, $file_dir) = @_;
	my @fn;
	my $fne = (defined $q->{file_name_ending} ? $q->{file_name_ending} : $q->{uri});
	if(defined $q->{when}) {
		my $when = DateTime->from_epoch(epoch => $q->{when});
		$when = $when->set_time_zone($conf->{timezone});
		push @fn, sprintf("[%s]", $when->strftime("%F %T"));
	}
	push @fn, "<$q->{nick}>" if defined $q->{nick};
	
	my $text = defined $q->{text} ? $q->{text} : '';
	while(length(join(' ', @fn) . "$file_dir $text >> $fne") > 255 and $text ne '') {
		$text = cutwords($text);
	}
	push @fn, "$text >>" if $text ne '';	
	
	my $desc = defined $q->{desc} ? $q->{desc} : '';
	while(length(join(' ', @fn) . "$file_dir $desc $fne") > 255 and $desc ne '') {
		$desc = cutwords($desc);
	}
	push @fn, $desc if $desc ne '';
	
	push @fn, $fne;
	my $filename = join(' ', @fn);
	$filename =~ s/\//∕/g;
	return $filename;
}

sub cutwords {
	my($phrase, $num) = @_;
	$num = 1 if !defined $num;
	for(1..$num) {
		return '' if index($phrase, ' ') == -1;
		substr($phrase, rindex($phrase, ' ')) = "-";
	}
	return $phrase;
}

$poe_kernel->run();