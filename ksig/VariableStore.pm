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
use v5.10;
use common::sense;
use Moose;
use Perl6::Subs;

has 'db' => (is => 'ro', required => 1);

method BUILD(*@vars) {
	$self->db->{dbh}->do('CREATE TABLE IF NOT EXISTS variable (`key` text, `val` text);');
}

method get(Str $key, Int ?$reset) {
	if(!exists $self->{cache}->{$key} || $reset) {
		$self->{cache}->{$key} = ($self->db->fetch('variable', 'value', {key => $key}, 1))->{val};
	}
	return $self->{cache}->{$key};
}

method set(Str $key, Str $value) {
	$self->{cache}->{$key} = $value;
	$self->db->set('variable', {key => $key, val => $value}, {key => $key});
	return $self;
}

1;