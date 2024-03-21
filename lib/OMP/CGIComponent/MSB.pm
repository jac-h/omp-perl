package OMP::CGIComponent::MSB;

=head1 NAME

OMP::CGIComponent::MSB - Web display of MSB information

=head1 SYNOPSIS

    use OMP::CGIComponent::MSB;

=head1 DESCRIPTION

Helper methods for generating and displaying portions of web
pages that display MSB comments and general MSB information.

=cut

use 5.006;
use strict;
use warnings;
use Carp;

use Time::Seconds qw/ONE_HOUR/;
use CGI;

use OMP::Constants qw/:done/;
use OMP::DBServer;
use OMP::Display;
use OMP::Error qw/:try/;
use OMP::DateTools;
use OMP::General;
use OMP::Info::Comment;
use OMP::MSBDB;
use OMP::MSBDoneDB;
use OMP::MSBServer;
use OMP::ProjDB;
use OMP::ProjServer;
use OMP::SpServer;
use OMP::UserServer;

use base qw/OMP::CGIComponent/;

$| = 1;

=head1 Routines

=over 4

=item B<fb_msb_active>

Create a table of active MSBs for a given project

    $comp->fb_msb_active($projectid);

=cut

sub fb_msb_active {
    my $self = shift;
    my $projectid = shift;

    my $proj_info = OMP::MSBServer->getSciProgInfo($projectid, with_observations => 1);

    my $active = [$proj_info->msb()];

    # First go through the array quickly to make sure we have
    # some valid entries
    my @remaining = grep {$_->remaining > 0} @$active;
    my $total = @$active;
    my $left = @remaining;
    my $msbs = undef;
    if ($left > 0) {
        # Now print the table (with an est. time column) if we have content
        $msbs = $self->msb_table(msbs => $active);
    }

    return {
        msbs => $msbs,
        total => $total,
        left => $left,
        done => $total - $left,
    };
}

=item B<fb_msb_observed>

Create a table of observed MSBs for a given project

    $comp->fb_msb_observed($projectid);

=cut

sub fb_msb_observed {
    my $self = shift;
    my $projectid = shift;

    # Get observed MSBs
    my $observed = OMP::MSBServer->observedMSBs({
            projectid => $projectid,
            format => 'data',
            include_undo => 1
    });

    return undef unless scalar @$observed;
    return $self->msb_table(msbs => $observed);
}

=item B<msb_action>

Working in conjunction with the B<msb_comments> function described elsewhere
in this document this function decides if the form generated by B<msb_comments>
was submitted, and if so, what action to take.

    my $response = $comp->msb_action(%args);

Returns a reference to a hash containing C<messages> and C<errors> arrays.

=cut

sub msb_action {
    my $self = shift;
    my %args = @_;

    my $q = $self->cgi;
    my $projectid = (exists $args{'projectid'})
        ? $args{'projectid'}
        : scalar $q->param('projectid');

    my @messages = ();
    my @errors = ();

    if ($q->param("submit_msb_comment")) {
        # Submit a comment
        try {
            # Create the comment object
            my $trans = $q->param('transaction');
            my $comment = OMP::Info::Comment->new(
                author => $self->auth->user,
                text => scalar $q->param('comment'),
                status => OMP__DONE_COMMENT,
                ($trans ? ('tid' => $trans) : ()),
            );

            # Add the comment
            OMP::MSBServer->addMSBcomment($projectid,
                (scalar $q->param('checksum')), $comment);
            push @messages, "MSB comment successfully submitted.";
        }
        catch OMP::Error::MSBMissing with {
            my $Error = shift;
            push @errors, "MSB not found in database:",
                "$Error";
        }
        otherwise {
            my $Error = shift;
            push @errors, "An error occurred preventing the comment submission:",
                "$Error";
        };
    }
    elsif ($q->param("submit_remove")) {
        # Mark msb as 'all done'
        try {
            OMP::MSBServer->alldoneMSB($projectid, (scalar $q->param('checksum')));
            push @messages, "MSB removed from consideration.";
        }
        catch OMP::Error::MSBMissing with {
            my $Error = shift;
            push @errors, "MSB not found in database:",
                "$Error";
        }
        otherwise {
            my $Error = shift;
            push @errors,
                "An error occurred while attempting to mark the MSB as Done:",
                "$Error";
        };
    }
    elsif ($q->param("submit_undo")) {
        # Unmark msb as 'done'.
        try {
            OMP::MSBServer->undoMSB(
                $projectid,
                (scalar $q->param('checksum')),
                (scalar $q->param('transaction'))
            );
            push @messages, "MSB done mark removed.";
        }
        catch OMP::Error::MSBMissing with {
            my $Error = shift;
            push @errors, "MSB not found in database:",
                "$Error";
        }
        otherwise {
            my $Error = shift;
            push @errors,
                "An error occurred while attempting to remove the MSB Done mark:",
                "$Error";
        };
    }
    elsif ($q->param("submit_unremove")) {
        # Unremove a removed MSB.
        try {
            OMP::MSBServer->unremoveMSB($projectid, (scalar $q->param('checksum')));
            push @messages, "MSB no longer removed from consideration.";
        }
        catch OMP::Error::MSBMissing with {
            my $Error = shift;
            push @errors, "MSB not found in database:",
                "$Error";
        }
        otherwise {
            my $Error = shift;
            push @errors,
                "An error occurred while attempting to remove the MSB Done mark:",
                "$Error";
        };
    }

    return {
        messages => \@messages,
        errors => \@errors,
    };
}

=item B<msb_comments>

Creates an HTML table of MSB comments.

    my $msb_info = $comp->msb_comments($msbcomments, $sp);

Takes a reference to an array of C<OMP::Info::MSB> objects as the second argument.
Last argument is an optional Sp object.

=cut

sub msb_comments {
    my $self = shift;
    my $commentref = shift;
    my $sp = shift;

    my $q = $self->cgi;

    # Colors associated with statuses
    my %colors = (
        &OMP__DONE_FETCH => '#c9d5ea',
        &OMP__DONE_DONE => '#c6bee0',
        &OMP__DONE_REMOVED => '#8075a5',
        &OMP__DONE_COMMENT => '#9f93c9',
        &OMP__DONE_UNDONE => '#ffd8a3',
        &OMP__DONE_ABORTED => '#9573a0',
        &OMP__DONE_REJECTED => '#bc5a74',
        &OMP__DONE_SUSPENDED => '#ffb959',
        &OMP__DONE_UNREMOVED => '#8075a5',
    );

    my @msbs;
    foreach my $msb (@$commentref) {
      # If the MSB exists in the science program we'll provide a "Remove" button
        # and we'll be able to display the number of remaining observations.

        # this will be the actual science program MSB if it exists
        # We need this so that we can provide the correct button types
        my $spmsb;
        if ($sp && $sp->existsMSB($msb->checksum)) {
            $spmsb = $sp->fetchMSB($msb->checksum);
        }

        # Group the comments by transaction ID, while otherwise
        # preserving the ordering (although it's not clear if this
        # is well established).
        my @comments;
        do {
            my %groups = ();
            foreach my $c ($msb->comments()) {
                my $cur = $c->tid;

                unless ($cur) {
                 # Consider each comment with empty|undef transaction id unique.
                    push @comments, [$c];
                }
                elsif (exists $groups{$cur}) {
                    # Add comment to existing group.
                    push @{$groups{$cur}}, $c;
                }
                else {
                    # Create a new group.
                    push @comments, ($groups{$cur} = [$c]);
                }
            }
        };

        push @msbs, {
            info => $msb,
            msb => $spmsb,
            wavebands => $msb->wavebands,
            comments => [
                map {
                    my $n_done = 0;
                    foreach my $c (@$_) {
                        $n_done ++ if $c->status == OMP__DONE_DONE;
                        $n_done -- if $c->status == OMP__DONE_UNDONE;
                    }
                    {
                        comments => $_,
                        n_done => $n_done,
                    };
                } @comments
            ],
        };
    }

    return {
        target => $self->page->url_absolute(),
        status_colors => \%colors,
        msbs => \@msbs,
    };
}

=item B<msb_count>

Returns the current number of MSBs.

    my $num_msbs = $comp->msb_count($projectid);

=cut

sub msb_count {
    my $self = shift;
    my $projectid = shift;

    my $num_msbs = undef;
    try {
        my $msbs = OMP::MSBServer->getMSBCount($projectid);
        $num_msbs = (exists $msbs->{$projectid}) ? $msbs->{$projectid}->{'total'} : 0;

    }
    otherwise {
        my $E = shift;
    };

    return $num_msbs;
}

=item B<msb_table>

Create a table containing information about given MSBs

    $comp->msb_table(msbs => $msbs);

Arguments should be provided in hash form, with the following
keys:

=over 4

=item msbs

An array reference containing C<OMP::Info::MSB> objects (required).

=back

=cut

sub msb_table {
    my $self = shift;
    my %args = @_;

    # Check for required arguments
    for my $key (qw/msbs/) {
        throw OMP::Error::BadArgs("The argument [$key] is required.")
            unless (defined $args{$key});
    }

    my $program = $args{msbs};

    # Note that this doesnt really work as code shared for MSB and
    # MSB Done summaries
    my @filtered;
    foreach my $msb (@$program) {
        # skip if we have a remaining field and it is 0 or less
        # dont skip if the remaining field is simply undefined
        # since that may be a valid case
        next if defined $msb->remaining && $msb->remaining <= 0;

        # Skip if this is only a fetch comment
        next if (scalar @{$msb->comments}
            && $msb->comments->[0]->status == &OMP__DONE_FETCH);

        push @filtered, $msb;
    }

    return \@filtered;
}

1;

__END__

=back

=head1 SEE ALSO

C<OMP::CGI::MSBPage>

=head1 AUTHOR

Kynan Delorey E<lt>k.delorey@jach.hawaii.eduE<gt>

=head1 COPYRIGHT

Copyright (C) 2004 Particle Physics and Astronomy Research Council.
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
