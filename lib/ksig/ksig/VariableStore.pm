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

