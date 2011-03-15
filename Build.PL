#! /usr/bin/env perl

use strict;
use warnings;

use Module::Build 0.3601;

my %module_build_args = (
	'dist_abstract' => 'IRC bot that automatically downloads picture links',
	'script_files'  => ['ksig.pl'],
	'license'       => 'isc',
	'dist_name'     => 'ksig',
	'dist_author'   => 'Kulag',
	'module_name'   => 'ksig',
	'requires'      => {
		'perl'              => '5.010',
		'Carp'              => '0',
		'Class::Accessor'    => '0',
		'Config::Std'       => '0',
		'common::sense'     => '0',
		'Data::Dumper'      => '0',
		'DateTime'          => '0',
		'DBI::SpeedySimple' => '0',
		'Digest::SHA1'      => '0',
		'Encode'            => '0',
		'File::BaseDir'     => '0',
		'File::Basename'    => '0',
		'File::Path'        => '0',
		'File::HomeDir'     => '0',
		'Getopt::Euclid'    => '0',
		'HTTP::Cookies'     => '0',
		'HTTP::Request::Common' => '0',
		'List::Util'        => '0',
		'List::MoreUtils'   => '0',
		'Log::Any'          => '0',
		'Log::Any::Adapter::Dispatch' => '0',
		'Log::Dispatch'     => '0',
		'Perl6::Subs'       => '0',
		'POE'               => '0',
		'POE::Component::Client::HTTP'             => '0',
		'POE::Component::IRC::State'               => '0',
		'POE::Component::IRC::Plugin::AutoJoin'    => '0',
		'POE::Component::IRC::Plugin::Connector'   => '0',
		'POE::Component::IRC::Plugin::NickReclaim' => '0',
		'POE::Session::Attribute'=> '0',
		'POSIX'             => '0',
		'Readonly'          => '0',
		'Time::HiRes'       => '0',
		'XML::Simple'       => '0',
	},
	'dist_version'  => 1,
);

my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
