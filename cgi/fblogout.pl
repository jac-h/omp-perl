#!/local/perl-5.6/bin/perl -XT

use CGI;
use CGI::Carp qw/fatalsToBrowser/;

BEGIN { $ENV{SYBASE} = "/local/progs/sybase";
	$ENV{OMP_CFG_DIR} = "/jac_sw/omp/msbserver/cfg"
	  unless exists $ENV{OMP_CFG_DIR};
      }

use lib qw(/jac_sw/omp/msbserver);

use OMP::CGI;
use OMP::CGIHelper;
use strict;
use warnings;

my $arg = shift @ARGV;

my $q = new CGI;
my $ompcgi = new OMP::CGI( CGI => $q );

my $title = $ompcgi->html_title;
$ompcgi->html_title("$title: Logout");
$ompcgi->write_page_logout( \&fb_logout );
