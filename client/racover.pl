#!/local/perl/bin/perl

=head1 NAME

racover - Present source coverage for the semester

=head1 SYNOPSIS

  racover -tel jcmt -semester 04B
  racover -tel ukirt -country uk -instrument ufti

=head1 DESCRIPTION

This program collates data for each active program in the specified
semester and presents a histogram of RA coverage for all the MSBs
present in the science programmes.

=head1 OPTIONS

The following options are supported:

=over 4

=item B<-tel>

Specify the telescope to use for the report. If the telescope can
be determined from the domain name it will be used automatically.
If the telescope can not be determined from the domain and this
option has not been specified a popup window will request the
telescope from the supplied list (assume the list contains more
than one telescope).

=item B<-semester>

Semester to query. Defaults to the current semester.

=item B<-country>

Country to query. Defaults to all countries.

=item B<-instrument>

Restrict the query to a specific instrumnet. Default to all.

=item B<-version>

Report the version number.

=item B<-help>

A help message.

=item B<-man>

This manual page.

=back

=cut

use 5.006;
use strict;
use warnings;

use Getopt::Long;
use Pod::Usage;
use Term::ReadLine;
use Graphics::PLplot;
use List::Util qw/ max /;

# Locate the OMP software through guess work
use FindBin;
use lib "$FindBin::RealBin/..";

# OMP Classes
use OMP::Error qw/ :try /;
use OMP::General;
use OMP::ProjServer;
use OMP::SpServer;

use vars qw/ $DEBUG /;
$DEBUG = 0;

# Options
my ($help, $man, $version, $tel, $semester, $country, $instrument);
my $status = GetOptions("help" => \$help,
                        "man" => \$man,
                        "version" => \$version,
                        "semester=s" => \$semester,
			"instrument=s" => \$instrument,
			"country=s" => \$country,
                        "tel=s" => \$tel,
                       );

pod2usage(1) if $help;
pod2usage(-exitstatus => 0, -verbose => 2) if $man;

if ($version) {
  my $id = '$Id$ ';
  print "ompracover - Display RA coverage for a semester\n";
  print " CVS revision: $id\n";
  exit;
}

# First thing we do is ask for a password and possibly telescope
my $term = new Term::ReadLine 'Gather RA coverage stats';

# Telescope
my $telescope;
if(defined($tel)) {
  $telescope = uc($tel);
} else {
  # Should be able to pass in a readline object if Tk not desired
  $telescope = OMP::General->determine_tel($term);
  die "Unable to determine telescope. Exiting.\n" unless defined $telescope;
  die "Unable to determine telescope [too many choices]. Exiting.\n" 
     if ref $telescope;
}


# Default the semester if necessary
$semester = OMP::General->determine_semester()
   unless defined $semester;


# Form the country part of the query [and a useful string for later]
my $ctryxml = (defined $country ? "<country>$country</country>" : "");
my $ctrystr = (defined $country ? "Country ".uc($country) : '');

# Form instrument string
$instrument = uc($instrument) if defined $instrument;
my $inststr = (defined $instrument ? "Instrument $instrument" : '');

# Form the query string for the projects
my $query = "<ProjQuery><telescope>$telescope</telescope><semester>$semester</semester>$ctryxml<state>1</state></ProjQuery>";

print "Querying database for project details...\n";
my $projects = OMP::ProjServer->listProjects( $query, "object" );

print "Located " . scalar(@$projects). " active projects in Semester $semester\n";


# Needs Term::ReadLine::Gnu
my $attribs = $term->Attribs;
$attribs->{redisplay_function} = $attribs->{shadow_redisplay};
my $password = $term->readline( "Please enter staff password: ");
$attribs->{redisplay_function} = $attribs->{rl_redisplay};

OMP::General->verify_staff_password( $password );

print "Password Verified. Now analyzing MSB information.\n";

# Make an array indexed by integer RA
my @rahist = map { 0 } (0..23);

# print header
printf "RA: ".("%02d "x scalar(@rahist))."\n", (0..$#rahist);

# Loop over all the projects and retrieve the science program
my $i = 0;
for my $proj (@$projects) {
  print $proj->projectid ."\n";
  my $sp;
  try {
    $sp = OMP::SpServer->fetchProgram($proj->projectid, $password, 1);
  } catch OMP::Error::UnknownProject with {
    print "Unable to retrieve science programme. Skipping\n";
  };
  next unless defined $sp;

  # Local counter
  my @local = map { 0 } (0..23);

  # Now loop over each MSB
  for my $msb ($sp->msb) {

    my $remaining = $msb->remaining;

    # Filter out complete MSBs or removed MSBs.
    next unless $remaining > 0;

    for my $obs ($msb->obssum) {
      # skip if we are specifically looking for one instrument
      next if (defined $instrument && $obs->{instrument} ne $instrument);

      my $target = $obs->{coords};
      if ($target->type ne 'RADEC') {
	# warn "Target ". $target->name ." in project ". $proj->projectid . " is non-sidereal. Skipping\n";
	next;
      }
      my $ra = $target->ra( format => 'h' );
      $ra = int( $ra + 0.5);
      $ra = 0 if $ra >= 24;

      # Take into account the estimated duration of each SpObs
      # If we are just counting SpObs this factor is always 1
      my $dur = $obs->{timeest} / 3600;

      # Total time for this SpObs is the duration of the observation
      # times the number of repeats
      my $incr = $remaining * $dur;

      # Add an entry for each repeat of an MSB
      $rahist[$ra] += $incr;
      $local[$ra] += $incr;

    }


  }

  # print stats for this project
  printf "    ". ("%02d "x scalar(@local))."\n", map {$_+0.5} @local;
#  $i++;
#  last if $i > 5;

}

print "Complete results:\n";
  printf "    ". ("%02d "x scalar(@rahist))."\n", map {$_+0.5} @rahist;

# Now plot the results

plsdev( "xwin" );
plinit();
pladv(0);

my $xmin = 0;
my $xmax = 24;
my $ymin = 0;
my $ymax = max(@rahist) * 1.01;

plvsta();
plwind($xmin, $xmax, $ymin, $ymax);
plbox("bc", 1.0, 0, "bcnv", 25, 5);
plcol0(2);
pllab("RA / hrs", "Estimated Duration / hrs",
      "Semester $semester for telescope $telescope $ctrystr $inststr");

my $binsz = 1/scalar(@rahist);

my $cnum = 1;
for my $i (0..$#rahist) {
  $cnum++;
  $cnum = 2 if $cnum > 15;
  plcol0( $cnum);
  plpsty(0);
  plfbox( ( $xmin + $i ), $rahist[$i]);
  plptex( ( $xmin + $i + 0.5), ($rahist[$i]+(0.01*$ymax)),
	  1, 0.0, 0.5, int($rahist[$i]+0.5));

  # Annotate every other
  plmtex("b",1,(($i+1) * ($binsz) - (0.5*$binsz)), 0.5, ($xmin+$i))
    if $i % 2;

}

my $outfile = "ra_coverage.eps";
save_plot($outfile);
print "Histogram written to file $outfile\n";

plend();
exit;

# Taken from x12.t. It is amazing that PLplot does not have
# a bar chart command
sub plfbox {
  my ($x0, $y0) = @_;
  my @x = ( $x0, $x0, $x0+1, $x0+1);
  my @y = ( 0, $y0, $y0, 0);

  plfill(\@x, \@y);
  plcol0(1);
  pllsty(1);
  plline(\@x, \@y);
}

# Taken from x20.t

sub save_plot {
  my $fname = shift;

  my $cur_strm = plgstrm();
  my $new_strm = plmkstrm();

  # Need a white background so drop colour for now
  plsdev("ps");
  plsfnam($fname);

  plcpstrm($cur_strm, 0);
  plreplot();
  plend1();

  plsstrm( $cur_strm );

}


=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2004 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut
