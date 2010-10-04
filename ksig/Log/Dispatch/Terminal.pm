package ksig::Log::Dispatch::Terminal; {
	use v5.10;
	use base qw(Log::Dispatch::Output);
	use common::sense;

	sub new {
		my($class, %p) = @_;
		my $self = bless {}, $class;
		$self->_basic_init(%p);
		$self->{buffer} = '';
		$self->{statusline_active} = $p{statsactive};
		$self;
	}

	sub log_message {
		my($self, %p) = @_;
		if(${$self->{statusline_active}}) {
			$self->{buffer} .= $p{message} . "buffer\n";
		}
		else {
			say $p{message};
		}
	}

	sub buffer_get_clean {
		my $self = shift;
		if(@{$self->{buffer}}) {
			my $r = $self->{buffer};
			$self->{buffer} = '';
			return $r;
		}
		return '';
	}
}
1;