package OMP::CGI::Project;

=head1 NAME

OMP::CGI::Project - Web display of project information

=head1 SYNOPSIS

  use OMP::CGI::Project;

=head1 DESCRIPTION

Helper methods for creating web pages that display project
information.

=cut

use 5.006;
use strict;
use warnings;
use Carp;

use OMP::Config;
use OMP::Display;
use OMP::General;
use OMP::MSBServer;
use OMP::ProjDB;
use OMP::ProjServer;

$| = 1;

=head1 Routines

=over 4

=item B<list_project_form>

Create a form for taking the semester parameter

  list_projects_form($cgi);

=cut

sub list_projects_form {
  my $q = shift;

  my $db = new OMP::ProjDB( DB => OMP::DBServer->dbConnection, );

  # get the current semester for the default telescope case
  # so it can be defaulted in addition to the list of all semesters
  # in the database
  my $sem = OMP::General->determine_semester;
  my @sem = $db->listSemesters;

  # Make sure the current semester is a selectable option
  my @a = grep {$_ =~ /$sem/i} @sem;
  (!@a) and unshift @sem, $sem;

  # Get the telescopes for our popup menu
  my @tel = $db->listTelescopes;
  unshift @tel, "Any";

  my @support = $db->listSupport;
  my @sorted = sort {$a->userid cmp $b->userid} @support;
  my @values = map {$_->userid} @sorted;

  my %labels = map {$_->userid, $_} @support;
  $labels{dontcare} = "Any";
  unshift @values, 'dontcare';

  my @c = $db->listCountries;

  # Take serv and jac out of the countries list
  my @countries = grep {$_ !~ /^serv$|^jac$/i} @c;
  unshift @countries, 'Any';

  print "<table border=0><tr><td align=right>Semester: </td><td>";
  print $q->startform;
  print $q->hidden(-name=>'show_output',
		   -default=>1,);
  print $q->popup_menu(-name=>'semester',
		       -values=>\@sem,
		       -default=>uc($sem),);
  print "</td><tr><td align='right'>Telescope: </td><td>";
  print $q->popup_menu(-name=>'telescope',
		       -values=>\@tel,
		       -default=>'Any',);
  print "</td><tr><td align='right'>Show: </td><td>";
  print $q->radio_group(-name=>'status',
		        -values=>['active', 'inactive', 'all'],
			-labels=>{active=>'Time remaining',
				  inactive=>'No time remaining',
				  all=>'Both',},
		        -default=>'active',);
  print "<br>";
  print $q->radio_group(-name=>'state',
		        -values=>[1,0,'all'],
		        -labels=>{1=>'Enabled',
				  0=>'Disabled',
				  all=>'Both',},
		        -default=>1,);
  print "</td><tr><td align='right'>Support: </td><td>";
  print $q->popup_menu(-name=>'support',
		       -values=>\@values,
		       -labels=>\%labels,
		       -default=>'dontcare',);
  print "</td><tr><td align='right'>Country: </td><td>";
  print $q->popup_menu(-name=>'country',
		       -values=>\@countries,
		       -default=>'Any',);
  print "</td><tr><td align='right'>Order by:</td><td colspan=2>";
  print $q->radio_group(-name=>'order',
			-values=>['priority', 'projectid'],
		        -labels=>{priority => 'Priority',
				  projectid => 'Project ID',},
		        -default=>'priority',);
  print "</td><tr><td colspan=2>";
  print $q->checkbox(-name=>'table_format',
		     -value=>1,
		     -label=>'Display using tabular format',
		     -checked=>'true',);
  print "&nbsp;&nbsp;&nbsp;";
  print $q->submit(-name=>'Submit');
  print $q->endform();
  print "</td></table>";
}

=item B<proj_status_table>

Creates an HTML table containing information relevant to the status of
a project.

  proj_status_table( $cgi, %cookie);

First argument should be the C<CGI> object.  The second argument
should be a hash containing the contents of the C<OMP::Cookie> cookie
object.

=cut

sub proj_status_table {
  my $q = shift;
  my %cookie = @_;

  # Get the project details
  my $project = OMP::ProjServer->projectDetails( $cookie{projectid},
						 $cookie{password},
						 'object' );

  my $projectid = $cookie{projectid};

  # Link to the science case
  my $case_href = "<a href='props.pl?urlprojid=$projectid'>Science Case</a>";

  # Get the CoI email(s)
  my $coiemail = join(", ",map{OMP::Display->userhtml($_, $q, $project->contactable($_->userid), $project->projectid) } $project->coi);

  # Get the support
  my $supportemail = join(", ",map{OMP::Display->userhtml($_, $q)} $project->support);

  print "<table border='0' cellspacing=1 cellpadding=2 width='100%' bgcolor='#bcbee3'><tr>",
	"<td colspan=3><font size=+2><b>Current project status</b></font></td>",
	"<tr bgcolor=#7979aa>",
	"<td><b>PI:</b>".OMP::Display->userhtml($project->pi, $q, $project->contactable($project->pi->userid), $project->projectid)."</td>",
	"<td><b>Title:</b> " . $project->title . "</td>",
	"<td> $case_href </td>",
	"<tr bgcolor='#7979aa'><td colspan='2'><b>CoI:</b> $coiemail</td>",
	"<td><b>Staff Contact:</b> $supportemail</td>",
        "<tr bgcolor='#7979aa'><td><b>Time allocated:</b> " . $project->allocated->pretty_print . "</td>",
	"<td><b>Time Remaining:</b> " . $project->allRemaining->pretty_print . "</td>",
	"<td><b>Country:</b>" . $project->country . "</td>",
        "</table><p>";
}

=item B<proj_sum_table>

Display details for multiple projects in a tabular format.

  proj_sum_table($projects, $cgi, $headings);

If the third argument is true, table headings for semester and
country will appear.

=cut

sub proj_sum_table {
  my $projects = shift;
  my $q = shift;
  my $headings = shift;

  my $url = OMP::Config->getData('omp-url') . OMP::Config->getData('cgidir');

  print "<table cellspacing=0>";
  print "<tr align=center><td>Project ID</td>";
  print "<td>PI</td>";
  print "<td>Support</td>";
  print "<td># MSBs</td>";
  print "<td>Priority</td>";
  print "<td>Allocated</td>";
  print "<td>Completed</td>";
  print "<td>Tau range</td>";
  print "<td>Seeing range</td>";
  print "<td>Sky</td>";
  print "<td>Title</td>";

  my %bgcolor = (dark => "#6161aa",
		 light => "#8080cc",
                 disabled => "#e26868",
		 heading => "#c2c5ef",);

  my $bgcolor = $bgcolor{dark};

  my $hsem;
  my $hcountry;

  # Count msbs for each project
  my @projectids = map {$_->projectid} @$projects;
  my %msbcount = OMP::MSBServer->getMSBCount(@projectids);

  foreach my $project (@$projects) {

    if ($headings) {
      # If the country or semester for this project are different
      # than the previous project row, create a new heading

      if ($project->semester_ori ne $hsem or $project->country ne $hcountry) {
	$hsem = $project->semester_ori;
	$hcountry = $project->country;
	print "<tr bgcolor='$bgcolor{heading}'><td colspan=11>Semester: $hsem, Country: $hcountry</td></td>";
      }
    }

    # Get MSB counts
    my $nmsb = $msbcount{$project->projectid}{total};
    my $nremaining = $msbcount{$project->projectid}{active};
    (! defined $nmsb) and $nmsb = 0;
    (! defined $nremaining) and $nremaining = 0;

    # Get seeing and tau info
    my $taurange = $project->taurange;
    my $seerange = $project->seerange;

    # Make sure there is a valid range to display
    for ($taurange, $seerange) {
      if ($_->min == 0 and ! defined $_->max) {
	$_ = "--";
      } else {
	$_ = $_->stringify;
      }
    }

    my $support = join(", ", map {$_->userid} $project->support);

    # Make it noticeable if the project is disabled
    (! $project->state) and $bgcolor = $bgcolor{disabled};

    print "<tr bgcolor=$bgcolor valign=top>";
    print "<td><a href='$url/projecthome.pl?urlprojid=". $project->projectid ."'>". $project->projectid ."</a></td>";
    print "<td>". OMP::Display->userhtml($project->pi, $q, $project->contactable($project->pi->userid), $project->projectid) ."</td>";
    print "<td>". $support ."</td>";
    print "<td align=center>$nremaining/$nmsb</td>";
    print "<td align=center>". $project->tagpriority ."</td>";
    print "<td align=center>". $project->allocated->pretty_print ."</td>";
    print "<td align=center>". sprintf("%.0f",$project->percentComplete) . "%</td>";
    print "<td align=center>$taurange</td>";
    print "<td align=center>$seerange</td>";
    print "<td align=center>". $project->cloudtxt ."</td>";
    print "<td>". $project->title ."</td>";

    # Alternate background color
    ($bgcolor eq $bgcolor{dark}) and $bgcolor = $bgcolor{light}
      or $bgcolor = $bgcolor{dark};
  }

  print "</table>";

}

=head1 SEE ALSO

C<OMP::CGI::ProjectPage>

=back

=head1 AUTHOR

Kynan Delorey E<lt>k.delorey@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2004 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut

1;
