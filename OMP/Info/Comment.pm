package OMP::Info::Comment;

=head1 NAME

OMP::Info::Comment - a comment

=head1 SYNOPSIS

  use OMP::Info::Comment;

  $resp = new OMP::Info::Comment( author => $user,
                                  text => $text,
                                  date => $date );
  $resp = new OMP::Info::Comment( author => $user,
                                  text => $text,
                                  status => OMP__DONE_DONE );

  $body = $resp->text;
  $user = $resp->author;


=head1 DESCRIPTION

This is used to attach comments to C<OMP::Info::MSB> and C<OMP::Info::Obs>
objects. Multiple comments can be stored in each of these objects.

=cut

use 5.006;
use warnings;
use strict;
use Carp;

use Time::Piece;

our $VERSION = (qw$Revision$)[1];

# Overloading
use overload '""' => "stringify";


=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new comment object. The comment must be supplied in the constructor
but "author", "status" and "date" are optional.


  $resp = new OMP::Info::Comment( author => $author,
                                  text => $text,
                                  status => 1 );

If it is not specified the current date will be used. The date must be
supplied as a C<Time::Piece> object and is assumed to be UT.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  # Arguments
  my %args = @_;

  # initialize the hash
  my $comm = {
	      Author => undef,
	      Text => undef,
	      Date => undef,
	      Status => undef,
	     };

  bless $comm, $class;

  # if a date has not been supplied get current
  $args{date} = gmtime() unless (exists $args{date} or exists $args{Date});

  # Invoke accessors to configure object
  for my $key (keys %args) {
    my $method = lc($key);
    if ($comm->can($method)) {
      $comm->$method( $args{$key});
    }
  }

  # Check that we have text
  croak "Must supply comment text"
    unless $comm->text;

  # Return the object
  return $comm;
}

=back

=head2 Accessor methods

=over 4

=item B<text>

Text content forming the comment. Should be in plain text.

  $text = $comm->text;
  $comm->text( $text );

=cut

sub text {
  my $self = shift;
  if (@_) { $self->{Text} = shift; }
  return $self->{Text};
}

=item B<author>

Name of person submitting the comment. This field is optional.

  $author = $comm->author;
  $comm->author( $author );

=cut

sub author {
  my $self = shift;
  if (@_) { $self->{Author} = shift; }
  return $self->{Author};
}

=item B<date>

The date the comment was filed. Returned (and must be supplied) as a
C<Time::Piece> object.

  $date = $comm->date;
  $comm->date( $date );

=cut

sub date {
  my $self = shift;
  if (@_) { 
    my $date = shift;
    croak "Date must be supplied as Time::Piece object"
      unless UNIVERSAL::isa( $date, "Time::Piece" );
    $self->{Date} = $date;
  }
  return $self->{Date};
}

=item B<status>

Status indicator associated with the comment.

=cut

sub status {
  my $self = shift;
  if (@_) { $self->{Status} = shift; }
  return $self->{Status};
}

=back

=head2 General Methods

=over 4

=item <stringify>

Convert comment to plain text for quick display.
This is the default stringification overload.

Just returns the comment text.

=cut

sub stringify {
  my $self = shift;
  return $self->text;
}

=back

=head1 SEE ALSO

C<OMP::Fault>, C<OMP::FaultDB>.

=head1 AUTHORS

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=cut

1;
