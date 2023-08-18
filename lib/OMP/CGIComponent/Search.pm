package OMP::CGIComponent::Search;

=head1 NAME

OMP::CGIComponent::Search - CGI functions relating to search operations

=head1 SYNOPSIS

    use OMP::CGIComponent::Search;

    $search = OMP::CGIComponent::Search->new(page => $page);

=cut

use strict;
use warnings;

use Carp;
use Time::Piece;
use Time::Seconds qw/ONE_DAY/;

use OMP::DateTools;
use OMP::Display;
use OMP::UserServer;

use parent qw/OMP::CGIComponent/;

=head1 METHODS

=over 4

=item read_search_common

Read common search values from CGI parameters.

    %values = $search->read_search_common();

=cut

sub read_search_common {
    my $self = shift;

    my $q = $self->cgi;

    my %values = ();

    $values{'text_boolean'} = ($q->param('text_boolean') ? 1 : 0);

    foreach (qw/text period author mindate maxdate days/) {
        my $val = $q->param($_);
        $values{$_} = $val if defined $val;
    }

    return %values;
}

=item read_search_sort

Read C<sort_by> and C<sort_order> CGI parameters.

    %values = $search->read_search_sort();

=cut

sub read_search_sort {
    my $self = shift;

    my $q = $self->cgi;

    return (
        sort_by => (scalar $q->param('sort_by')),
        sort_order => (scalar $q->param('sort_order')),
    );
}

=item common_search_xml

Prepare database query XML fragments for common search parameters.

    ($message, $xml) = $search->read_search_sort(\%values, $authorfield);

=cut

sub common_search_xml {
    my $self = shift;
    my $values = shift;
    my $authorfield = shift;

    my @xml;
    my $message = undef;

    if ($values->{'text'}) {
        push @xml, '<text'
            . ($values->{'text_boolean'} ? ' mode="boolean"' : '') . '>'
            . OMP::Display::escape_entity($values->{'text'})
            . '</text>';
    }
    else {
        $message = 'No query text specified.';
    }

    if ($values->{'author'}) {
        my $author = uc $values->{'author'};

        my $user = OMP::UserServer->getUser($author);

        unless ($user) {
            $message = "Could not find user '$author'.";
        }
        else {
            push @xml, '<' . $authorfield . '>' . $user->userid . '</' . $authorfield . '>';
        }
    }

    if ($values->{'period'} eq 'arbitrary') {
        my ($mindate, $maxdate) = map {
            my $datestr = $values->{$_};
            unless ($datestr) {
                undef;
            }
            elsif ($datestr !~ /^\d{8}$/a and $datestr !~ /^\d\d\d\d-\d\d-\d\d$/a) {
                $message = 'Date "' . $datestr . '" not understood.';
                undef;
            }
            else {
                OMP::DateTools->parse_date($datestr);
            }
        } qw/mindate maxdate/;

        if ($mindate or $maxdate) {
            push @xml, '<date>';
            if ($mindate) {
                push @xml, '<min>' . $mindate->ymd. '</min>';
            }
            if ($maxdate) {
                $maxdate += ONE_DAY;
                push @xml, '<max>' . $maxdate->ymd . '</max>';
            }
            push @xml, '</date>';
        }
    }
    elsif ($values->{'period'} eq 'days') {
        my $days = $values->{'days'};
        if ($days) {
            unless ($days =~ /^\d+$/) {
                $message = 'Day range "' . $days . '" not understood.';
            }
            else {
                my $t = gmtime;
                $t += ONE_DAY;
                push @xml, '<date delta="-' . $days . '">'. $t->ymd. '</date>';
            }
        }
    }

    return ($message, \@xml);
}

=item sort_search_results

Sort the given list of search results.

    $results = $search->sort_search_results(\%values, $datefield, \@results);

=cut

sub sort_search_results {
    my $self = shift;
    my $values = shift;
    my $datefield = shift;
    my $results = shift;

    if ($values->{'sort_by'} eq 'date') {
        if ($values->{'sort_order'} eq 'ascending') {
            return [sort {$a->$datefield->epoch <=> $b->$datefield->epoch} @$results];
        }
        return [sort {$b->$datefield->epoch <=> $a->$datefield->epoch} @$results];
    }

    # Assume sort_by relevance.
    if ($values->{'sort_order'} eq 'ascending') {
        return [sort {$a->relevance() <=> $b->relevance()} @$results];
    }
    return [sort {$b->relevance() <=> $a->relevance()} @$results];
}

1;

__END__

=back

=head1 COPYRIGHT

Copyright (C) 2023 East Asian Observatory
All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc.,51 Franklin
Street, Fifth Floor, Boston, MA  02110-1301, USA

=cut
