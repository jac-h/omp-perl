package OMP::FeedbackDB;

=head1 NAME

OMP::FeedbackDB - Manipulate the feedback database

=head1 SYNOPSIS

  $db = new OMP::FeedbackDB( ProjectID => $projectid,
			     Password => $password,
			     DB => $dbconnection );

  $db->addComment( $comment );
  $db->getComments( \@status );
  $db->alterStatus( $commentid, $status );


=head1 DESCRIPTION

This class manipulates information in the feedback table.  It is the
only interface to the database tables. The table should not be
accessed directly to avoid loss of data integrity.


=cut

use 5.006;
use strict;
use warnings;
use Carp;
use Time::Piece;
our $VERSION = (qw$ Revision: 1.2 $ )[1];

use OMP::Project;
use OMP::ProjDB;
use OMP::Constants;
use OMP::Error;

use base qw/ OMP::BaseDB /;

# This is picked up by OMP::MSBDB
our $FBTABLE = "ompfeedback";

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new instance of an C<OMP::FeedbackDB> object.

  $db = new OMP::FeedbackDB( ProjectID => $project,
                             Password => $password,
			     DB => $connection );

If supplied, the database connection object must be of type
C<OMP::DBbackend>.  It is not accepted if that is not the case.
(but no error is raised - this is probably a bug).

=cut

# Use base class constructor

=back

=head2 General Methods

=over 4

=item B<getComments>

Returns an array of hashes containing comments for the project. If
arguments are given they should be in the form of a hash whos keys are
B<status> and B<order>.  Value for B<status> should be an array
reference containing the desired status types of the comments to be
returned.  Status types are defined in C<OMP::Constants>.  Value for
B<order> should be 'ascending' or 'descending'.  Defaults to returning
comments with a status of B<OMP__FB_IMPORTANT> or B<OMP__FB_INFO>, and
sorts the comments in ascending order.

  @status = ( qw/OMP__FB_IMPORTANT OMP__FB_INFO/ );
  $comm = $db->getComments( status => \@status, order => 'descending' );

=cut

sub getComments {
  my $self = shift;

  my %defaults = (status => [OMP__FB_IMPORTANT, OMP__FB_INFO],
		  order => 'ascending',);

  my %args = (%defaults, @_);

  # Verify the password
  my $projdb = new OMP::ProjDB( ProjectID => $self->projectid,
			        DB => $self->db );

  throw OMP::Error::Authentication("Supplied password for project " .$self->projectid )
    unless $projdb->verifyPassword( $self->password );

  # Get the comments
  my $comment = $self->_fetch_comments( %args );


  # Throw out comments that with a status that isn't wanted
  # Strip out the milliseconds
  for (@$comment) {
    $_->{date} =~ s/:000/ /g;
  }

  return $comment;
}

=item B<addComment>

Adds a comment to the database.  Takes a hash reference containing the
comment and all of its details.  This method also mails the comment
depending on its status.

  $db->addComment( $comment );

=over 4

=item Hash reference should contain the following key/value pairs:

=item B<author>

The name of the author of the comment.

=item B<subject>

The subject of the comment.

=item B<program>

The program used to submit the comment.

=item B<sourceinfo>

The IP address of the machine comment is being submitted from.

=item B<text>

The text of the comment (HTML tags are encouraged).

=back


=cut

sub addComment {
  my $self = shift;
  my $comment = shift;

  throw OMP::Error::BadArgs( "Comment was not a hash reference" )
    unless UNIVERSAL::isa($comment, "HASH");

  my $t = gmtime;
  my %defaults = ( subject => 'none',
		   date => $t->strftime("%b %e %Y %T"),
		   program => 'unspecified',
		   sourceinfo => 'unspecified',
		   status => OMP__FB_IMPORTANT, );

  # Override defaults
  $comment = {%defaults, %$comment};

  # Check for required fields
  for (qw/ author text /) {
    throw OMP::Error::BadArgs("$_ was not specified")
      unless $comment->{$_};
  }

  # Check that the project actually exists
  my $projdb = new OMP::ProjDB( ProjectID => $self->projectid,
                                DB => $self->db, );

  $projdb->verifyProject()
    or throw OMP::Error::UnknownProject("Project " .$self->projectid. " not known.");

  # We need to think carefully about transaction management

  # Begin transaction
  $self->_db_begin_trans;
  $self->_dblock;

  # Store comment in the database
  $self->_store_comment( $comment );

  # End transaction
  $self->_dbunlock;
  $self->_db_commit_trans;

  # Mail the comment to interested parties
  ($comment->{status} == OMP__FB_IMPORTANT) and
    $self->_mail_comment_important( $self->projectid, $comment );

  ($comment->{status} == OMP__FB_INFO) and
    $self->_mail_comment_info( $self->projectid, $comment );

  #  $self->_mail_comment( $comment );

  return;
}

=item B<alterStatus>

Alters the status of a comment.

  $db->alterStatus( $commentid, $status);

Last argument should be a feedback constant as defined in C<OMP::Constants>.

=cut

sub alterStatus {
  my $self = shift;
  my $commentid = shift;
  my $status = shift;

  # Verify admin password.
  OMP::General->verify_administrator_password( $self->password );

  # Begin trans
  $self->_db_begin_trans;
  $self->_dblock;

  # Alter comment's status
  $self->_alter_status( $commentid, $status );

  # End trans
  $self->_dbunlock;
  $self->_db_commit_trans;


}

=back

=head2 Internal Methods

=over 4

=item B<_store_comment>

Stores a comment in the database.

  $db->_store_comment($comment);

=cut

sub _store_comment {
  my $self = shift;
  my $comment = shift;

  my $projectid = $self->projectid;

  # Create the comment entry number
  my $clause = "projectid = \"$projectid\"";
  my $entrynum = $self->_db_findmax( $FBTABLE, "entrynum", $clause);
  (defined $entrynum) and $entrynum++
    or $entrynum = 1;

  # Store the data
  $self->_db_insert_data( $FBTABLE,
			  $entrynum,
			  $projectid,
			  @$comment{ 'author',
				     'date',
				     'subject',
				     'program',
				     'sourceinfo',
				     'status',},
			  {
			   TEXT => $comment->{text},
			   COLUMN => 'text',
			  });

}

=item B<_mail_comment>

Mail the comment to the specified addresses.

  $db->_mail_comment( $comment, \@addresslist );

First argument should be a hash reference.

=cut

sub _mail_comment {
  my $self = shift;
  my $comment = shift;
  my $addrlist = shift;
 # Mail message
  my $msg = "\nAuthor: $comment->{author}\n" .
            "$comment->{text}\n";

  my $projectid = $self->projectid;

  # Put projectid in subject header if it isn't already there
  my $subject;
  ($comment->{subject} !~ /^\[.+\]/) and $subject = "[$projectid] $comment->{subject}"
    or $subject = "$comment->{subject}";

  $self->_mail_information(
			   message => $msg,
			   to => $addrlist,
			   from => "omp-feedback-system",
			   subject => "$subject\n\n",
			   headers => ["Reply-To: flex\@jach.hawaii.edu","Content-type: text/html"],
			  );

}

=item B<_mail_comment_important>

Will send the email to PI, COI and support emails.

  $db->_mail_comment_important( $projectid, $comment );

=cut

sub _mail_comment_important {
  my $self = shift;
  my $projectid = shift;
  my $comment = shift;

  my $projdb = new OMP::ProjDB( ProjectID => $projectid,
				DB => $self->db,
			      );

  my $proj = $projdb->_get_project_row;

  my @email = $proj->contacts;
  $self->_mail_comment( $comment, \@email );
}

=item B<_mail_comment_info>

Will send the message to support emails

  $db->_mail_comment_info( $projectid, $comment );

=cut

sub _mail_comment_info {
  my $self = shift;
  my $projectid = shift;
  my $comment = shift;

  # Get a ProjDB object so we can get info from the database
  my $projdb = new OMP::ProjDB( ProjectID => $projectid,
				DB => $self->db,
			      );

  # This is an internal method that removes password
  # verification. Since comments are not meant to need password
  # to be added we can not use $projdb->projectDetails [unless
  # we specfy the administrator password here]
  my $proj = $projdb->_get_project_row;

  my @email = $proj->piemail;

  $self->_mail_comment( $comment, \@email );
}

=item B<_fetch_comments>

Internal method to retrieve the comments from the database.  
The hash argument controls the sort order of the results and the
status of comments to be retrieved.

Only
argument is an array reference containing the desired statuses of the
comments to be returned.

  $db->_fetch_comments( %args );

Recognized hash keys are:

 order: "descending" or "ascending" by date
 status: Reference to array listing all desired status types

Returns either a reference or a list depending on the calling context.

=cut

sub _fetch_comments {
  my $self = shift;
  my %args = @_;

  my $projectid = $self->projectid;

  my $order;
  ($args{order} eq 'descending') and $order = 'desc'
    or $order = 'asc';

  $args{status} = [OMP__FB_IMPORTANT, OMP__FB_INFO] unless defined $args{status}
    and ref($args{status}) eq "ARRAY";

  # Construct the SQL
  # Use convert() in select statement to get seconds back with the date field.
  my $sql = "select author, entrynum, commid, convert(char(32), date, 109) as 'date', program, projectid, sourceinfo, status, subject, text from $FBTABLE where projectid = \"$projectid\" " .
            "AND status in (" . join(',',@{$args{status}}) . ") " .
	    "ORDER BY commid $order";

  # Fetch the data
  my $ref = $self->_db_retrieve_data_ashash( $sql );

  if (wantarray) {
    return @$ref;
  } else {
    return $ref;
  }
}

=item B<_alter_status>

Update the status field of an entry.

  _alter_status( $commentid, $status );

=cut

sub _alter_status {
  my $self = shift;
  my $commid = shift;
  my $status = shift;

  $self->_db_update_data( $FBTABLE,
			  { status => $status },
			  " commid = $commid ");

}

=back

=head1 SEE ALSO

This class inherits from C<OMP::BaseDB>.

For related classes see C<OMP::MSBDB> and C<OMP::ProjDB>.

=head1 COPYRIGHT

Copyright (C) 2001-2002 Particle Physics and Astronomy Research
Council.  All Rights Reserved.

=head1 AUTHORS

Kynan Delorey E<lt>k.delorey@jach.hawaii.eduE<gt>
Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=cut

1;
