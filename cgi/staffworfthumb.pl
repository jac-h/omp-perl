#!/local/perl-5.6/bin/perl
#
# WWW Observing Remotely Facility (WORF)
#
# http://www.jach.hawaii.edu/JACpublic/UKIRT/software/worf/
#
# Requirements:
# TBD
#
# Authors: Frossie Economou (f.economou@jach.hawaii.edu)
#          Brad Cavanagh (b.cavanagh@jach.hawaii.edu)

# Set up the environment for PGPLOT

BEGIN {
  $ENV{'PGPLOT_DIR'} = '/star/bin';
  $ENV{'PGPLOT_FONT'} = '/star/bin/grfont.dat';
  $ENV{'PGPLOT_BACKGROUND'} = 'white';
  $ENV{'PGPLOT_FOREGROUND'} = 'black';
  $ENV{'HDS_SCRATCH'} = "/tmp";

  use constant OMPLIB => "/jac_sw/omp/msbserver";
  use File::Spec;
  $ENV{'OMP_CFG_DIR'} = File::Spec->catdir( OMPLIB, "cfg" )
    unless exists $ENV{'OMP_CFG_DIR'};
}

# Bring in all the required modules

use CGI;
use CGI::Carp qw/fatalsToBrowser/;

# we need to point to a different directory to see ORAC and OMP modules

use lib OMPLIB;
use OMP::CGI;
use OMP::CGIWORF;

use strict;

# Set up global variables, system variables, etc.

$| = 1;  # make output unbuffered

my $query = new CGI;
my $cgi = new OMP::CGI( CGI => $query );
$cgi->html_title("WORF: WWW Observing Remotely Facility");

my @domain = OMP::General->determine_host;

# write the page

if( $domain[1] and $domain[1] !~ /\./) {
  $cgi->write_page_noauth( \&thumbnails_page, \&thumbnails_page );
} else {
  $cgi->write_page_staff( \&thumbnails_page, \&thumbnails_page );
}
