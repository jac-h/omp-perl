#!/local/perl-5.6/bin/perl -T

use strict;
use OMP::FBServer;
use Mail::Audit;

my $mail = new Mail::Audit::OMP(loglevel => 4);

# Look for project ID
$mail->reject("Sorry. Could not discern project ID from the subject line.")
  unless $mail->projectid;

# Look for spam
$mail->reject("Sorry. This email looks like spam. Rejecting.")
  if $mail->get("X-Spam-Status") =~ /^Yes/;


# looks like we can accept this
$mail->accept;


exit;

package Mail::Audit::OMP;

# Process OMP feedback mail messages
use base qw/ Mail::Audit/;


# Accept a message and send it to the feedback system
sub accept {
  my $self = shift;

  Mail::Audit::_log(1,"Accepting");

  # Get the information we need
  my $from = $self->get("from");
  my $srcip = (  $from =~ /@(.*)$/ ? $1 : $from );
  my $subject = $self->get("subject");
  my $text = "<PRE>\n" . @{ $self->body } . "</PRE>";
  my $project = $self->get("projectid");
  chomp($project); # header includes newline

  # Contact the feedback system
  OMP::FBServer->addComment( $project, {
					author => $from,
					program => $0,
					subject => $subject,
					sourceinfo => $srcip,
					text => $text,
				       });

  print "Sending to Feedback from project $project\n";

  Mail::Audit::_log(1, "Sent to feedback system with Project $project");

  # Exit after delivery if required
  if (!$self->{noexit}) {
    Mail::Audit::_log(2,"Exiting with status ".Mail::Audit::DELIVERED);
    exit Mail::Audit::DELIVERED;
  }

}

# Determine the project ID from the subject and
# store it in the mail header
# Return 1 if subject found, else false
sub projectid {
  my $self = shift;
  my $subject = $self->get("subject");

  # Attempt to match
  if ($subject =~ /(u\/\d\d[ab]\/h?\d+)/i
     or $subject =~ /(m\d\d[ab][uncih]\d+)/i ) {
    my $pid = $1;
    $self->put_header("projectid", $pid);
    Mail::Audit::_log(1, "Project from subject: $pid");
    return 1;
  } else {
    Mail::Audit::_log(1, "Could not determine project from subject line");
    return 0;
  }

}


__END__
=head1 NAME

mail2feedback.pl - Forward mail message to OMP feedback system

=head1 SYNOPSIS

  cat mailmessage | mail2feedback.pl

=head1 DESCRIPTION

This program reads in mail messages from standard input, determines
the project ID from the subject line and forwards the message to
the OMP feedback system.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut

