#!/usr/bin/env perl
package ksig;
use 5.010;
use base qw(POE::Session::Attribute);
use Carp;
use common::sense;
use Data::Dumper;
use DateTime;
use DBI::SpeedySimple;
use Digest::SHA1 qw(sha1_hex);
use Encode;
use File::BaseDir;
use File::Basename 'dirname';
use File::HomeDir;
use File::Path qw(make_path);
use Getopt::Euclid;
use HTTP::Cookies;
use HTTP::Request;
use HTTP::Request::Common;
use List::Util qw(max min);
use Log::Any qw($log);
use Log::Any::Adapter;
use Log::Any::Adapter::Dispatch;
use Log::Dispatch;
use Perl6::Subs;
use POE qw(Component::Client::HTTP Component::IRC::State Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::Connector Component::IRC::Plugin::NickReclaim);
use POE::Component::IRC::Common qw(:ALL);
use POSIX qw(ceil floor);
use Time::HiRes;
use XML::Simple;

use lib dirname(__FILE__);
use ksig::conf;
use ksig::Log::Dispatch::Terminal;
use ksig::Query;
use ksig::VariableStore;

binmode(STDOUT, ":utf8");
$|++;

my $appdir = File::HomeDir->my_home . '/.ksig';
mkdir $appdir if !-d $appdir;

my $conf = ksig::conf->new({
	cookies_file => File::BaseDir->cache_home('ksig', 'cookies'),
	danbooru_username => undef, # ksig cannot download images from danbooru without this.
	danbooru_password => undef,
	database => 'dbi:SQLite:' . File::BaseDir->data_home('ksig', 'db'),
	file_timestamps_use_mtime => 0,
	http_concurrent_requests => 5,
	pixiv_username => undef, # Without this, ksig can only download basic image links. No manga, R-18 content, or any of the other pages are supported.
	pixiv_password => undef,
	irc_admins => [], # IRC masks of users allowed to send commands to the bot.
	irc_ignore_skipped_urls => 1, # Ignore urls preceded by a !skip on an IRC line. Default: True.
	irc_nick => 'ksig',
	irc_quitmsg => 'ksig is shutting down.',
	irc_channels => {}, # The IRC servers to connect to, along with the channels to join with their keys. Must be of the form {"irc.example.com" => {"#channel[ <key>]"}}.
	log_file => undef,
	output_folder => File::HomeDir->my_home . '/ksig',
	screen_output_level => 'info',
	stats_speed_average_window => 4000,
	stats_update_frequency => 0.1,
	timezone => 'UTC',
	use_windows_compatible_filenames => 0,
});
if(!-d File::BaseDir->cache_home('ksig')) {
	mkdir File::BaseDir->cache_home('ksig')
}
if(!-d File::BaseDir->data_home('ksig')) {
	mkdir File::BaseDir->data_home('ksig')
}
my $db = DBI::SpeedySimple->new($conf->database);
$db->{dbh}->do("CREATE TABLE IF NOT EXISTS fetchqueue (qid integer primary key autoincrement, `type` text, `id` text, `domain` text, `when` int, `count` int, `nick` text, `text` text, `desc` text, `uri` text, `from` text, `file_name_ending` text, `file_dir` text, recurse int);");
my $vs = ksig::VariableStore->new($db);

my $logger;
my %irc_session_ids;

my $http_session_id = $poe_kernel->ID_session_to_id(
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
			file => $conf->cookies_file,
			autosave => 1,
		),
	)
);

sub yield :Object {
	shift;
	$poe_kernel->yield(@_);
}

sub _start :Object {
	my $self = shift;
	
	$poe_kernel->sig(INT => 'shutdown');
	
	$self->{activequeries} = {};
	$self->{downloaderactive} = 0;
	$self->{fetchqueue} = $db->{dbh}->selectcol_arrayref('SELECT qid FROM fetchqueue');
	$self->{last_stats_line_len} = 0;
	$self->{statsactive} = 0;

	# Perl can't find Log::Dispatch::File if we try to use it normally.
	$logger = Log::Dispatch->new(outputs => $conf->log_file ? [['File', min_level => 'debug', filename => $conf->log_file, newline => 1]] : []);
	$logger->add($self->{term_logger} = ksig::Log::Dispatch::Terminal->new(
		name => 'terminal',
		min_level => $conf->screen_output_level,
		statsactive => \$self->{statsactive}
	));
	Log::Any::Adapter->set('Dispatch', dispatcher => $logger);
	
	my %irc_channels = %{$conf->irc_channels};
	for my $url (keys %irc_channels) {
		my $irc = POE::Component::IRC::State->spawn(
			Nick => $conf->irc_nick,
			Server => $url,
		);
		
		my %channels;
		for(ref $irc_channels{$url} eq 'ARRAY' ? @{$irc_channels{$url}} : $irc_channels{$url}) {
			if(/ /) {
				my($a, $b) = split / /, $_;
				$channels{$a} = $b;
			}
			else {
				$channels{$_} = '';
			}
		}
		
		$irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(Channels => \%channels, RejoinOnKick => 1, Retry_when_banned => 1));
		$irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new(servers => \($url)));
		$irc->plugin_add('NickReclaim', POE::Component::IRC::Plugin::NickReclaim->new());
		
		$poe_kernel->post($irc, 'register', qw(public msg join));
		$poe_kernel->post($irc, 'connect', {});
		$irc_session_ids{$irc->session_id} = 1;
	}
	
	if(@{$self->{fetchqueue}}) {
		$self->{downloaderactive} = 1;
		$self->yield("http_process_queue");
	}
	return;
}

sub _stop :Object {
	my $self = shift;
	$self->yield('shutdown');
	return;
}

sub shutdown :Object {
	my $self = shift;
	if(!$self->{_shutdown}) {
		$log->info("ksig is shutting down.");
		$self->{_shutdown} = 1;
		if($http_session_id) {
			$poe_kernel->post($http_session_id, 'shutdown');
			$http_session_id = 0;
		}
		for(keys %irc_session_ids) {
			$poe_kernel->post($_, 'shutdown', $conf->irc_quitmsg);
		}
	}
	return;
}

# IRC events.
sub irc_join :Object {
	my($self, $sender, $nick, $channel) = @_[0, SENDER, ARG0, ARG1];
	my $irc = $sender->get_heap;
	($nick, my $vhost) = split '!', $nick;
	if($nick eq $conf->irc_nick) {
		$log->info("Listening on $channel\@". $irc->server_name);
	}
	return;
}

sub irc_public :Object {
	my($self, $who, $where, $what) = @_[0, ARG0, ARG1, ARG2];
	my $count = 0;
	my $nick = (split /!/, $who)[0];
	$what = decode_utf8($what);
	my $q;
	my $queue = sub {
		if(defined $q->{type}) {
			$self->queue($q);
		}
		$q = ksig::Query->new(count => $count++, from => $where->[0], nick => $nick);
	};
	for(split / /, $what) {
		given($_) {
			when('!skip') {
				return if $conf->irc_ignore_skipped_urls;
			}
			when(m!http://img\d+\.pixiv\.net/img/.*?/(\d+)!) {
				$queue->();
				$q->{type} = 'pixivimage';
				$q->{id} = $1;
			}
			when(m!http://(?:www\.)?pixiv\.net/member_illust\.php\?mode=(?:medium|big)&illust_id=(\d+)!i) {
				$queue->();
				$q->{type} = 'pixivimage';
				$q->{id} = $1;
			}
			when(m!http://(?:www\.)?pixiv\.net/member_illust\.php\?mode=manga&illust_id=(\d+)!i) {
				$queue->();
				$q->{type} = 'pixivmanga';
				$q->{id} = $1;
			}
			when(m!http://(?:www\.)?(danbooru\.donmai\.us|konachan\.(?:com|net)|moe.imouto.org)/post/show/(\d+)!i) {
				$queue->();
				$q->{type} = 'danbooruimage';
				$q->{domain} = $1;
				$q->{id} = $2;
			}
			when(m!^(.*?)(https?://(?:www\.)?.*?\.(?:png|jpe?g|bmp|gif))(.*?)$!i) {
				$queue->();
				$q->{type} = 'file';
				$q->{uri} = $2;
				if($1) {
					$q->{text} .= $1 . " ";
				}
				if($3) {
					$q->{text} .= $3 . " ";
				}
			}
			default {
				$q->{text} .= "$_ ";
			}
		}
	}
	$queue->();
	return;
}

sub irc_msg :Object {
	my($self, $sender, $who, $where, $what) = @_[0, SENDER, ARG0, ARG1, ARG2];
	my $nick = (split /!/, $who)[0];
	$what = decode_utf8($what);
	
	if(!%{matches_mask_array($conf->irc_admins, [$who])}) {
		$poe_kernel->post($sender, 'privmsg', $nick, "I'm sorry Dave, I can't do that.");
		return;
	}
	
	my $command;
	($command, $what) = split(/ /, $what, 2);
	given($command) {
		when('grab') {
			for(split / /, $what) {
				given($_) {
					when(m!http://img\d+\.pixiv\.net/img/.*?/(\d+)!) {
						$self->queue(from => $who, type => 'pixivimage', id => $1);
					}
					when(m!http://(?:www\.)?pixiv\.net/member_illust\.php\?mode=(?:medium|big)&illust_id=(\d+)!i) {
						$self->queue(from => $who, type => 'pixivimage', id => $1);
					}
					when(m!http://(?:www\.)?pixiv\.net/member_illust\.php\?mode=manga&illust_id=(\d+)!i) {
						$self->queue(from => $who, type => 'pixivmanga', id => $1);
					}
					when(m!http://(?:www\.)?(danbooru\.donmai\.us|konachan\.(?:com|net)|moe.imouto.org)/post/show/(\d+)!i) {
						$self->queue(from => $who, type => 'danbooruimage', domain => $1, id => $2);
					}
					when(m!^pixivbni(?:#(\d+))?!i) {
						my $id = (defined $1 ? int($1) : $vs->get('pixiv_bookmark_new_illust_last_id'));
						$self->queue(from => $who, type => 'pixiv_bookmark_new_illust', id => $id);
					}
					when(m!^http://www\.pixiv\.net/member_illust.php\?id=(\d+)!) {
						$self->queue(from => $who, type => 'pixiv_member_illust', id => $1);
					}
					when(m!(.*?)(http://.*)!i) {
						$self->queue(from => $who, type => 'file', uri => $2, text => $1);
					}
					default {
						$poe_kernel->post($sender, 'privmsg', $nick, "Don't know how to grab '$what'.");
					}
				}
			}
		}
		when('cancel') {
			if($db->exists('fetchqueue', {qid => $what})) {
				if(my $q = $self->{activequeries}->{$what}) {
					$self->clear_download($q);
				}
				else {
					$db->remove('fetchqueue', {qid => $q->{qid}});
				}
				$poe_kernel->post($sender => privmsg => $nick => "#$what canceled.");
			}
			else {
				$poe_kernel->post($sender => privmsg => $nick => "Invalid fetchqueue ID: $what");
			}
		}
		when('shutdown') {
			$self->yield('shutdown');
		}
		when('hi') {
			$poe_kernel->post($sender => privmsg => $nick => 'Hi there!');
		}
		default {
			$poe_kernel->post($sender => privmsg => $nick => "Unrecognized command '$command'.");
		}
	}
	return;
}

sub http_process_queue :Object {
	my $self = shift;
	if(!scalar @{$self->{fetchqueue}} || $self->{_shutdown}) {
		$self->{downloaderactive} = 0;
		return;
	}
	
	if(scalar(keys %{$self->{activequeries}}) < $conf->http_concurrent_requests) {
		my $q = ksig::Query::load(shift(@{$self->{fetchqueue}}));
		my $downloader = "download_$q->{type}";
		if($self->$downloader($q)) {
			if($log->is_info) {
				$log->info('Get #' . join(':', grep { defined } $q->qid, $q->type, $q->id, $q->uri));
			}
			
			$q->{starttime} = Time::HiRes::time();
			$q->{completed_length} = 0 if !defined $q->{completed_length};
			$q->{startpos} = $q->{completed_length};
			$self->{activequeries}->{$q->qid} = $q;
		}
		else {
			push @{$self->{fetchqueue}}, $q->qid;
		}
	}
	
	if(scalar(keys %{$self->{activequeries}}) < $conf->http_concurrent_requests) {
		$self->yield('http_process_queue');
	}
	else {
		$poe_kernel->delay('http_process_queue', 0.1);
	}
	return;
}

sub http_stream_q :Object {
	my($self, $req, $qid, $res, $chunk) = ($_[0], @{$_[ARG0]}, @{$_[ARG1]});
	my $q = $self->{activequeries}->{$qid};
	if(!defined $q) {
		$log->info("#$qid no longer active.");
		return;
	}
	if(!$res->is_success) {
		if($res->code == 408) {
			return if $res->content =~ /request canceled/;
			if($res->content =~ /component shut down/) {
				$log->info("Closing #$qid in preparation for component shutdown.");
				close $q->{outfh} if $q->{outfh};
				delete $self->{activequeries}->{$q->{qid}};
				return;
			}
			$self->requeue($q);
		}
		elsif($res->code == 400 || $res->code == 500) {
			$self->requeue($q);
		}
		elsif($res->code == 416 || $res->code == 404) {
			$log->info("#$qid HTTP failure: " . $res->status_line);
		}
		$self->clear_download($q);
		return;
	}
	if(defined $chunk) {
		if(!defined $q->{total_length} && defined $res->header('Content-Length')) {
			$q->{content_length} = $res->header('Content-Length');
			if($res->code == 200) {
				$q->{total_length} = int($res->header('Content-Length'));
				if($q->{completed_length} == $q->{total_length}) {
					$poe_kernel->call('http', 'cancel', $req);
					$log->info("$qid is already done.");
					$self->clear_download($q);
					return;
				}
				if(defined $q->{file_path} && !defined $q->{outfh}) {
					open($q->{outfh}, '>', $q->{file_path}) or croak $!;
				}
			}
			elsif($res->code == 206) {
				$res->header('Content-Range') =~ /bytes (\d+)-(\d+)\/(\d+)/;
				croak('restarted at wrong location: ' . Dumper($res)) if int($1) != $q->{completed_length};
				$q->{total_length} = int($3);
				if(defined $q->{file_path} && !defined $q->{outfh}) {
					open($q->{outfh}, '>>', $q->{file_path}) or croak $!;
				}
			}
		}
		
		if($q->{outfh}) {
			syswrite($q->{outfh}, $chunk) or croak $!;
		}
		else {
			$q->{buf} .= $chunk;
		}
		
		$q->{completed_length} += length($chunk);
		my $now = int(Time::HiRes::time() * 1000);
		$q->{timelens}->{$now} = $q->{completed_length};
		
		for(keys %{$q->{timelens}}) {
			delete $q->{timelens}->{$_} if $now - $conf->stats_speed_average_window > $_;
		}
		
		if(!$self->{statsactive}) {
			$self->{statsactive} = 1;
			$self->yield('stats_update');
		}
	}
	else {
		$self->download_finished($q);
	}
	return;
};

sub stats_update :Object {
	my $self = shift;
	# First blank the last stats line to prevent trailing garbage.
	my $out = "\r" . (' ' x $self->{last_stats_line_len}) . "\r";
	
	# Add any new inform lines since the last update.
	$out .= $self->{term_logger}->buffer_get_clean;
	
	# Stop updating if there's nothing going on.
	if(!scalar(keys %{$self->{activequeries}})) {
		print $out;
		$log->debug('Queue finished.');
		$self->{last_stats_line_len} = 0;
		$self->{statsactive} = 0;
		return;
	}
	
	my %totals = (
		completed_length => 0,
		len => 0,
		speed => 0,
	);
	my $stats_line = '';
	my $now = int(Time::HiRes::time() * 1000);
	
	for(sort(keys %{$self->{activequeries}})) {
		my $q = $self->{activequeries}->{$_};
		
		if(defined $q->{total_length}) {
			my $speed = calc_speed($q);
			my $percent = $q->{completed_length} * 10000 / $q->{total_length};
			
			$totals{completed_length} += $q->{completed_length};
			$totals{len} += $q->{total_length};
			$totals{speed} += $speed;
			
			$stats_line .= sprintf('[%d %s/%s %2d.%02d%%]', $q->{qid}, fmt_size($q->{completed_length}), fmt_size($q->{total_length}), $percent / 100, $percent % 100);
		}
		else {
			$stats_line .= "[$q->{qid} Connecting]";
		}
	}
	
	$stats_line = sprintf("Active: %d/%d %s/s ", scalar(keys %{$self->{activequeries}}), scalar(@{$self->{fetchqueue}}) + scalar(keys %{$self->{activequeries}}), fmt_size($totals{speed})) . $stats_line;
	$self->{last_stats_line_len} = length($stats_line);
	print $out . $stats_line;
	
	$poe_kernel->delay(stats_update => $conf->stats_update_frequency);
};

sub queue {
	my $self = shift;
	my $q = $_[0]->isa('ksig::Query') ? shift : ksig::Query->new(@_);
	my $qid = $q->save->qid;
	push @{$self->{fetchqueue}}, $qid;
	if(!$self->{_shutdown} && !$self->{downloaderactive}) {
		$self->{downloaderactive} = 1;
		$self->yield('http_process_queue');
	}
	$qid;
}

sub requeue {
	my($self, $q, $newq) = (shift, ksig::Query::clone(shift), {@_});
	for(keys %$newq) {
		$q->$_($newq->{$_}); 
	}
	return $self->queue($q);
}

method download_finished($q) {
	my $transfer_timedelta = Time::HiRes::time() - $q->{starttime};
	$log->notice(sprintf("Finished #%d. %s transferred in %s (avg %s/s).",
		$q->{qid},
		fmt_size($q->{completed_length} - $q->{startpos}),
		fmt_timedelta($transfer_timedelta),
		fmt_size($q->{completed_length} / $transfer_timedelta)));
	my $handler = "handle_$q->{type}_completion";
	$self->$handler($q);
	$self->clear_download($q);
	return;
}

method clear_download($q) {
	delete $self->{activequeries}->{$q->{qid}};
	$db->remove('fetchqueue', {qid => $q->{qid}});
	return;
}

# Downloaders and completion handlers.
method download_file($q) {
	my $file_dir = encode_utf8($conf->output_folder . "/$q->{from}" . (defined $q->{file_dir} ? "/$q->{file_dir}" : ""));
	if(!$q->{file_name_ending}) {
		($q->{file_name_ending} = $q->{uri}) =~ s!^https?://(www\.)?!!;
	}
	$q->{file_name} = make_file_name($q, $file_dir) if !defined $q->{file_name};
	make_path($file_dir) if !-d $file_dir;
	$q->{file_path} = "$file_dir/" . encode_utf8($q->{file_name});

	my $r = GET $q->{uri};
	$r->header(Accept_Ranges => 'bytes');
	if(-f $q->{file_path}) {
		$r->header(Range => 'bytes=' . (-s $q->{file_path}) . "-");
		$q->{completed_length} = -s $q->{file_path};
	}
	$r->header(Referer => 'http://pixiv.net') if($q->{uri} =~ m!^http://img\d+\.pixiv\.net!);
	$poe_kernel->post('http', 'request', 'http_stream_q', $r, $q->{qid});
	return 1;
}

method handle_file_completion($q) {
	if($conf->file_timestamps_use_mtime) {
		utime(time(), $q->{when}, $q->{outfh});
	}
	close $q->{outfh};
}

method download_pixivlogin($q) {
	$poe_kernel->post('http', 'request', 'http_stream_q', POST('http://www.pixiv.net/index.php', Content => {mode => 'login', pixiv_id => $conf->pixiv_username, pass => $conf->pixiv_password, skip => 1}), $q->{qid});
	return 1;
}

method handle_pixivlogin_completion($q) {
	my $buf = decode_utf8($q->{buf});
	croak 'Pixiv login failed' if($buf =~ /value="login"/);
	$log->info('Logged in to pixiv.');
	$self->{pixivloggingin} = 0;
}

method download_pixivrelogin($q) {
	$poe_kernel->post('http', 'request', 'http_stream_q', POST('http://www.pixiv.net/logout.php'), $q->{qid});
	return 1;
}

method handle_pixivrelogin_completion($q) {
	$self->queue({type => 'pixivlogin'});
	return;
}


method download_pixivimage($q) {
	return 0 if $self->{pixivloggingin};
	$poe_kernel->post('http', 'request', 'http_stream_q', GET("http://www.pixiv.net/member_illust.php?mode=medium&illust_id=$q->{id}"), $q->{qid});
	return 1;
}

method handle_pixivimage_completion($q) {
	my $buf = decode_utf8($q->{buf});
	return $self->requeue($q) if $buf !~ /<\/html>/;
	
	if($conf->pixiv_username) {
		return if !$self->check_pixiv_login($q, $buf);
		given($buf) {
			when(/あなたが18/) {
				$log->info("Ignoring #$q->{qid}, it's R-18 and the user has disabled R-18.");
				return;
			}
			when(/該当イラストは削除されたか、存在しないイラストIDです。/) { # Either the corresponding illustration has been deleted, or the illustration ID does not exist.
				$log->info("#$q->{qid} was deleted before we got to it.");
				return;
			}
			when(/member_illust.php\?mode=manga&illust_id=$q->{id}/) {
				$self->requeue($q, type => 'pixivmanga', id => $q->{id});
			}
			when(m!<title>(.*?)のイラスト \[pixiv\]</title>.*?http://(img\d+)\.pixiv\.net/img/(.*?)/$q->{id}_m.(\w+)!s) {
				$self->requeue($q, type => 'file', uri => "http://$2.pixiv.net/img/$3/$q->{id}.$4", file_name_ending => "pixiv $q->{id} $1.$4");
			}
			default {
				open F, ">pixivimageregex-failed-$q->{id}";
				print F encode_utf8($buf);
				close F;
				carp "pixivimage regex failed on $q->{id}";
			}
		}
	}
	else {
		if($buf =~ m!<title>(.*?)のイラスト \[pixiv\]</title>.*?http://(img\d+)\.pixiv\.net/img/(.*?)/$q->{id}_s.(\w+)!s) {
			$self->requeue($q, type => 'file', uri => "http:\/\/$2.pixiv.net\/img\/$3\/$q->{id}.$4", file_name_ending => "pixiv $q->{id} $1.$4");
		}
		# Otherwise, it's probably R-18, but pixiv doesn't return anything to tell us that if we aren't logged in.
	}
}

method download_pixivmanga($q) {
	return 0 if $self->{pixivloggingin};
	$poe_kernel->post('http', 'request', 'http_stream_q', GET("http://www.pixiv.net/member_illust.php?mode=manga&illust_id=$q->{id}"), $q->{qid});
	return 1;
}

method handle_pixivmanga_completion($q) {
	my $buf = decode_utf8($q->{buf});
	return if !$self->check_pixiv_login($q, $buf);

	my $title;
	if($buf =~ m!<title>(.*?)の漫画 \[pixiv\]</title>!) {
		$title = $1;
	}
	else {
		open F, ">pixivmangaregex-title-failed-$q->{id}.html";
		print F encode_utf8($buf);
		close F;
		croak "pixivmanga regex title failed on $q->{id}";
	}
	
	my $pagecount;
	if($buf =~ m!1 / (\d+) p!) {
		$pagecount = int($1);
	}
	else {
		open F, ">pixivmangaregex-pagecount-failed-$q->{id}.html";
		print F encode_utf8($buf);
		close F;
		croak "pixivmanga regex pagecount failed on $q->{id}";
	}

	my($imgserver, $username, $file_ext);
	if($buf =~ m!<img src="http://(\w+)\.pixiv\.net/img/(.*?)/$q->{id}_p\d+\.(\w+)">!) {
		($imgserver, $username, $file_ext) = ($1, $2, $3);
	}
	else {
		open my $f, ">pixivmangaregex-imgurl-failed-$q->{id}.html";
		print $f encode_utf8($buf);
		close $f;
		croak "pixivmanga regex imgurl failed on $q->{id}";
	}

	# Assumes that the file extension is the same for all the pages.
	# Might turn out to be a problem, but it's simpler than loading and parsing each page.
	for(0..($pagecount - 1)) {
		$self->requeue($q,
			type => 'file',
			uri => sprintf('http://%s.pixiv.net/img/%s/%d_p%d.%s', $imgserver, $username, $q->{id}, $_, $file_ext),
			file_name_ending => sprintf('pixiv %d %s P%d.%s', $q->{id}, $title, $_, $file_ext),
		);
	}
}

method download_pixiv_bookmark_new_illust($q) {
	return 0 if $self->{pixivloggingin};
	my $r = GET('http://www.pixiv.net/bookmark_new_illust.php?mode=new&p=' . (defined $q->{uri} ? $q->{uri} : 1));
	$r->header(Referer => 'http://www.pixiv.net/mypage.php') if !defined $q->{uri};
	$poe_kernel->post('http', 'request', 'http_stream_q', $r, $q->{qid});
	return 1;
}

method handle_pixiv_bookmark_new_illust_completion($q) {
	my $buf = decode_utf8($q->{buf});
	return if !$self->check_pixiv_login($q, $buf);
	
	while($buf =~ m!src="http://img\d+.pixiv.net/img/.+?/(\d+)_s.\w+" alt=".+?"!g) {
		$self->{pixiv_bni_last_id} = int($1) if !defined $self->{pixiv_bni_last_id} || int($1) > $self->{pixiv_bni_last_id};
		if(int($1) <= $q->{id}) {
			$vs->set('pixiv_bookmark_new_illust_last_id', $self->{pixiv_bni_last_id});
			return;
		}
		$self->requeue($q, type => 'pixivimage', id => $1, file_dir => "pixiv_bookmark_new_illust_from_$q->{id}");
	}
	$self->requeue($q, uri => (defined $q->{uri} ? int($q->{uri}) + 1 : 2));
}

method download_pixiv_member_illust($q) {
	return 0 if $self->{pixivloggingin};
	$poe_kernel->post('http', 'request', 'http_stream_q', GET("http://www.pixiv.net/member_illust.php?id=$q->{id}" . (defined $q->{uri} ? "&p=$q->{uri}" : '')), $q->{qid});
	return 1;
}

method handle_pixiv_member_illust_completion($q) {
	my $buf = decode_utf8($q->{buf});
	return if !$self->check_pixiv_login($q, $buf);
	
	my $page = int($q->{uri} ? $q->{uri} : 1);
	if($page == 1) {
		$buf =~ m!<span> (\d+)件</span>!; # Post count
		my $items = int($1);
		my $pages = ceil($items / 20);
		if($pages > 1) {
			$self->requeue($q, type => 'pixiv_member_illust', id => $q->{id}, uri => $_) for 2..$pages;
		}
	}
	
	while($buf =~ m!member_illust\.php\?mode=medium&illust_id=(\d+)"><img src="http://img\d+.pixiv.net/img/.*?/\d+_s!g) {
		$self->requeue($q, type => 'pixivimage', id => $1, file_dir => "pixiv_member_illust_$q->{id}");
	}
}

method download_danbooruimage($q) {
	$poe_kernel->post('http', 'request', 'http_stream_q', make_danbooru_request($q->{domain}, 'post/index', {tags => "id:$q->{id}"}), $q->{qid});
	return 1;
}

method handle_danbooruimage_completion($q) {
	my $r = (XMLin(decode_utf8($q->{buf})))->{post};
	$r->{file_url} =~ /\.(\w{3,4})$/;
	$self->requeue($q, type => 'file', desc => $r->{tags}, uri => $r->{file_url}, file_name_ending => "$q->{domain} $q->{id}.$1");
}

method check_pixiv_login($q, $buf) {
	given($buf) {
		when(/value="login"/) {
			# We aren't logged in.
			if(!$self->{pixivloggingin}) {
				$self->{pixivloggingin} = 1;
				$self->queue({type => 'pixivlogin'});
			}
			$self->requeue($q);
			return 0;
		}
		when(/プロフィール確認/) { # As far as I know, this string is unique to this page.
			# mypage.php is shown when a session times out. Simply loading it refreshes the session, so all we need to do is reload the desired page.
			$self->requeue($q);
			return 0;
		}
		when(/エラーが発生しました/) { # An error has occured.
			if(!$self->{pixivloggingin}) {
				$self->{pixivloggingin} = 1;
				$self->queue({type => 'pixivrelogin'});
			}
			$self->requeue($q);
			return 0;
		}
	}
	return 1;
}

sub calc_speed {
	my($q) = @_;
	my $speed = 0;
	my @timelens_keys = keys %{$q->{timelens}};
	
	if(scalar(@timelens_keys)) {
		my($min_timelens_key, $max_timelens_key) = (min(@timelens_keys), max(@timelens_keys));
		$speed = ($q->{timelens}->{$max_timelens_key} - $q->{timelens}->{$min_timelens_key}) / ($conf->stats_speed_average_window / 1000);
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
	return;
}

sub fmt_timedelta {
	my $timedelta = shift;
	my $ms = floor($timedelta*1000)+0.5;
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
	if($domain eq 'danbooru.donmai.us' && defined $conf->danbooru_username) {
		$options->{login} = $conf->danbooru_username;
		$options->{password_hash} = sha1_hex('choujin-steiner--' . $conf->danbooru_password . '--');
	}
	return HTTP::Request->new(GET => sprintf("http://%s/%s.xml?%s", $domain, $func, join("&", map { "$_=$options->{$_}" } keys %{$options})));
}

sub make_file_name {
	my($q, $file_dir) = @_;

	my @fn;
	if(defined $q->{when} && !$conf->file_timestamps_use_mtime) {
		push @fn, sprintf("[%s]", get_datetime($q->{when})->strftime("%F %T"));
	}
	push @fn, '<' . $q->nick . '>' if $q->nick;

	my $text = defined $q->{text} ? $q->{text} : '';
	while(length(encode_utf8(join(' ', @fn) . "$file_dir $text >> $q->{file_name_ending}")) >= 255 and $text ne '') {
		$text = substr($text, 0, length($text) - 2);
	}
	push @fn, "$text >>" if $text ne '';

	my $desc = defined $q->{desc} ? $q->{desc} : '';
	while(length(encode_utf8(join(' ', @fn) . "$file_dir $desc $q->{file_name_ending}")) >= 255 and $desc ne '') {
		$desc = substr($desc, 0, length($desc) - 2);
	}
	push @fn, $desc if $desc ne '';

	push @fn, $q->{file_name_ending};
	my $filename = join(' ', @fn);
	if($conf->use_windows_compatible_filenames) {
		$filename =~ tr!\?"/\\<>\|:\*!？”∕＼＜＞｜：＊!;
	}
	else {
		$filename =~ s!/!∕!g;
	}
	return $filename;
}

sub get_datetime {
	my $time = shift;
	my $when = DateTime->from_epoch(epoch => $time);
	$when = $when->set_time_zone($conf->timezone);
	return $when;
}

sub db { $db }

ksig->spawn;
$poe_kernel->run;

__END__
=head1 NAME

ksig.pl - A bot to grab images from IRC

=head1 USAGE

ksig.pl [options]

=head1 OPTIONS

=over

=item --conf[ig[file]] [=] <file>

File to read configuration from. Default: ~/.config/ksig/ksig.cfg

=for Euclid
	file.type: readable

=item --cookies-file [=] <file>

File to store cookies in. Default: ~/.cache/ksig/cookies

=for Euclid
	file.type: writeable

=item --database [=] <str>

DBI connection string. Default: dbi:SQLite:~/.local/share/ksig/db.

=for Euclid
	str.type: str

=item --file-timestamps-[dont-]use-mtime

Enabling this sets the modification time on the file to the time the event that caused it to be downloaded happened instead of putting it in the filename.

=for Euclid
	false: --file-timestamps-dont-use-mtime

=item --http-concurrent-requests [=] <int>

The number of requests the http module may execute concurrently. Default: 5.
Note: This default was chosen not for performance reasons, but simply because that was the number of requests that fit on one line of my terminal. YMMV.

=for Euclid
	int.type: 0+int

=item --irc-nick [=] <str>

The nick to try to use on IRC. Default: ksig.

=for Euclid
	str.type: str

=item --irc-quitmsg [=] <str>

The message to send to the IRC server when quitting.
Default: ksig is shutting down.

=for Euclid
	str.type: str

=item --log-file [=] <str>

Where to log stuff.

=for Euclid
	str.type: str

=item --out[put[-folder]] [=] <filename>

The folder to put downloaded files in. Default: ~/ksig

=for Euclid
	filename.type: writeable

=item --screen-output-level [=] <level>

How detailed information to output to the terminal. Default: info.
Options: debug info notice warning error critical alert emergency.

=for Euclid:
	level.type: /(debug|info|notice|warning|error|critical|alert|emergency)/

=item --stats-speed-average-window [=] <milliseconds>

How large a window (in milliseconds) to use for the current speed calculation.

=for Euclid
	milliseconds.type: 0+i

=item --stats-update-frequency [=] <seconds>

How often (in seconds) to update the stats line at the bottom of the terminal.

=for Euclid
	seconds.type: 0+num

=item --timezone [=] <timezone>

The timezone to use for dates in the downloaded files' filenames.

=for Euclid
	timezone.type: str

=item --[dont-[use-]]windows-compatible-filenames

Default: false. Set to true to make Windows not shit bricks.

=for Euclid
	false: --dont-use-windows-compatible-filenames

=back

=head1 COPYRIGHT

Copyright (c) 2010, Kulag <g.kulag@gmail.com>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
