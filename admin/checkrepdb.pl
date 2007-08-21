use warnings;
use strict;

use FindBin;
use lib "$FindBin::RealBin/..";

use MIME::Lite;

use OMP::BaseDB;
use OMP::DBbackend;
use OMP::Error qw/ :try /;
use OMP::KeyDB;

my $msg;
my $trunc;
my $missing;
my $row_count;
my $missing_msb;
my $critical;
my $fault = 0;

my $primary_db = "SYB_OMP1";
my $secondary_db = "SYB_OMP2";
my $primary_kdb;
my $secondary_kdb;
my $primary_db_down;
my $secondary_db_down;

# Do insert on primary DB
$ENV{OMP_DBSERVER} = $primary_db;
try {
  $primary_kdb = new OMP::KeyDB( DB => new OMP::DBbackend );
} catch OMP::Error with {
  my $E = shift;
  $primary_db_down = 1;
  $critical = 1;
};

if ($primary_db_down) {
  $msg .= "Database $primary_db is down!\n";
} else {
  $msg .= "Database $primary_db is up. [OK]\n";
}

my $key = $primary_kdb->genKey()
  unless (! $primary_kdb);

sleep 20;

# Look for insert on replicate DB
$ENV{OMP_DBSERVER} = $secondary_db;
try {
  $secondary_kdb = new OMP::KeyDB( DB => new OMP::DBbackend(1) )
} catch OMP::Error with {
  $secondary_db_down = 1;
  $critical = 1;
};

if ($secondary_db_down) {
  $msg .= "Database $secondary_db is down!\n";
} else {
  $msg .= "Database $secondary_db is up. [OK]\n";
}

my $verify = $secondary_kdb->verifyKey($key)
  unless (! $secondary_kdb);

if ($primary_db_down or $secondary_db_down) {
  $msg .= "\nCannot proceed with tests.\n";
}

unless ($primary_db_down or $secondary_db_down) {
  if ($verify) {
    $msg .= "\nReplication server ($primary_db -> $secondary_db) is actively replicating. [OK]\n\n";
  } else {
    $critical = 1;
    $msg .= "\nReplication server ($primary_db -> $secondary_db) is not replicating!\n\n";
  }

  # Check for truncated science programs
  my $sql = "SELECT projectid FROM ompsciprog WHERE sciprog not like \"%</SpProg>%\"";

  my %results;
  for my $dbserver (qw/SYB_OMP1 SYB_OMP2/) {
    $ENV{OMP_DBSERVER} = $dbserver;
    my $db = new OMP::BaseDB( DB => new OMP::DBbackend(1) );
    
    my $ref = $db->_db_retrieve_data_ashash( $sql );

    if ($ref->[0]) {
      map {push @{$results{$dbserver}}, $_->{projectid}} @$ref;
    }
  }

  if (%results) {
    $trunc = 1;
    $fault++;
    $msg .= "Truncated science programs found!\n";
    for my $dbserver (keys %results) {
      $msg .= "$dbserver:\n";
      map {$msg .= "\t$_\n"} @{$results{$dbserver}};
      $msg .= "\n";
    }
  } else {
    $msg .= "No truncated science programs found. [OK]\n\n";
  }

  # Check for missing science programs
  my $missing_sql = "SELECT DISTINCT F.projectid\n".
    "FROM ompfeedback F, ompsciprog S\n".
      "WHERE F.projectid = S.projectid\n".
	"AND F.msgtype = 70\n".
	  "AND S.sciprog LIKE NULL";

  my %missing_results;
  for my $dbserver (qw/SYB_OMP1 SYB_OMP2/) {
    $ENV{OMP_DBSERVER} = $dbserver;
    my $db = new OMP::BaseDB( DB => new OMP::DBbackend(1) );
    
    my $ref = $db->_db_retrieve_data_ashash( $sql );

        if ($ref->[0]) {
      map {push @{$results{$dbserver}}, $_->{projectid}} @$ref;
    }
  }

  if (%missing_results) {
    $missing = 1;
    $fault++;
    $msg .= "Missing programs detected!\n";
    for my $dbserver (keys %results) {
      $msg .= "$dbserver:\n";
      map {$msg .= "\t$_\n"} @{$results{$dbserver}};
      $msg .= "\n";
    }
  } else {
    $msg .= "All science programs are present. [OK]\n\n";
  }

  # Compare row counts for disparity
  my %row_count_results;
  for my $dbserver (qw/SYB_OMP1 SYB_OMP2/) {
    $ENV{OMP_DBSERVER} = $dbserver;
    my $db = new OMP::BaseDB( DB => new OMP::DBbackend(1) );
    for my $table (qw/ompfault ompfaultassoc ompfaultbody ompfeedback
		      ompmsb ompmsbdone ompobs ompobslog ompproj
		      ompprojqueue ompprojuser ompshiftlog ompsciprog
		      omptimeacct ompuser ompkey/) {
      my $sql = "SELECT COUNT(*) AS \'count\' FROM $table";

      my $ref = $db->_db_retrieve_data_ashash( $sql );
      $row_count_results{$dbserver}{$table} = $ref->[0]->{count};
    }
  }

  my @row_count_disparity;
  for my $table (keys %{$row_count_results{SYB_OMP1}}) {
    if ($row_count_results{SYB_OMP1}{$table} ne $row_count_results{SYB_OMP2}{$table}) {
      push(@row_count_disparity, $table)
	unless $table eq 'ompkey';
    }
  }

  if ($row_count_disparity[0]) {
    $row_count = 1;
    $fault++;
    $msg .= "Disparity between row counts detected!\n";
    $msg .= "The following tables are affected:\n";
    for my $table (@row_count_disparity) {
      $msg .= "\t$table (SYB_OMP1: ". $row_count_results{SYB_OMP1}{$table}
	." SYB_OMP2: ". $row_count_results{SYB_OMP2}{$table} . ")\n";
    }
    $msg .= "\n";
  } else {
    $msg .= "Row counts are equal across both databases. [OK]\n\n";
  }

  # Make sure MSBs are present if there's a science program
  for my $dbserver (qw/SYB_OMP1 SYB_OMP2/) {
    $ENV{OMP_DBSERVER} = $dbserver;
    my $db = new OMP::BaseDB( DB => new OMP::DBbackend(1) );
    my $sql = "SELECT projectid FROM ompsciprog\n".
      "WHERE projectid NOT IN (SELECT DISTINCT projectid FROM ompmsb)";

    my $ref = $db->_db_retrieve_data_ashash( $sql );

    my @really_missing;
    if ($ref->[0]) {
      for my $row (@$ref) {
	my $projectid = $row->{projectid};
	my $sql = "SELECT projectid FROM ompsciprog\n".
	  "WHERE projectid = '$projectid' AND sciprog NOT LIKE '%<SpObs%'";

	my $really_missing_ref = $db->_db_retrieve_data_ashash( $sql );
	push @really_missing, $projectid
	  unless ($really_missing_ref->[0]);
      }
    }

    if ($really_missing[0]) {
      $missing_msb = 1;
      $fault++;

      $msg .= "Missing MSBs detected on ${dbserver}!\n";
      $msg .= "The following projects are affected:\n";
      for my $projectid (@really_missing) {
	$msg .= "\t$projectid\n";
      }
      $msg .= "\n";
    }
  }
  if (! $missing_msb) {
    $msg .= "MSBs are present for each science program. [OK]\n\n";
  }
}

my $subject = "Replication status: ";

if ($critical) {
  $subject .= "CRITICAL!";
} elsif ($fault > 1) {
  $subject .= "MULTIPLE FAULTS!";
} elsif ($trunc) {
  $subject .= "TRUNCATED PROGRAMS FOUND!";
} elsif ($missing) {
  $subject .= "MISSING PROGRAMS DETECTED!";
} elsif ($row_count) {
  $subject .= "ROW COUNT DISPARITY DETECTED!";
} elsif ($missing_msb) {
  $subject .= "MISSING MSBS DETECTED!";
} else {
  $subject .= "OK";
}

my $email = MIME::Lite->new( From => 'jcmtarch@jach.hawaii.edu',
			     To => 'omp_group@jach.hawaii.edu',
			     Subject => $subject,
			     Data => $msg, );

MIME::Lite->send("smtp", "mailhost", Timeout => 30);

# Send the message
$email->send
  or die "Error sending message: $!\n";