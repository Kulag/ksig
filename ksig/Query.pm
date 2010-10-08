package ksig::Query; {
	use base qw(Class::Accessor);
	use common::sense;
	use Log::Any qw($log);
	__PACKAGE__->mk_accessors(qw(qid type id from nick when text count desc file_dir uri file_name_ending domain));
	
	sub new {
		my $class = shift;
		my $self = bless {@_}, $class;
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
			$log->debug('Saved Query #' . join(':', grep { defined } $self->qid, $self->type, $self->id, $self->uri));
		}
		$self;
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
