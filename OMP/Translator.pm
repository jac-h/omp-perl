package OMP::Translator;

=head1 NAME

OMP::Translator - translate science program to sequence

=head1 SYNOPSIS

  use OMP::Translator;

  $odf = OMP::Translator->translate( $sp );


=head1 DESCRIPTION

This class converts a science program object (an C<OMP::SciProg>)
into a sequence understood by the data acquisition system.

In the case of SCUBA, an Observation Definition File (ODF) is
generated.


=cut

use 5.006;
use strict;
use warnings;

use OMP::SciProg;
use OMP::Error;

our $VERSION = (qw$Revision$)[1];

our $TRANS_DIR = "/tmp/omplog";

=head1 METHODS

=over 4

=item B<translate>

Convert the science program object (C<OMP::SciProg>) into
a observing sequence understood by the instrument data acquisition
system.

  $odf = OMP::Translate->translate( $sp );

Currently only understands SCUBA. Eventually will have to understand
ACSIS.

Returns a observation definition file, or if more than one observation
is generated from the SpObs, a SCUBA macro file.

=cut

sub translate {
  my $self = shift;
  my $sp = shift;

  # See how many MSBs we have
  my @msbs = $sp->msb;

  throw OMP::Error::TranslateFail("Only one MSB can be translated at a time")
    if scalar(@msbs) != 1;

  # Now get the MSB info
  my $msbinfo = $msbs[0]->info;




}

=back

=head1 COPYRIGHT

Copyright (C) 2002 Particle Physics and Astronomy Research Council.
All Rights Reserved.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=cut

1;
