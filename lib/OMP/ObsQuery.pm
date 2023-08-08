package OMP::ObsQuery;

=head1 NAME

OMP::ObsQuery - Class representing an XML OMP query of the Observation table

=head1 SYNOPSIS

  $query = new OMP::ObsQuery( XML => $xml );
  $sql = $query->sql( $obslogtable );

=head1 DESCRIPTION

This class can be used to process OMP Observation queries.
The queries are usually represented as XML.

=cut

use 5.006;
use strict;
use warnings;
use Carp;

# External modules
use OMP::Error;
use OMP::General;
use OMP::Range;

# Inheritance
use base qw/ OMP::DBQuery /;

# Package globals

our $VERSION = '2.000';

=head1 METHODS

=head2 Accessor Methods

=over 4

=item B<checksums>

Returns any checksums specified in the query.

 @checksums = $q->checksums;

=cut

sub checksums {
  my $self = shift;
  my $qhash = $self->query_hash();

  if (exists $qhash->{checksum}) {
    return @{ $qhash->{checksum} };
  } else {
    return ();
  }
}



=back

=head2 General Methods

=over 4

=item B<sql>

Returns an SQL representation of the XML Query using the specified
database table.

  $sql = $query->sql( $obslogtable );

Returns undef if the query could not be formed.

This query does not require any joins. The data returned by the SQL
generated by this method will include all matches but may include
partial matches for a particular MSB (ie only some of the comments).
To overcome this we must either first do a query on the table to
generate matching checksums in a temporary table and then do a
subsquent query using those checksums.

The results can include more than one row per MSB. It is up to the
caller to reorganize the resulting data into data structures
indexed by single MSB IDs with multiple comments.

=cut

sub sql {
  my $self = shift;

  throw OMP::Error::DBMalformedQuery("sql method invoked with incorrect number of arguments\n")
    unless scalar(@_) == 1;

  my ($table) = @_;

  # Generate the WHERE clause from the query hash
  # Note that we ignore elevation, airmass and date since
  # these can not be dealt with in the database at the present
  # time [they are used to calculate source availability]
  # Disabling constraints on queries should be left to this
  # subclass
  my $subsql = $self->_qhash_tosql();

  # Construct the the where clause. Depends on which
  # additional queries are defined
  my @where = grep { $_ } ( $subsql);
  my $where = '';
  $where = " WHERE " . join( " AND ", @where)
    if @where;

  # Prepare relevance expression if doing a fulltext index search.
  my @rel = $self->_qhash_relevance();
  my $rel = (scalar @rel) ? (join ' + ', @rel) : 0;

  # Now need to put this SQL into the template query
  my $sql = "(SELECT *, $rel AS relevance FROM $table $where)";

  return "$sql\n";

}

=begin __PRIVATE__METHODS__

=item B<_root_element>

Class method that returns the name of the XML root element to be
located in the query XML. This changes depending on whether we
are doing an MSB, a Project, or an Observation (Obs) query.
Returns "ObsQuery" by default.

=cut

sub _root_element {
  return "ObsQuery";
}

=item B<_post_process_hash>

Do table specific post processing of the query hash. For projects this
mainly entails converting range hashes to C<OMP::Range> objects (via
the base class), upcasing some entries and converting "status" fields
to queries on "remaining" and "pending" columns.

  $query->_post_process_hash( \%hash );

Also converts abbreviated form of project name to the full form
recognised by the database (this is why a telescope is required).

=cut

sub _post_process_hash {
  my $self = shift;
  my $href = shift;

  # Do the generic pre-processing
  $self->SUPER::_post_process_hash( $href );

  if (exists $href->{'text'}) {
    my $prefix = 'TEXTFIELD__';
    $prefix .= 'BOOLEAN__' if exists $href->{'_attr'}->{'text'}
      and exists $href->{'_attr'}->{'text'}->{'mode'}
      and $href->{'_attr'}->{'text'}->{'mode'} eq 'boolean';
    $href->{$prefix . 'commenttext'} = delete $href->{'text'};
  }

  # Remove attributes since we dont need them anymore
  delete $href->{_attr};

}


=end __PRIVATE__METHODS__

=back

=head1 Query XML

The Query XML is specified as follows:

=over 4

=item B<ObsQuery>

The top-level container element is E<lt>ObsQueryE<gt>.

=item B<Equality>

Elements that contain simply C<PCDATA> are assumed to indicate
a required value.

  <instrument>SCUBA</instrument>

Would only match if C<instrument=SCUBA>.

=item B<Ranges>

Elements that contain elements C<max> and/or C<min> are used
to indicate ranges.

  <elevation><min>30</min></elevation>
  <priority><max>2</max></priority>

Why dont we just use attributes?

  <priority max="2" /> ?

Using explicit elements is probably easier to generate.

Ranges are inclusive.

=item B<Multiple matches>

Elements that contain other elements are assumed to be containing
multiple alternative matches (C<OR>ed).

  <instruments>
   <instrument>CGS4</instrument>
   <instrument>IRCAM</instrument>
  </isntruments>

C<max> and C<min> are special cases. In general the parser will
ignore the plural element (rather than trying to determine that
"instruments" is the plural of "instrument"). This leads to the
dropping of plurals such that multiple occurrence of the same element
in the query represent variants directly.

  <name>Tim</name>
  <name>Kynan</name>

would suggest that names Tim or Kynan are valid (but Brad and Frossie
aren't, alas). This also means

  <instrument>SCUBA</instrument>
  <instruments>
    <instrument>CGS4</instrument>
  </instruments>

will select SCUBA or CGS4.

Neither C<min> nor C<max> can be included more than once for a
particular element. The most recent values for C<min> and C<max> will
be used. It is also illegal to use ranges inside a plural element.

=back

=head1 SEE ALSO

L<OMP::DBQuery>, L<OMP::MSBQuery>

=head1 AUTHORS

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>,
Brad Cavanagh E<lt>b.cavanagh@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2001-2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the
Free Software Foundation, Inc., 59 Temple Place, Suite 330,
Boston, MA  02111-1307  USA


=cut

1;
