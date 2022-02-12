#!/local/perl/bin/perl -XT
use strict;

# Standard initialisation (not much shorter than the previous
# code but no longer has the module path hard-coded)
BEGIN {
  my $retval = do "./omp-cgi-init.pl";
  unless ($retval) {
    warn "couldn't parse omp-cgi-init.pl: $@" if $@;
    warn "couldn't do omp-cgi-init.pl: $!"    unless defined $retval;
    warn "couldn't run omp-cgi-init.pl"       unless $retval;
    exit;
  }
}

use OMP::CGIPage::Sched;

OMP::CGIPage::Sched->new(cgi => new CGI())->write_page(
    \&OMP::CGIPage::Sched::staff_sched_view,
    undef,
    'local_or_staff',
    title => 'Telescope Schedule');