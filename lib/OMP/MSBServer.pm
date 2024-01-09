package OMP::MSBServer;

=head1 NAME

OMP::MSBServer - OMP MSB Server class

=head1 SYNOPSIS

  $xml = OMP::MSBServer->fetchMSB( $uniqueKey );
  @results = OMP::MSBServer->queryMSB( $xmlQuery, $max );
  OMP::MSBServer->doneMSB( $project, $checksum );

=head1 DESCRIPTION

This class provides the public server interface for the OMP MSB
database server. The interface is specified in document
OMP/SN/003.

This class is intended for use as a stateless server. State is
maintained in external databases. All methods are class methods.

=cut

use strict;
use warnings;
use Carp;
use Encode qw/encode/;

# OMP dependencies
use OMP::User;
use OMP::MSBDB;
use OMP::MSBDoneDB;
use OMP::MSBQuery;
use OMP::Info::MSB;
use OMP::Info::Comment;
use OMP::Constants qw/ :done /;
use OMP::Error qw/ :try /;

use Compress::Zlib;
use Time::HiRes qw/ tv_interval gettimeofday /;

# Different Science program return types
use constant OMP__SCIPROG_XML => 0;
use constant OMP__SCIPROG_OBJ => 1;
use constant OMP__SCIPROG_GZIP => 2;
use constant OMP__SCIPROG_AUTO => 3;

# GZIP threshold in bytes
use constant GZIP_THRESHOLD => 30_000;

# Inherit server specific class
use base qw/OMP::SOAPServer OMP::DBServer/;

our $VERSION = '2.000';

=head1 METHODS

=over 4

=item B<fetchMSB>

Retrieve an MSB from the database and return it in XML format.

  $xml = OMP::MSBServer->fetchMSB( $key );

The key is obtained from a query to the MSB server and is all that
is required to uniquely specify the MSB (the key is the ID string
for <SpMSBSummary> elements).

The MSB is contained in an SpProg element for compatibility with
standard Science Program classes.

Returns nothing is no MSB is found.  Throws I<OMP::Error> exception on
errors.

A second argument controls what form the returned MSB should
take.

  # The gzip output will be base64 encoded.
  $gzip_base64 = OMP::MSBServer->fetchMSB( $key, 'GZIP' );

The following values can be used to specify different return types:
I<GZIP>, I<AUTO>, I<XML> (default).
See also I<_find_return_type> function.

=cut

sub fetchMSB {
  my $class = shift;
  my ( $key , $rettype ) = @_;

  $rettype = _find_return_type( $rettype );

  throw OMP::Error::BadArgs "Return type OMP__SCIPROG_OBJ (object) is not supported yet"
    if $rettype == OMP__SCIPROG_OBJ;

  my $t0 = [gettimeofday];
  OMP::General->log_message( "fetchMSB: Begin.\nKey=$key\n");

  my $msb;
  my $E;
  try {

    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(
                            DB => $class->dbConnection
                           );

    $msb = $db->fetchMSB( msbid => $key );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  return unless defined $msb;

  # Return stringified form of object
  # Note that we have to make these actual Science Programs
  # so that the OM and Java Sp class know what to do.
  my $spprog = $msb->dummy_sciprog_xml();

  my $log = sprintf "fetchMSB: Complete in %d seconds. Project=%s\nChecksum=%s\n",
              tv_interval( $t0 ), $msb->projectID, $msb->checksum ;

  my ( $converted, $zipped ) = _convert_sciprog( encode('UTF-8', $spprog), $rettype, $log );
  return
    $zipped
      ? SOAP::Data->type( 'base64' => $converted )
      : $converted;
}

=item B<fetchCalProgram>

Retrieve the *CAL project science program from the database.

  $xml = OMP::MSBServer->fetchCalProgram( $telescope );

The return argument is an XML representation of the science
program (encoded in base64 for speed over SOAP if we are using
SOAP).

The first argument is the name of the telescope that is
associated with the calibration program to be returned.

A second argument controls what form the returned science program should
take.

  $gzip = OMP::MSBServer->fetchCalProgram( $telescope, "GZIP" );

The following values can be used to specify different return
types:

  "XML"    OMP__SCIPROG_XML   (default)  Plain text XML
  "OBJECT" OMP__SCIPROG_OBJ   Perl OMP::SciProg object
  "GZIP"   OMP__SCIPROG_GZIP  Gzipped XML
  "AUTO"   OMP__SCIPROG_AUTO  plain text or gzip depending on size

These are not exported and are defined in the OMP::SpServer namespace.

Note that for cases XML and GZIP, these will be Base64 encoded if returned
via a SOAP request.

=cut

sub fetchCalProgram {
  my $class = shift;
  my $telescope = shift;
  my $rettype = shift;

  $rettype = _find_return_type( $rettype );

  my $t0 = [gettimeofday];
  OMP::General->log_message( "fetchCalProgram: Begin.\nTelescope=$telescope\nFormat=$rettype\n");

  my $sp;
  my $E;
  try {

    # Create new DB object
    my $db = new OMP::MSBDB(
                             ProjectID => uc($telescope) . 'CAL',
                             DB => $class->dbConnection, );

    # Retrieve the Science Program object
    $sp = $db->fetchSciProg;

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;
  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;


  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  my ( $converted ) =
    _convert_sciprog( $sp, $rettype,
                      "fetchCalProgram: Complete in " . tv_interval($t0) . " seconds\n"
                    );

  return exists $ENV{HTTP_SOAPACTION}
          ? SOAP::Data->type(base64 => $converted)
          : $converted ;
}

=item B<getSciProgInfo>

Retrieve science program information object.

=cut

sub getSciProgInfo {
  my $class = shift;
  my $project = shift;
  my %opt = @_;

  my $db = new OMP::MSBDB(
    ProjectID => $project,
    DB => $class->dbConnection);

  return $db->getSciProgInfo(%opt);
}

=item B<queryMSB>

Send a query to the MSB server (encoded as an XML document) and
retrieve results as an XML document consisting of summaries
for each of the matching MSBs.

  XML document = OMP::MSBServer->queryMSB( $xml, $max );

The query string is described in OMP/SN/003 but looks something like:

  <MSBQuery>
    <tauBand>1</tauBand>
    <seeing>
      <max>2.0</max>
    </seeing>
    <elevation>
      <max>85.0</max>
      <min>45.0</min>
    </elevation>
    <projects>
      <project>M01BU53</project>
      <project>M01BH01</project>
    </projects>
    <instruments>
      <instrument>SCUBA</instrument>
    </instruments>
  </MSBQuery>

The second argument indicates the maximum number of results summaries
to return. If this value is negative all results are returned and if it
is zero then the default number are returned (usually 100).

The format of the resulting document is:

  <?xml version="1.0" encoding="UTF-8"?>
  <QueryResult>
   <SpMSBSummary id="unique">
     <something>XXX</something>
     ...
   </SpMSBSummary>
   <SpMSBSummary id="unique">
     <something>XXX</something>
     ...
   </SpMSBSummary>
   ...
  </QueryResult>

The elements inside C<SpMSBSummary> may or may not relate to
tables in the database.

Throws an exception on error.

=cut

sub queryMSB {
  my $class = shift;
  my $xmlquery = shift;
  my $maxCount = shift;

  my $t0 = [gettimeofday];
  my $m = ( defined $maxCount ? $maxCount : '[undefined]' );
  OMP::General->log_message("queryMSB:\n$xmlquery\nMaxcount=$m\n");

  my @results;
  my $E;
  try {
    # Convert the Query to an object
    # Triggers an exception on fatal errors
    my $query = new OMP::MSBQuery( XML => $xmlquery,
                                   MaxCount => $maxCount,
                                 );

    # Not really needed if exceptions work
    return '' unless defined $query;

    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(
                            DB => $class->dbConnection
                           );

    # Do the query
    @results = $db->queryMSB( $query );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  # Convert results to an XML document
  my $result;

  try {
    my $tag = "QueryResult";
    my $xmlhead = '<?xml version="1.0" encoding="UTF-8"?>';
    $result = "$xmlhead\n<$tag>\n". join("\n",@results). "\n</$tag>\n";

    OMP::General->log_message("queryMSB: Complete. Retrieved ".@results." MSBs in ".
                              tv_interval($t0)." seconds\n");
  } catch OMP::Error with {
    $E = shift;
  } otherwise {
    $E = shift;
  };
  $class->throwException( $E ) if defined $E;

  $result = SOAP::Data->type(base64 => encode('UTF-8', $result)) if exists $ENV{'HTTP_SOAPACTION'};

  return $result;
}

=item B<doneMSB>

Mark the specified MSB (identified by project ID and MSB checksum)
as having been observed.

This will have the effect of decrementing the overall observing
counter for that MSB. If the MSB happens to be part of some OR logic
it is possible that the Science program will be reorganized.

  OMP::MSBServer->doneMSB( $project, $checksum );

Nothing happens if the MSB can no longer be located since this
simply indicates that the science program has been reorganized
or the MSB modified.

Optionally, a userid and/or reason for the marking as complete
can be supplied:

  OMP::MSBServer->doneMSB( $project, $checksum, $userid, $reason );

A transaction ID can also be specified

  OMP::MSBServer->doneMSB( $project, $checksum, $userid, $reason, $msbtid );

The transaction ID is a string that should be unique for a particular
instance of an MSB. Userid and reason must be specified (undef is okay)
if a transaction ID is supplied.

A shift type can also be specified
  OMP::MSBServer->doneMSB( $project, $checksum, $userid, $reason, $msbtid,
    $shifttype );

This is a standard shift name.

An MSB title can also be specified
  OMP::MSBServer->doneMSB( $project, $checksum, $userid, $reason, $msbtid, $shifttype,
    $msbtitle );
=cut

sub doneMSB {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;
  my $userid = shift;
  my $reason = shift;
  my $msbtid = shift;
  my $shift_type = shift;
  my $msbtitle = shift;

  my $reastr = (defined $reason ? $reason : "<None supplied>");
  my $ustr = (defined $userid ? $userid : "<No User>");
  my $tidstr = (defined $msbtid ? $msbtid : '<No MSBTID>');

  my $t0 = [gettimeofday];
  OMP::General->log_message("doneMSB: Begin.\nProject=$project\nChecksum=$checksum\nUser=$ustr\nReason=$reastr\nMSBTID=$tidstr\n");

  my $E;
  try {

    # Create a comment object for doneMSB
    # We are allowed to specify a user regardless of whether there
    # is a reason
    my $user;
    if ($userid) {
      $user = new OMP::User( userid => $userid );
      if (!$user->verify) {
        throw OMP::Error::InvalidUser("The userid [$userid] is not a valid OMP user ID. Please supply a valid id.");
      }
    }


    # We must have a valid user if there is an explicit reason
    if ($reason && ! defined $user) {
      throw OMP::Error::BadArgs( "A user ID must be supplied if a reason for the rejection is given");
    }

    # Form the comment object
    my $comment = new OMP::Info::Comment( status => OMP__DONE_DONE,
                                          text => $reason,
                                          author => $user,
                                          tid => $msbtid,
                                        );

    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(ProjectID => $project,
                            DB => $class->dbConnection
                           );


    # If the shift type and/or msbtitle was defined, create an option hash.
    my %optargs;
    if (defined $shift_type) {
        $optargs{'shifttype'} = $shift_type;
    }
    if (defined $msbtitle) {
        $optargs{'msbtitle'} = $msbtitle;
    }

    # We want to set the option 'notify_first_accept=1' to the
    # MSBDB::doneMSB option hash; we will actually check in
    # MSBDB::MSBDone to only send that notification if the telescope
    # is JCMT. this is to avoid having to look up the telescope here.
    $optargs{'notify_first_accept'} = 1;

    $db->doneMSB( $checksum, $comment, \%optargs);

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  OMP::General->log_message("doneMSB: $project Complete. ".tv_interval($t0)." seconds\n");
}

=item B<undoMSB>

Mark the specified MSB (identified by project ID and MSB checksum)
as not having been observed.

This will have the effect of incrementing by one the overall observing
counter for that MSB. This method can not reverse OR logic
reorganization triggered by an earlier C<doneMSB> call.

  OMP::MSBServer->undoMSB( $project, $checksum, $msbtid );

Nothing happens if the MSB can no longer be located since this
simply indicates that the science program has been reorganized
or the MSB modified.

=cut

sub undoMSB {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;
  my $msbtid = shift;

  OMP::General->log_message("undoMSB: $project $checksum MSBTID=$msbtid\n");

  my $E;
  try {
    # Prepare comment object.
    my $comment = new OMP::Info::Comment(
      text => "MSB done status reversed.",
      status => OMP__DONE_UNDONE,
      tid => $msbtid,
    );

    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(ProjectID => $project,
                            DB => $class->dbConnection);

    $db->undoMSB( $checksum, $comment );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;
}

=item B<unremoveMSB>

Unmark the specified MSB as having been removed.

  OMP::MSBServer->unremoveMSB( $project, $checksum );

Nothing happens if the MSB can no longer be located since this
simply indicates that the science program has been reorganized
or the MSB modified.

=cut

sub unremoveMSB {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;

  OMP::General->log_message("unremoveMSB: $project $checksum\n");

  my $E;
  try {
    # Prepare comment object.
    my $comment = new OMP::Info::Comment(
      text => "MSB removed status reversed.",
      status => OMP__DONE_UNREMOVED,
    );

    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(ProjectID => $project,
                            DB => $class->dbConnection);

    $db->undoMSB( $checksum, $comment );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;
}

=item B<suspendMSB>

Cause the MSB to go into a "suspended" state such that the next
time it is translated only some of the files will be sent to
the sequencer.

The "suspended" flag is cleared only when an MSB is marked
as "done".

  OMP::MSBServer->suspendMSB( $project, $checksum, $label );

The label must match the observation labels generated by the
C<unroll_obs> method in C<OMP::MSB>. This label is used by the
translator to determine which observation to start at.

Nothing happens if the MSB can no longer be located since this
simply indicates that the science program has been reorganized
or the MSB modified.

Optionally, a user ID and reason for the suspension can be supplied
(similar to the C<doneMSB> method).

  OMP::MSBServer->suspendMSB( $project, $checksum, $label, $userid,
                              $reason, $msbtid);

Reason is optional. User id is mandatory if a reason is supplied.
MSB transaction ID requires that reason and userid are specified (or are
at least set explicitly to undef).

=cut

sub suspendMSB {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;
  my $label = shift;
  my $userid = shift;
  my $reason = shift;
  my $msbtid = shift;

  my $reastr = (defined $reason ? $reason : "<None supplied>");
  my $ustr = (defined $userid ? $userid : "<No User>");
  my $tidstr = (defined $msbtid ? $msbtid : '<No MSBTID>');
  OMP::General->log_message("suspendMSB: $project $checksum $label\n".
                           "User: $ustr Reason: $reastr\nTransaction ID: $msbtid\n");

  my $E;
  try {

    # Create a comment object for suspendMSB
    # We are allowed to specify a user regardless of whether there
    # is a reason
    my $user;
    if ($userid) {
      $user = new OMP::User( userid => $userid );
      if (!$user->verify) {
        throw OMP::Error::InvalidUser("The userid [$userid] is not a valid OMP user ID. Please supply a valid id.");
      }
    }


    # We must have a valid user if there is an explicit reason
    if ($reason && ! defined $user) {
      throw OMP::Error::BadArgs( "A user ID must be supplied if a reason for the rejection is given");
    }

    # Form the comment object
    my $comment = new OMP::Info::Comment( status => OMP__DONE_DONE,
                                          text => $reason,
                                          author => $user,
                                          tid => $msbtid,
                                        );


    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(ProjectID => $project,
                            DB => $class->dbConnection
                           );

    $db->suspendMSB( $checksum, $label, $comment );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;


}

=item B<alldoneMSB>

Mark the specified MSB (identified by project ID and MSB checksum) as
being completely done. This simply involves setting the remaining
counter for the MSB to zero regardless of how many were thought to be
remaining. This is useful for removing an MSB when the required noise
limit has been reached but the PI of the project is not available to
update their science program. The MSB is still present in the science
program.

If the MSB happens to be part of some OR logic
it is possible that the Science program will be reorganized.

  OMP::MSBServer->alldoneMSB( $project, $checksum );

Nothing happens if the MSB can no longer be located since this
simply indicates that the science program has been reorganized
or the MSB modified.

=cut

sub alldoneMSB {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;

  OMP::General->log_message("alldoneMSB: $project $checksum\n");

  my $E;
  try {
    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(ProjectID => $project,
                            DB => $class->dbConnection
                           );

    $db->alldoneMSB( $checksum );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;


}

=item B<rejectMSB>

Indicate that the MSB has been partially observed but has been
rejected by the observer rather than being marked as complete
using C<doneMSB>.

  OMP::MSBServer->rejectMSB( $project, $checksum, $userid, $reason, $msbtid );

This method simply places an entry in the MSB history - it is a
wrapper around addMSBComment method. The optional reason string can be
used to specify a particular reason for the rejection. The userid
is optional unless a reason is supplied (in which case it must be defined
and must match a valid user ID). The MSB transaction ID can be specified.

=cut

sub rejectMSB {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;
  my $userid = shift;
  my $reason = shift;
  my $msbtid = shift;

  my $reastr = (defined $reason ? $reason : "<None supplied>");
  my $ustr = (defined $userid ? $userid : "<No User>");
  my $tidstr = (defined $msbtid ? $msbtid : '<No MSBTID>');
  OMP::General->log_message("rejectMSB: $project $checksum User: $ustr Reason: $reastr MSBtid=$msbtid");

  my $E;
  try {

    # We are allowed to specify a user regardless of whether there
    # is a reason
    my $user;
    if ($userid) {
      $user = new OMP::User( userid => $userid );
      if (!$user->verify) {
        throw OMP::Error::InvalidUser("The userid [$userid] is not a valid OMP user ID. Please supply a valid id.");
      }
    }

    # We must have a valid user if there is an explicit reason
    if ($reason && ! defined $user) {
      throw OMP::Error::BadArgs( "A user ID must be supplied if a reason for the rejection is given");
    }

    # Default comment
    $reason = "This MSB was observed but was not accepted by the observer/TSS. No reason was given."
      unless defined $reason;

    # Add prefix
    $reason = "MSB rejected: $reason";

    # Form the comment object
    my $comment = new OMP::Info::Comment( status => OMP__DONE_REJECTED,
                                          text => $reason,
                                          author => $user,
                                          tid => $msbtid,
                                        );

    # Add the comment
    OMP::MSBServer->addMSBcomment($project, $checksum, $comment);

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  return;
}

=item B<historyMSB>

Retrieve the observation history for the specified MSB (identified
by checksum and project ID).

  $xml = OMP::MSBServer->historyMSB( $project, $checksum, 'xml');
  $info = OMP::MSBServer->historyMSB( $project, $checksum, 'data');
  $arrref  = OMP::MSBServer->historyMSB( $project, '', 'data');

If the checksum is not supplied a full project observation history
is returned. Note that the information retrieved consists of:

 - Target name, waveband and instruments
 - Date of observation or comment
 - Comment associated with action

Only "data" and "xml" are understood as valid types.  If "data" is
specified the results are retrieved as either a single
C<OMP::Info::MSB> object or a reference to an array of
C<OMP::Info::MSB> objects. If XML is requested (the default) an XML
string is returned with a wrapper element of SpMSBSummaries and
content matching that generated from C<OMP::Info::MSB> objects.

   <SpMSBSummaries>
     <SpMSBSummary>
       ...
     </SpMSBSummary>
     <SpMSBSummary>
       ...
     </SpMSBSummary>
   </SpMSBSummaries>

Since checksums are unique, a project ID is not required (but must be
specified as undef explicitly) if a checksum is provided.

=cut

sub historyMSB {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;
  my $type = lc(shift);
  $type ||= 'xml';

  OMP::General->log_message("historyMSB: project:".(defined $project ? $project : "none").", checksum:" .
                            (defined $checksum ? $checksum : "none") ."\n");

  my $E;
  my $result;
  try {
    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDoneDB(ProjectID => $project,
                                DB => $class->dbConnection
                               );

    $result = $db->historyMSB( $checksum );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  if ($type eq 'xml') {
    # Generate the XML
    my $xml = "<SpMSBSummaries>\n";
    my @msbs = ( ref($result) eq 'ARRAY' ? @$result : $result );
    for my $msb (@msbs) {
      $xml .= $msb->summary('xml') . "\n";
    }
    $xml .= "</SpMSBSummaries>\n";
    $result = $xml;
  }

  return $result;
}

=item B<historyMSBtid>

Retrieve information associated with a specific MSB transaction.

  $info = OMP::MSBServer->historyMSBtid( $msbtid );

Only a single item should be returned containing all activity
associated with this transaction. Returns a single C<OMP::Info::MSB>
object. This method is not compatible with SOAP.

=cut

sub historyMSBtid {
  my $class = shift;
  my $msbtid = shift;

  OMP::General->log_message("historyMSBtid: msbtid: $msbtid");

  my $E;
  my $result;
  try {
    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDoneDB(DB => $class->dbConnection);

    $result = $db->historyMSBtid( $msbtid );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  return $result;
}

=item B<titleMSB>

Simple routine for obtaining the title of an MSB given a checksum.

 $title = OMP::MSBServer->titleMSB( $checksum );

Use historyMSB for more details on the MSB if it has previously been
observed.

Queries both the MSB history table and the to be observed MSB
table.

=cut

sub titleMSB {
  my $class = shift;
  my $checksum = shift;

  my $E;
  my $result;
  try {
    throw OMP::Error::BadArgs( "No checksum specified for titleMSB" )
      if !$checksum;

    my $connection = $class->dbConnection;

    # first try the Done table
    my $donedb = new OMP::MSBDoneDB( DB => $connection );
    $result = $donedb->titleMSB( $checksum );

    # Now MSBDB
    if (!$result) {
      my $msbdb = new OMP::MSBDB( DB => $connection );
      $result = $msbdb->getMSBtitle( $checksum );
    }

  } catch OMP::Error with {
    $E = shift;
  } otherwise {
    $E = shift;
  };

  # rethrow if a problem
  $class->throwException( $E ) if defined $E;

  return $result;
}

=item B<observedMSBs>

Return all the MSBs observed (ie "marked as done" or MSBs started) on
the specified date and/or for the specified project.

  $output = OMP::MSBServer->observedMSBs( { date => $date,
                                            comments => 1,
                                            transactions => 1,
                                            format => 'xml',
                                            projectid => $proj,
                                          } );

I<returnall> parameter has been I<deprecated> in favor of I<comments>.

The C<comments> parameter governs whether all the comments
associated with the observed MSBs are returned (regardless of when
they were added) or only those added for the specified night. If the
value is false only the comments for the night are returned.

The output format matches that returned by C<historyMSB>.

Similarly for C<transactions>, all the comments related to a
transaction id will be returned if true.

If the current date is required use the "usenow" flag:

  $output = OMP::MSBServer->observedMSBs( { usenow => 1,
                                            comments => 1,
                                            format => 'xml',
                                          } );

At least one of "usenow", "projectid" or "date" must be defined
else the query is too open-ended (and would result in every MSB
ever observed).

Note that the argument is a reference to a hash.

=cut

sub observedMSBs {
  my $class = shift;
  my $args = shift;

  # Support old key until its usage is brought upto date.
  for ( 'returnall') {

    exists $args->{ $_ } and
      $args->{'comments'} = delete $args->{ $_ };
  }

  my $type = lc( $args->{format} );
  $type ||= 'xml';
  delete $args->{format};

  # Check basic consistency of arguments
  if (!exists $args->{usenow} && !exists $args->{date} &&
     !exists $args->{projectid}) {
    throw OMP::Error::BadArgs("observedMSBs: Please supply one of usenow, date or projectid");
  }

  # Log message
  my $string;
  my $dstr = (exists $args->{date} ? $args->{date} : "<undef>");
  my $pstr = (exists $args->{projectid} ? $args->{projectid} : "<undef>");
  my $ustr = (exists $args->{usenow} ? $args->{usenow} : "<undef>");

  my $t0 = [gettimeofday];
  OMP::General->log_message("observedMSBs: Begin.\nDate=$dstr\nProject=$pstr\nUseNow=$ustr\n");

  my $E;
  my $result;
  try {

    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDoneDB(
                                DB => $class->dbConnection
                               );

    # Do we have a project?
    $db->projectid( $args->{projectid} )
      if exists $args->{projectid} && defined $args->{projectid};
    delete $args->{projectid};

    $result = $db->observedMSBs( %$args );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  my @msbs;
  if ($type eq 'xml') {
    # Generate the XML
    my $xml = "<SpMSBSummaries>\n";
    @msbs = ( ref($result) eq 'ARRAY' ? @$result : $result );
    for my $msb (@msbs) {
      $xml .= $msb->summary('xml') . "\n";
    }
    $xml .= "</SpMSBSummaries>\n";
    $result = $xml;
  }

  OMP::General->log_message("observedMSBs: Complete. Retrieved ". @msbs ." MSBS in ".tv_interval($t0)." seconds\n");

  return $result;
}

=item B<observedDates>

Return an array (as reference) of all dates (in YYYYMMDD format) on
which data for the specified project has been taken.

  $ref = OMP::MSBServer->observedDates( $projectid );

A project ID must be supplied. An optional boolean second argument can
be used to specify that the dates should be returned as C<Time::Piece>
objects (usually only relevant outside of a SOAP environment)

  $ref = OMP::MSBServer->observedDates( $projectid, 1 );

=cut

sub observedDates {
  my $class = shift;
  my $projectid = shift;
  my $useobj = shift;

  my $E;
  my @result;
  try {
    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDoneDB(
                                ProjectID => $projectid,
                                DB => $class->dbConnection
                               );

    @result = $db->observedDates($useobj);

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;


  return \@result;
}

=item B<queryMSBdone>

Return all the MSBs that match the specified XML query

  $output = OMP::MSBServer->queryMSBdone( $xml,
                                          { 'comments' => $allcomments }
                                          , 'xml'
                                        );

The truth value for C<comments> governs whether all the comments
associated with the matching MSBs are returned (regardless of when
they were added) or only those added for the specific query. If the
value is false only the comments for the query are returned.

Similarly for C<transactions>, all the comments related to a
transaction id will be returned if true.

The output format matches that returned by C<historyMSB>.

The XML query must match that described in C<OMP::MSBDoneQuery>.

=cut

sub queryMSBdone {
  my $class = shift;
  my $xml = shift;
  my $more = shift;
  my $type = lc(shift);
  $type ||= 'xml';

  OMP::General->log_message("queryMSBdone: xml $xml\n");

  my $E;
  my $result;
  try {
    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDoneDB(
                                DB => $class->dbConnection
                               );

    my $q = new OMP::MSBDoneQuery( XML => $xml );

    $result = $db->queryMSBdone( $q, $more );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  if ($type eq 'xml') {
    # Generate the XML
    my $xml = "<SpMSBSummaries>\n";
    my @msbs = ( ref($result) eq 'ARRAY' ? @$result : $result );
    for my $msb (@msbs) {
      $xml .= $msb->summary('xml') . "\n";
    }
    $xml .= "</SpMSBSummaries>\n";
    $result = $xml;
  }


  return $result;
}

=item B<addMSBcomment>

Associate a comment with a previously observed MSB.

  OMP::MSBServer->addMSBcomment( $project, $checksum, $comment );

=cut

sub addMSBcomment {
  my $class = shift;
  my $project = shift;
  my $checksum = shift;
  my $comment = shift;

  # Store the comment text for the log message
  my $text;
  if (UNIVERSAL::isa($comment, "OMP::Info::Comment")) {
    $text = $comment->text;
  } else {
    $text = $comment;
  }

  OMP::General->log_message("addMSBComment: $project $checksum $text\n");

  my $E;
  my $result;
  try {
    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDoneDB(ProjectID => $project,
                                DB => $class->dbConnection
                               );

    $result = $db->addMSBcomment( $checksum, $comment );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

}

=item B<getMSBCount>

Return the total number of MSBs, and the total number of active MSBs, for a
given list of projects.

  \%msbcount = OMP::MSBServer->getMSBCount(@projectids);

The only argument is a list (or reference to a list) of project IDs.
Returns a hash of hashes indexed by project ID where the second-level
hashes contain the keys 'total' and 'active' (each points to a number).
If a project has no MSBs, not key is included for that project.  If
a project has no MSBs with remaining observations, no 'active' key
is returned for that project.

=cut

sub getMSBCount {
  my $class = shift;
  my @projectids = (ref($_[0]) eq 'ARRAY' ? @{$_[0]} : @_);

  my $E;
  my $result;
  try {
    # Create a new object but we dont know any setup values
    my $db = new OMP::MSBDB(
                            DB => $class->dbConnection
                           );

    $result = $db->getMSBCount(@projectids);

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  return $result;
}

=item B<getResultColumns>

Retrieve the column names that will be used for the XML query
results. Requires a telescope name be provided as single argument.

  $colnames = OMP::MSBServer->getResultColumns( $tel );

Returns an array (as a reference).

=cut

sub getResultColumns {
  my $class = shift;
  my $tel = shift;

  my $E;
  my @result;
  try {
    # Create a new object but we dont know any setup values
    @result = OMP::Info::MSB->getResultColumns( $tel );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  return \@result;

}

=item B<getTypeColumns>

Retrieve the data types associated with the column names that will be
used for the XML query results (as returned by
getResultColumns). Requires a telescope name be provided as single
argument.

  $coltypes = OMP::MSBServer->getTypeColumns( $tel );

Returns an array (as a reference).

=cut

sub getTypeColumns {
  my $class = shift;
  my $tel = shift;

  my $E;
  my @result;
  try {
    # Create a new object but we dont know any setup values
    @result = OMP::Info::MSB->getTypeColumns( $tel );

  } catch OMP::Error with {
    # Just catch OMP::Error exceptions
    # Server infrastructure should catch everything else
    $E = shift;

  } otherwise {
    # This is "normal" errors. At the moment treat them like any other
    $E = shift;

  };
  # This has to be outside the catch block else we get
  # a problem where we cant use die (it becomes throw)
  $class->throwException( $E ) if defined $E;

  return \@result;

}

=item B<testServer>

Test the server is actually handling requests.

Run with no arguments. Returns 1 if working.

=cut

sub testServer {
  my $class = shift;
  return 1;
}

=item B<_convert_sciprog>

Returns a list of converted string and compression indicating flag,
given a string, return type, and optional message of non zero length
to log.

  # Compress if needed, save converted string & compression flag.
  ( $converted, $compressed ) =
    _convert_sciprog( $var, OMP__SCIPROG_AUTO );

  # Compress, log message, save only converted string.
  ( $converted ) = _convert_sciprog( $var, OMP__SCIPROG_GZIP, "log this" );


If the string cannot be compressed, L<OMP::Error::FatalError>
exception is thrown.  Behaviour based on a return type (see
I<_find_return_type> function for details):

=over 4

=item *

If type is I<OMP__SCIPROG_OBJ>, value of C<$var> is returned as is.

=item *

If type is I<OMP__SCIPROG_AUTO>, return value of C<$var> will be
compressed only if its length exceeds L<GZIP_THRESHOLD>.

=item *

If type is I<OMP__SCIPROG_GZIP>, compressed value of C<$var> is
returned.

=item *

For all other types, stringyfied value of C<$var> is returned.

=back

=cut

sub _convert_sciprog {

  my ( $in, $type, $log ) = @_;

  return ( $in )
    if $type == OMP__SCIPROG_OBJ;

  # Return the stringified form, compressed if asked or needed.
  my ( $string, $zipped ) = ( "$in" );

  if ( $type == OMP__SCIPROG_GZIP
        || ( $type == OMP__SCIPROG_AUTO
              && length $string > GZIP_THRESHOLD
            )
      ) {

    $string = Compress::Zlib::memGzip( $string )
      or throw OMP::Error::FatalError "Unable to gzip compress science program";

    $zipped++;
  }

  OMP::General->log_message( $log )
    if defined $log && length $log;

  return ( $string, $zipped );
}

=item B<_find_return_type>

Returns one of OMP__SCIPROG* value given a text description
irrespective of case.

  $type = _find_return_type( 'auto' );

Valid types are:

  "XML"    OMP__SCIPROG_XML   Plain text XML
  "OBJECT" OMP__SCIPROG_OBJ   Perl OMP::SciProg object
  "GZIP"   OMP__SCIPROG_GZIP  Gzipped XML
  "AUTO"   OMP__SCIPROG_AUTO  plain text or gzip depending on size

C<AUTO> type implies compression when length of the output of other
methods (I<fetchCalProgram> and I<fetchMSB> for example) exceeds
I<GZIP_THRESHOLD> which is currently 30,000.

These are not exported and are defined in the I<OMP::SpServer> namespace.

=cut

sub _find_return_type {

  my ( $rettype ) = @_;

  $rettype = OMP__SCIPROG_XML unless defined $rettype;
  $rettype = uc($rettype);

  # Translate input strings to constants
  if ($rettype !~ /^\d$/a) {
    $rettype = OMP__SCIPROG_XML  if $rettype eq 'XML';
    $rettype = OMP__SCIPROG_OBJ  if $rettype eq 'OBJECT';
    $rettype = OMP__SCIPROG_GZIP if $rettype eq 'GZIP';
    $rettype = OMP__SCIPROG_AUTO if $rettype eq 'AUTO';
  }

  return $rettype;
}


=back

=head1 SEE ALSO

OMP document OMP/SN/003.

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


=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=cut

1;
