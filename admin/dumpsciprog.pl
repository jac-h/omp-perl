#!/local/perl-5.6/bin/perl

# Dump the contents of the Database
# [currently only the science programs and the project info]
# to disk

# Note: Faults, Feedback and MSBDone info is not dumped!!!!

# The output directory is obtained from $OMP_DUMP_DIR

use 5.006;
use strict;
use warnings;

BEGIN { $ENV{SYBASE} = "/local/progs/sybase";
	$ENV{OMP_CFG_DIR} = "/jac_sw/omp/msbserver/cfg";
	$ENV{PATH} = "/usr/bin";
      }

use lib qw(/jac_sw/omp/msbserver);

use OMP::Config;
use OMP::MSBDB;
use OMP::DBbackend;
use OMP::ProjServer;
use OMP::Error qw/ :try /;
use Data::Dumper;
use Time::Piece;

# Abort if $OMP_DUMP_DIR is not set
$ENV{OMP_DUMP_DIR} = "/DSS/omp-cache/sciprogs"
  unless exists $ENV{OMP_DUMP_DIR};

chdir $ENV{OMP_DUMP_DIR}
  or die "Error changing to directory $ENV{OMP_DUMP_DIR}: $!\n";

my $dumplog = $ENV{OMP_DUMP_DIR} . "/dumpsciprog.log";

# Get the date of the last dump
my $date;
if (-e $dumplog) {
  open my $fh, "$dumplog" or die "Error opening file $dumplog: $!";
  my $line = <$fh>;
  close $fh;
  $date = gmtime($line);
  (! $date) and die "Unable to parse date of last dump!";
}

my $db = new OMP::MSBDB( DB => new OMP::DBbackend );

# Query the database for all projects whose programs have been modified
# since the last dump
my @projects;
if ($date) {
  @projects = map { OMP::ProjServer->projectDetails( $_, "***REMOVED***", "object" ) }
    $db->listModified($date);
} else {
  my $projects = OMP::ProjServer->listProjects("<ProjQuery></ProjQuery>", "object");
  @projects = @$projects;
}

exit unless ($projects[0]);

# Now for each of these projects attempt to read a science program
for my $proj (@projects) {
  my $projid = $proj->projectid;
  try {

    # Create new DB object using backdoor password
    my $db = new OMP::MSBDB( Password => "***REMOVED***",
			     ProjectID => $projid,
			     DB => new OMP::DBbackend );

    my $xml = $db->fetchSciProg(1);

    print "Retrieved science program for project $projid\n";

    # Write it out
    my $outfile = $projid . ".xml";
    $outfile =~ s/\//_/g;
    open my $fh, "> $outfile" or die "Error opening outfile\n";
    print $fh $xml;
    close $fh;

  } otherwise {
    print "No science program available for $projid\n";

  };

}

# Now dump the project info
my $outfile = "projects.dump";
open my $fh, ">$outfile" or die "Error opening file $outfile: $!";
print $fh Dumper(@projects);
close $fh;

# Write date of this dump to the log
my $today = gmtime;
open my $log, ">$dumplog" or die "Error opening file $dumplog: $!";
print $log $today->epoch;
print $log "\nTHIS FILE KEEPS TRACK OF THE MOST RECENT SCIENCE PROGRAM DUMP.\nREMOVING THIS FILE WILL RESULT IN A REFETCH OF ALL SCIENCE PROGRAMS.";
close $log;
