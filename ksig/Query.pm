package ksig::Query; {
	use base qw(Class::Accessor);
	use common::sense;
	use Log::Any qw($log);
	__PACKAGE__->mk_accessors(qw(qid type id from nick when text count desc file_dir uri file_name_ending domain app));

	sub new {
		my $class = shift;
		my %params = @_;
		if($class eq __PACKAGE__) {
			#die Dumper(\%params);
			my $type_class = 'ksig::Query::' . _camelize($params{type});
			if($type_class->can('new')) {
				return $type_class->new(%params);
			}
		}
		my $self = bless \%params, $class;
		if(!$self->when) {
			$self->when(time);
		}
		if(!defined $self->text) {
			$self->text('');
		}
		$self;
	}
	
	sub clone {
		my $self = shift;
		ksig::Query->new(map { $_, $self->{$_} } qw(type id from nick when text count desc file_dir uri file_name_ending domain));
	}

	sub make_child {
		my($self, $new_data) = (shift, {@_});
		my $q = ksig::Query::clone($self);
		for(keys %$new_data) {
			$q->$_($new_data->{$_}); 
		}
		$q;
	}

	sub load {
		my $q = ksig->db->fetch('fetchqueue', ['*'], {qid => shift}, 1);
		return ksig::Query->new(%$q);
	}
	
	sub save {
		my $self = shift;
		my $save = {map { $_, $self->{$_} } grep { $self->{$_} } qw(type id from nick when text count desc file_dir uri file_name_ending domain)};
		if($self->qid) {
			ksig->db->update('fetchqueue', $save, {qid => $self->qid});
		}
		else {
			ksig->db->insert('fetchqueue', $save);
			$self->qid(ksig->db->{dbh}->last_insert_id('', '', 'fetchqueue', 'qid'));
		}
		if($log->is_debug) {
			$log->debug('Saved Query #' . $self->pprint);
		}
		$self;
	}

	sub remove {
		my $self = shift;
		ksig->db->remove('fetchqueue', {qid => $self->qid});
		$self;
	}

	sub execute {
		my $self = shift;
		my $handler = 'ksig::download_' . $self->type;
		return &$handler($self->app, $self);
	}

	sub handle_completion {
		my $self = shift;
		my $handler = 'ksig::handle_' . $self->type . '_completion';
		&$handler($self->app, $self);
		$self;
	}

	sub _camelize {
		$_ = shift;
		lc;
		s/-([a-z])/'::'.uc($1)/ge;
		s/_([a-z])/uc($1)/ge;
		ucfirst;
		
	}

	sub pprint {
		my $self = shift;
		join ':', grep {defined} $self->qid, $self->type, $self->id, $self->uri;
	}
}

1;

__END__
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
