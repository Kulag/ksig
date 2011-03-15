package ksig::VariableStore;
require Carp;
use common::sense;

sub new {
	my $self = bless {}, shift;
	$self->{db} = shift || Carp::croak('db is required');
	$self;
}

sub get {
	my($self, $key, $default, $reset) = @_;
	if(!exists $self->{cache}->{$key} || $reset) {
		if(my $r = $self->{db}->fetch('variable', ['val'], {key => $key}, 1)) {
			$self->{cache}->{$key} = $r->{val};
		}
		else {
			return $default;
		}
	}
	return $self->{cache}->{$key};
}

sub set {
	my($self, $key, $value) = @_;
	$self->{cache}->{$key} = $value;
	$self->{db}->set('variable', {key => $key, val => $value}, {key => $key});
	$self;
}

1;

