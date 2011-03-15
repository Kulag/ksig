package ksig::Query::Danbooruimage;
use base qw(ksig::Query);
use common::sense;
use Digest::SHA1 qw(sha1_hex);
use Encode;
use HTTP::Request::Common;
use POE;
use XML::Simple;

my $conf = $ksig::conf;

sub execute {
	my $self = shift;
	$poe_kernel->post('http', 'request', 'http_stream_q', _make_request($self->{domain}, 'post/index', {tags => "id:$self->{id}"}), $self->qid);
	return 1;
}

sub handle_completion {
	my $self = shift;
	my $r = (XMLin(decode_utf8($self->{buf})))->{post};
	$r->{file_url} =~ /\.(\w{3,4})$/;
	$self->app->requeue($self, type => 'file', desc => $r->{tags}, uri => $r->{file_url}, file_name_ending => "$self->{domain} $self->{id}.$1");
	$self;
}

sub _make_request {
	my($domain, $func, $options) = @_;
	if($domain eq 'danbooru.donmai.us' && defined $ksig::conf->danbooru_username) {
		$options->{login} = $ksig::conf->danbooru_username;
		$options->{password_hash} = sha1_hex('choujin-steiner--' . $ksig::conf->danbooru_password . '--');
	}
	return GET(sprintf("http://%s/%s.xml?%s", $domain, $func, join("&", map { "$_=$options->{$_}" } keys %{$options})));
}

1;
