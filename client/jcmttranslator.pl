#!/local/perl-5.6/bin/perl

=head1 NAME

jcmttranslator - translate science program XML to ODFs

=head1 SYNOPSIS

  cat sp.xml | jcmttranslator > outfile

=head1 DESCRIPTION

Reads science program xml from standard input and writes the
translated odf file name to standard output. The filename is
suitable for reading into the new DRAMA Queue.

=head1 ARGUMENTS

The following arguments are allowed:

NONE

=head1 OPTIONS

The following options are supported:

=over 4

=item B<-help>

A help message.

=item B<-man>

This manual page.

=item B<-cwd>

Write the translated files to the current working directory
rather than to the standard translation directory location.

=item B<-debug>

Turn on debugging messages.

=back

=cut

use warnings;
use strict;

use Pod::Usage;
use Getopt::Long;

# run relative to the client directory
use FindBin;
use lib "$FindBin::RealBin/../";



# Load the servers (but use them locally without SOAP)
use OMP::TransServer;
use File::Spec;

# Options
my ($help, $man, $debug, $cwd);
my $status = GetOptions("help" => \$help,
			"man" => \$man,
			"debug" => \$debug,
			"cwd" => \$cwd,
		       );

pod2usage(1) if $help;
pod2usage(-exitstatus => 0, -verbose => 2) if $man;

# debugging
$OMP::Translator::DEBUG = 1 if $debug;

# Translation directory override
$OMP::Translator::TRANS_DIR = "." if $cwd;

# Now for the action
# Read from standard input
my $xml;
{
  # Can not let this localization propoagate to the OMP classes
  # since this affects the srccatalog parsing
  local $/ = undef;
  $xml = <>;
}

my $filename = OMP::TransServer->translate( $xml );

# convert the filename to an absolute path
print File::Spec->rel2abs($filename) ."\n";

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut

