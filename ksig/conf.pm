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
use Config::Std;
use File::BaseDir;
use List::MoreUtils qw(zip);

sub new {
	my($class, $conf, %opts) = @_;
	my $package = caller;
	my $self = bless $conf, $class;

	my $configfile = delete $self->{configfile};

	# When the configfile key is set, magically load configuration from that filename.
	tie $self->{configfile}, __PACKAGE__, sub {
		if(@_ && ($configfile = shift) && -f $configfile) {
			read_config $configfile => my $file_conf;
			my $globals = delete $file_conf->{''};
			my $chain_configfile = delete $globals->{configfile};
			my @keys = keys %$globals;
			my @vals = map { /^\d+$/ ? int($_) : ($_ eq 'undef' ? undef : $_) } values %$globals;
			my %new = zip(@keys, @vals);
			for(@keys) {
				$self->{$_} = $new{$_};
			}
			for my $section (keys %$file_conf) {
				my @keys = keys %{$file_conf->{$section}};
				my @vals = map { /^\d+$/ ? int($_) : ($_ eq 'undef' ? undef : $_) } values %{$file_conf->{$section}};
				if(defined $opts{sections_under}) {
					my %new = (%{$self->{$opts{sections_under}}->{$section}}, zip(@keys, @vals));
					$self->{$opts{sections_under}}->{$section} = \%new;
				}
				else {
					my %new = (%{$self->{$section}}, zip(@keys, @vals));
					$self->{$section} = \%new;
				}
			}
			if($opts{chainload_configfiles} && $chain_configfile) {
				$self->{configfile} = $chain_configfile;
			}
		}
		$configfile;
	};

	local %ARGV = %ARGV; # Because --configfile gets deleted out of this.

	# Used cmd_ because I'm not entirely sure if the my scoping extends into the else block.
	# Delete --configfile out of ARGV so the file doesn't get loaded twice and so commandline options can override the config file.
	if(my $cmd_configfile = delete $ARGV{'--configfile'}) {
		$self->{configfile} = $cmd_configfile;
	}
	else {
		# Load one of the default config files.
		$self->{configfile} = $configfile || File::BaseDir->config_home($package, "$package.cfg");
	}

	# Set command line options.
	for(keys %ARGV) {
		$self->{trname($_)} = $ARGV{$_};
	}

	# Generate lv accessors for each config value.
	for my $field (keys %$self) {
		*{$field} = sub :lvalue {
			my $self = shift;
			$self->{$field} = shift if @_;
			$self->{$field};
		};
	}

	$self;
}

sub TIESCALAR {
	my($package, $coderef) = @_;
	die "Not a coderef: $coderef" unless ref($coderef) eq 'CODE';
	return bless $coderef, $package;
}

sub STORE { my $tied = shift; $tied->(@_); }
sub FETCH { shift->(); }

sub trname {
	shift;
	s/^-+//;
	s/-/_/g;
	return $_;
}

1;