# ------------------------------ MNI Header ----------------------------------
#@NAME       : MNI::Startup
#@DESCRIPTION: Perform common startup/shutdown tasks.
#@EXPORT     : (read the docs for how exports work with this module)
#@EXPORT_OK  : 
#@EXPORT_TAGS: 
#@USES       : Carp, Cwd, MNI::MiscUtilities
#@REQUIRES   : Exporter
#@CREATED    : 1997/07/25, Greg Ward (from old Startup.pm, rev. 1.23)
#@MODIFIED   : 
#@VERSION    : $Id: Startup.pm,v 1.1 1997-08-06 21:45:37 greg Exp $
#@COPYRIGHT  : Copyright (c) 1997 by Gregory P. Ward, McConnell Brain Imaging
#              Centre, Montreal Neurological Institute, McGill University.
#
#              This file is part of the MNI Perl Library.  It is free 
#              software, and may be distributed under the same terms
#              as Perl itself.
#-----------------------------------------------------------------------------

package MNI::Startup;

use strict;
use vars qw(@EXPORT_OK %EXPORT_TAGS);
use vars qw($ProgramDir $ProgramName $StartDirName $StartDir);
use vars qw($Verbose $Execute $Clobber $Debug $TmpDir $KeepTmp @DefaultArgs);
use Carp;
use Cwd;

use MNI::MiscUtilities qw(userstamp timestamp shellquote);

require 5.002;
require Exporter;

%EXPORT_TAGS = 
   (progname => [qw($ProgramDir $ProgramName)],
    startdir => [qw($StartDirName $StartDir)],
    optvars  => [qw($Verbose $Execute $Clobber $Debug $TmpDir $KeepTmp)],
    opttable => [qw(@DefaultArgs)],
    cputimes => [],
    cleanup  => [],
    sig      => [],
    subs     => [qw(self_announce backgroundify)]);

map { push (@EXPORT_OK, @{$EXPORT_TAGS{$_}}) } keys %EXPORT_TAGS;


=head1 NAME

MNI::Startup - perform common startup/shutdown tasks

=head1 SYNOPSIS

   use MNI::Startup;

   use MNI::Startup qw([optvars|nooptvars] 
                       [opttable|noopttable]
                       [progname|noprogname]
                       [startdir|nostartdir]
                       [cputimes|nocputimes]
                       [cleanup|nocleanup]
                       [sig|nosig]);

   self_announce ([$log [, $program [, $args]]]);

   backgroundify ($log [, $program [, $args]]);

=head1 DESCRIPTION

F<MNI::Startup> performs several common tasks that need to be done at
startup and shutdown time for most long-running,
computationally-intensive Perl scripts.  (By "computationally-intensive"
here I mean not that the script itself does lots of number
crunching---rather, it runs other programs to do its work, and acts to
unify a whole sequence of lower-level computational steps.  In other
words, F<MNI::Startup> is for writing glorified shell scripts.)

Each startup/shutdown task is independently controllable by a short
"option string".  The tasks, and the options that control them, are:

=over 4

=item C<progname>

Split C<$0> up into program name and directory.

=item C<startdir>

Get the starting directory and split off the last component (the
"start directory name").

=item C<optvars>

Initialize several useful global variables: C<$Verbose>,
C<$Execute>, C<$Clobber>, C<$Debug>, C<$TmpDir>, and C<$KeepTmp>.

=item C<opttable>

Create an option sub-table that can be incorporated into a larger option
table for use with the F<Getopt::Tabular> module.

=item C<cputimes>

Keep track of elapsed CPU time and print it out at exit time.

=item C<cleanup>

Clean up a temporary directory at exit time.

=item C<sig>

Install a signal handler to cleanup and die whenever we are hit by
certain signals.

=back 

By default, F<MNI::Startup> does everything on this list (i.e., all
options are true).  Options are supplied to the module via its import
list, and can be negated by prepending C<'no'> to them.  For instance,
if you want to disable printing CPU times and signal handling, you
could supply the C<nocputimes> and C<nosig> tokens as follows:

   use MNI::Startup qw(nocputimes nosig);

Note that having a particular option enabled usually implies two things:
a list of variable names that are exported into your namespace at
compile-time, and a little bit of work that F<MNI::Startup> must do at
run-time.  Thus, you don't have the kind of fine control over selecting
what names are exported that you do with most modules.  The exact
details of what work is done and which names are exported are covered in
the sections below.

=cut

# Necessary overhead.  The %options hash dictates what we will do and
# which lists of names will be exported; %option_exports contains
# the actual export sub-lists.

my %options = 
   (progname => 1,
    startdir => 1,
    optvars  => 1,
    opttable => 1,
    cputimes => 1,
    cleanup  => 1,
    sig      => 1,
    subs     => 1);

# @start_times is set when we run the module, and compared to the 
# ending times in &cleanup

my @start_times;

# %signals is used to generate the error message that we print on
# being hit by one of these signals; it also determines what signals
# we will catch

# XXX I have commented some of these out because "perl -w" warns "no
# such signal" about them with Perl 5.004 under IRIX 5.3 -- WHY??!!?
# these are listed with "kill -l", and in <sys/signal.h>

my %signals =
   (HUP  => 'hung-up', 
    INT  => 'interrupted', 
    QUIT => 'quit',
    ILL  => 'illegal instruction',
#   TRAP => 'trace trap',
    ABRT => 'aborted',                  # not in Linux
#   IOT  => 'I/O trap',                 # but this is instead
#   EMT  => 'EMT instruction',
    FPE  => 'floating-point exception',
#   BUS  => 'bus error',
    SEGV => 'segmentation violation',
    SYS  => 'bad argument to system call',
    PIPE => 'broken pipe',
    TERM => 'terminated');


# Here we process the import list.  We walk over the entire list once,
# checking it for validity, setting the appropriate option flags; then
# we walk the list of all options to build the export list, and call
# Exporter's import method to do all the hard work for us.

sub import
{
   my ($classname, @imports) = @_;
   my @exports;

   my ($item, $negated);
   foreach $item (@imports)
   {
      $negated = ($item =~ s/^no//);
      croak "MNI::Startup: unknown option \"$item\""
         unless exists $options{$item};

      $options{$item} = ! $negated;
   }

   my $option;
   foreach $option (keys %options)
   {
      push (@exports, ":$option")
         if ($options{$option});
   }

   local $Exporter::ExportLevel = 1;    # so we export to *our* user, not
                                        # Exporter's!
#   local $Exporter::Verbose = 1;        # for now!
   Exporter::import ('MNI::Startup', @exports);

}  # import



# Now the "let's do some work" bit -- here is where we actually set all
# the global variables that we exported up in `import'.

=head1 PROGRAM NAME AND START DIRECTORY

The first two tasks done at run-time are trivial, but important for
intelligent logging, useful error messages, and safe cleanup later on.
First, F<MNI::Spawn> splits C<$0> up into the "program directory" (up to
and including the last slash) and the "program name" (everything after
the last slash).  These two components are put into C<$ProgramDir> and
C<$ProgramName>, both of which will be exported to your program's
namespace if the C<progname> option is true (which, like with all of
F<MNI::Startup>'s options, is the default).  If there are no slashes in
C<$0>, then C<$ProgramDir> will be empty.

Next, F<MNI::Startup> gets the current directory (using C<Cwd::getcwd>)
and saves it in C<$StartDir>; the last component of this directory is
also extracted and saved in C<$StartDirName> (hey, you never know when
you might want it).

Note that the C<progname> and C<startdir> options only control whether
F<MNI::Spawn> actually exports these four variables into your program's
namespace---they are computed regardless of your wishes, because they are
needed elsewhere in the module and possibly in other modules
(F<MNI::Spawn>, for example, uses C<$main::ProgramName>).  (This could be
conceived as a minor disadvantage because of the expense of finding the
current directory.)

=cut

# We set $ProgramDir and $ProgramName regardless of the options in the
# import list because $ProgramName is needed for the temp dir name and
# various handy messages to the user.  Likewise for $StartDir and
# $StartDirName -- $StartDir is needed by self_announce and to cleanup
# safely (if $TmpDir is a relative path), so we always set it too.  The
# `progname' and `startdir' options only control whether these variables
# are exported into the user's namespace, which is controlled by `import'
# above.

($ProgramDir,$ProgramName) = $0 =~ /(.*\/)?([^\/]*)/;
$ProgramDir = '' unless defined $ProgramDir;

$StartDir = getcwd ();
($StartDirName) = $StartDir =~ /.*\/([^\/]+)/;

=head1 OPTION VARIABLES AND OPTION TABLE

Most long-running, computationally intensive scripts that spend a lot of
time running other programs and read/write lots of (potentially big)
files should be flexible enough for users to control a couple of basic
aspects of their behaviour: the level of verbosity, whether sub-programs
will actually be executed, whether pre-existing files should be
clobbered, where to write temporary files, whether to clean up those
temporary files, and so on.  As it happens, F<MNI::Spawn> provides a
tailored solution to these problems, including global variables to guide
the flow of control of your program and an option sub-table (for use
with F<Getopt::Tabular>) to allow the end user of your program to set
those globals.  These variables are only initialized and exported if the
C<optvars> switch is true, and the option table is only initialized and
exported if the C<opttable> switch is true.


=head2 Option variables

Most of the option variables initialized and exported by F<MNI::Spawn>
are boolean flags.  Thus, each one has both a positive and negative
option in the table meant for use with F<Getopt::Tabular>.  As explained
in the F<Getopt::Tabular> documentation, use of the positive option
means the associated variable will be set to 1, and the negative option
will set it to 0.  The variables, and the command-line options (in
positive/negative form for the boolean options) that can be used to
control them, are:

=over 4

=item C<$Verbose> (C<-verbose>/C<-quiet>) (initialized to: 1)

To be used as you see fit, but keep in mind that it is surreptitiously
used by other modules (F<MNI::Spawn> in particular---see the C<verbose>
option in its documentation).  I use it to control printing out useful
information to the user, echoing all executed command lines, and
controlling the verbosity of sub-programs (these last two with the help
of the F<MNI::Spawn> module).

=item C<$Execute> (C<-execute>/C<-noexecute>) (initialized to: 1)

Again to be used as you see fit, but also used by other modules (see
C<execute> in F<MNI::Spawn>).  I use it to control both the execution of
sub-programs (with F<MNI::Spawn>) and any operations that might affect
the filesystem---e.g. I only create directories or files if C<$Execute>
is true.

=item C<$Clobber> (C<-clobber>/C<-noclobber>) (initialized to: 0)

Use it to decide whether or not to overwrite existing files.  Generally,
my approach is that if C<$Clobber> is true, I will silently overwrite
existing files (which is what Unix tends to do for you anyways); if it
is false, a pre-existing file is either a fatal error or is used instead
of being re-created (depending on the context).  C<$Clobber> should also
be propagated to the command lines of sub-programs that support such an
option using F<MNI::Spawn>'s default arguments feature.

=item C<$Debug> (C<-debug>/C<-nodebug>) (initialized to: 0)

Controls whether you should print debugging information.  The quantity
and nature of this information is entirely up to you; C<$Debug> should
also be propagated to sub-programs that support it.

=item C<$TmpDir> (C<-tmpdir>)

Specifies where to write temporary files; this is initialized to a
unique directory constructed from C<$ProgramName> and the process id
(C<$$>).  This (hopefully) unique name is appended to C<$ENV{'TMPDIR'}>
(or C<'/usr/tmp'> if the TMPDIR environment variable doesn't exist) to
make the complete directory.  If this directory is found already to
exist, the module C<croak>s.  (This shouldn't happen, but it's
conceivably possible.  For instance, some previous run of your program
might not have properly cleaned up after itself, or there might be
another program with the same name and temporary directory naming scheme
that didn't clean up after itself.  Both of these, of course, assume
that the previous run of the ill-behaved progam just happened to have
the same process ID as the current run of your program---hence, the
small chance of this happening.)

Note that the directory is I<not> created, because the user might
override it with the C<-tmpdir> command-line option.  See
C<MNI::FileUtilities::check_output_dirs> for a safe and convenient way
to create output directories such as C<$TmpDir>.

On shutdown, however, F<MNI::Startup> will clean up this temporary
directory by running C<rm -rf> on it.  See L<"CLEANUP"> for details.

=item C<$KeepTmp> (C<-keeptmp>/C<-cleanup>) (initialized to: 0)

Can be used to disable cleaning up temporary files.  This is used by
F<MNI::Startup> on program shutdown to determine whether or not to
cleanup C<$TmpDir>.  You might also use it in your program if you
normally delete some temporary files along the way; if the user puts
C<-keeptmp> on the command line (thus setting C<$KeepTmp> true), you could
respect this by not deleting anything so that all temporary files are
preserved at the end of your program's run.

=back

=head2 Option table

F<Getopt::Tabular> is a module for table-driven command line parsing; to
make the global variables just described easily customizable by the end
user, F<MNI::Startup> provides a snippet of an option table in
C<@DefaultArgs> that you include in your main table for
F<Getopt::Tabular>.  For example:

   use Getopt::Tabular;
   use MNI::Startup qw(optvars opttable);       # redundant, but what the heck
     ...
   my @opt_table = 
     (@DefaultArgs,                             # from MNI::Startup
      # rest of option table
     );

This provides five boolean options (C<-verbose>, C<-execute>, C<-clobber>,
C<-debug>, and C<-keeptmp>) along with one string option (C<-tmpdir>)
corresponding to the six variables described above.

=cut

if ($options{optvars})
{
   $Verbose = 1;
   $Execute = 1;
   $Clobber = 0;
   $Debug = 0;

   my ($basetmp) = (defined ($ENV{'TMPDIR'}) ? $ENV{'TMPDIR'} : '/usr/tmp');
   $TmpDir = ($basetmp . "/${ProgramName}_$$");
   croak "$ProgramName: temporary directory $TmpDir already exists"
      if -e $TmpDir;
   $KeepTmp = 0;
}

if ($options{opttable})
{
   @DefaultArgs =
      (['Basic behaviour options', 'section'],
       ['-verbose|-quiet', 'boolean', 0, \$Verbose, 
	'print status information and command lines of subprograms ' .
	'[default; opposite is -quiet]' ],
       ['-execute', 'boolean', 0, \$Execute, 
	'actually execute planned commands [default]'],
       ['-clobber', 'boolean', 0, \$Clobber,
	'blithely overwrite files (and make subprograms do as well) ' .
	'[default: -noclobber]'],
       ['-debug', 'boolean', 0, \$Debug,
	'spew lots of debugging info (and make subprograms do so as well) ' .
	'[default: -nodebug]'],
       ['-tmpdir', 'string', 1, \$TmpDir,
	'set the temporary working directory'],
       ['-keeptmp|-cleanup', 'boolean', 0, \$KeepTmp,
	'don\'t delete temporary files when finished [default: -nokeeptmp]']);
}

=head1 RUNNING TIME

F<MNI::Spawn> can keep track of the CPU time used by your program and any
child processes, and by the system on behalf of them.  If the C<cputimes>
option is true, it will do just this and print out the CPU times used on
program shutdown---but only if the program is exiting successfully
(i.e. with a zero exit status).

=cut

if ($options{cputimes})
{
   @start_times = times;
}

=head1 SIGNAL HANDLING

Finally, F<MNI::Spawn> can install a signal handler for the most
commonly encountered signals.  This handler simply C<die>s with a
message describing the signal we were hit by, which then triggers the
normal shutdown/cleanup procedure (see L<"CLEANUP"> below). The signals
handled fall into two groups: those you would normally expect to
encounter (HUP, INT, PIPE and TERM), and those that indicate a serious
problem with your script or the Perl interpreter running it (ABRT, BUS,
EMT, FPE, ILL, QUIT, SEGV, SYS and TRAP).  Currently, no distinction is
made between these two groups of signals.

The F<sigtrap> module provided with Perl 5.004 provides a more flexible
approach to signal handling, but doesn't provide a signal handler to
clean up your temporary directory.  If you wish to use F<MNI::Spawn>'s
signal handler with F<sigtrap>'s more flexible interface, just specify
C<\&MNI::Startup::catch_signal> as your signal handler to F<sigtrap>.
Be sure that you also include C<nosig> in F<MNI::Startup>'s import list,
to disable its signal handling.  (The version of F<sigtrap> distributed
with Perl 5.003 and earlier isn't nearly as flexible, so there's not
much point using F<sigtrap> instead of F<MNI::Startup>'s signal handling
if you're not running Perl 5.004 or later.)

To give credit where it is due, the list of signals handled and some of
the language used to describe them were stolen straight from the
F<sigtrap> documentation.

=cut

if ($options{sig})
{
   my $sig;
   foreach $sig (keys %signals)
   {
      $SIG{$sig} = \&catch_signal;
   }
}


=head1 CLEANUP

From the kernel's point-of-view, there are only two ways in which a
process terminates: normally and abnormally.  Programmers generally
further distinguish between two kinds of normal termination, namely
success and failure.  In Perl, success is usually indicated by calling
C<exit 0> or by running off the end of the main program; failure is
indicated by calling C<exit> with a non-zero argument or C<die> outside
of any C<eval> (i.e., an uncaught exception).  Abnormal termination is
what happens when we are hit by a signal, whether it's caused internally
(e.g. a segmentation violation or floating-point exception) or
externally (such as the user hitting Ctrl-C or another process sending
the C<TERM> signal).

In Perl programs that use F<MNI::Startup>, most abnormal terminations will
be turned into normal terminations, because the installed signal handler
simply C<die>s.  Thus, the events that take place for a normal "failure"
shutdown (C<die> or C<exit> with non-zero argument) also take place when we
are killed by a signal.  In particular, if the C<cleanup> option is true,
the C<$KeepTmp> global is false, and C<$TmpDir> names an actual directory,
we execute C<rm -rf> on that directory.  (CPU times are not printed,
because this action is suppressed for failure exits.)

To handle the case where C<$TmpDir> is a relative directory and your
program C<chdir>'s away from its start directory, F<MNI::Startup> will
C<chdir> back to C<$StartDir> before C<rm -rf>'ing C<$TmpDir> in such
circumstances.  If the C<chdir> fails, a warning is printed and the
cleanup is skipped.  Because of this, you should always create your
temporary directory before doing any C<chdir>'ing away from the start
directory.  (Note that C<$TmpDir> can only be relative if you change it,
either through an explicit assignment or by the caller of your program
using the C<-tmpdir> option.  This will happen without any involvement
from F<MNI::Startup>, though, so it has to take the possibility into
account.)


=cut

# Now comes the chain of subroutines by which we clean up the mess made
# by the user's program in its temporary directory ($TmpDir).  There are
# really only two kinds of shutdown to worry about: normal and abnormal.
# Normal exits are triggered by running off the end of main, calling
# exit anywhere, or die anywhere outside of an eval; these are all
# handled by the "END" block -- on shutting down the script, Perl
# executes this END block, which calls cleanup; we then return to Perl's
# shutdown sequence (including possibly any other END blocks).  Abnormal
# exits are triggered by signals; we catch a generous helping of signals
# with &catch_signal, which then calls die.  From here, the END block
# takes over.

sub cleanup
{
   if ($options{cputimes} && $? == 0)   # only print times on successful exit
   {
      my (@stop_times, @elapsed, $i, $user, $system);

      @stop_times = times;
      foreach $i (0 .. 3)
      { 
	 $elapsed[$i] = $stop_times[$i] - $start_times[$i];
      }
      $user = $elapsed[0] + $elapsed[2];
      $system = $elapsed[1] + $elapsed[3];
      print "Elapsed time in ${ProgramName} ($$) and children:\n";
      printf "%g sec (user) + %g sec (system) = %g sec (total)\n", 
	      $user, $system, $user+$system;
   }

   if ($options{cleanup} && !$KeepTmp && defined $TmpDir && -d $TmpDir)
   {
      if ($TmpDir !~ m|^/| && ! chdir $StartDir)
      {
         warn "cleanup: couldn't chdir to \"$StartDir\": $! " .
              "(not cleaning up)\n";
      }
      else
      {
         system 'rm', '-rf', $TmpDir;
         warn "\"rm -rf $TmpDir\" failed\n" if $?;
      }
   }
}

sub catch_signal
{
   die "$ProgramName: $signals{$_[0]}\n";
}

END 
{
#    if ($?)
#    {
#       warn "$ProgramName: exiting with non-zero exit status\n";
#    }
#    else
#    {
#       warn "$ProgramName: exiting normally\n";
#    }
   cleanup;
}


=head1 SUBROUTINES

In addition to the startup/shutdown services described above,
F<MNI::Startup> also provides a couple of subroutines that are handy in
certain applications.  These subroutines will be exported into your
program's namespace if the C<subs> option is true (as always, the
default); if you instead supply C<nosubs> in F<MNI::Startup>'s import
list, they will of course still be available as
C<MNI::Startup::self_announce> and C<MNI::Startup::backgroundify>.

=over 4

=item self_announce ([LOG [, PROGRAM [, ARGS]]])

Prints a brief description of the program's execution environment: user,
host, start directory, date, time, progam name, and program arguments.
LOG, if supplied, should be a filehandle reference (i.e., either a GLOB
ref, an C<IO::Handle> (or descendants) object, or a C<FileHandle>
object); it defaults to C<\*STDOUT>.  PROGRAM should be the program
name; it defaults to C<$0>.  ARGS should be a reference to the program's
list of arguments; it defaults to C<\@ARGV>.  (Thus, to ensure that
C<self_announce> prints an accurate record, you should never fiddle with
C<$0> or C<@ARGV> in your program---the former is made unnecessary by
F<MNI::Startup>'s creation and export of C<$ProgramName>, and the latter
can be avoided without much trouble.  The three-argument form of
C<Getopt::Tabular::GetOptions>, in particular, is designed to help you
avoid clobbering C<@ARGV>.)

This can be enormously useful when trying to recreate the run of a
program by dissecting its log file; for that reason, it is most commonly
called only when C<STDOUT> is not a TTY (i.e. when the program's output
is being logged to a file):

   self_announce () unless -t STDOUT;

=cut

# ------------------------------ MNI Header ----------------------------------
#@NAME       : self_announce
#@INPUT      : $log     - [optional] filehandle to print announcement
#                         to; defaults to \*STDOUT
#              $program - [optional] program name to print instead of $0
#              $args    - [list ref; optional] program arguments to print
#                         instead of @ARGV
#@OUTPUT     : 
#@RETURNS    : 
#@DESCRIPTION: Prints the user, host, time, and full command line (as
#              supplied in @$args).  Useful for later figuring out
#              what happened from a log file.
#@METHOD     : 
#@GLOBALS    : $0, @ARGV
#@CREATED    : 
#@MODIFIED   : 
#-----------------------------------------------------------------------------
sub self_announce
{
   my ($log, $program, $args) = @_;

   $log = \*STDOUT unless defined $log;
   $program = $0 unless defined $program;
   $args = \@ARGV unless defined $args;

   printf $log ("[%s] [%s] running:\n", 
                userstamp (undef, undef, $StartDir), timestamp ());
   print $log "  $program " . shellquote (@$args) . "\n\n";
}


=item backgroundify (LOG [, PROGRAM [, ARGS]])

Redirects C<STDOUT> and C<STDERR> to a log file and detaches to the
background by forking off a child process.  LOG must be either a
filehandle (represented by a glob reference) or a filename; if the
former, it is assumed that the file was opened for writing, and
C<STDOUT> and C<STDERR> are redirected to that file.  If LOG is not a
reference, it is assumed to be a filename to be opened for output.  You
can also supply a filename in the form of the second argument to
C<open>, i.e. with C<'E<gt>'> or C<'E<gt>E<gt>'> already prepended.  If
you just supply a bare filename, C<backgroundify> will either clobber or
append, depending on the value of the C<$Clobber> global.
C<backgroundify> will then redirect C<STDOUT> and C<STDERR> both to this
file.  PROGRAM and ARGS are the same as for C<self_annouce>; in fact,
they are passed to C<self_announce> after redirecting C<STDOUT> and
C<STDERR> so that your program will describe its execution in its own
log file.  (Thus, it's never necessary to call both C<self_announce> and
C<backgroundify> in the same run of a program.)

Note that while both C<backgroundify> and C<self_announce> allow you to
supply LOG as a filehandle, C<backgroundify> isn't as flexible: use of
the C<IO::Handle> or C<FileHandle> classes isn't allowed, because I
couldn't figure out a reliable, consistent way to redirect to those
beasts.  If this stuff becomes better documented in a future version of
Perl, I may change this... but don't hold your breath.

After redirecting, C<backgroundify> unbuffers both C<STDOUT> and
C<STDERR> (so that messages to both streams will be wind up in the same
order as they are output by your program, and also to avoid problems
with unflushed buffers before forking) and C<fork>s.  If the C<fork>
fails, the parent C<die>s; otherwise, the parent C<exit>s and the child
returns 1.

Note that C<backgroundify> is I<not> sufficient for forking off a daemon
process.  This requires a slightly different flavour of wizardry, which
is well outside the scope of this module and this man page.  Anyways,
glorified shell scripts probably shouldn't be made into daemons.

=cut

# ------------------------------ MNI Header ----------------------------------
#@NAME       : backgroundify
#@INPUT      : $log     - either a filename or filehandle
#              $program - [optional] name of program to announce; default $0
#              $args    - [list ref; optional] list of arguments to announce
#                         with $program; defaults to @ARGV
#@OUTPUT     : 
#@RETURNS    : 
#@DESCRIPTION: Redirects STDOUT and STDERR to $log, forks, and (in the 
#              parent) exits.  Returns 1 to newly forked child process 
#              on success; dies on any error.  (No errors are possible
#              after the fork, so only the parent process will die.)
#
#              This is *not* sufficient for writing a daemon.
#@METHOD     : 
#@GLOBALS    : $0, @ARGV, STDOUT, STDERR
#              $Verbose, $Clobber
#@CALLS      : self_announce
#@CREATED    : 1997/07/28, GPW (loosely based on code from old JobControl.pm)
#@MODIFIED   : 
#-----------------------------------------------------------------------------
sub backgroundify
{
   my ($log, $program, $args) = @_;
   my ($stdout, $log_existed);

   # XXX to emulate what happens when a shell puts something in 
   # the BG, should we be be calling setpgrp or something???

   select STDERR; $| = 1;
   select STDOUT; $| = 1;

   # First, figure out what the nature of $log is.  We assume that if it's
   # a reference, it must be a filehandle in some form.  

   if (ref $log eq 'GLOB')              # assume it's a filehandle
   {
      carp "backgroundify: \$log should not be \*STDOUT"
         if $log == \*STDOUT;

      $stdout = ">&$$log";
      print "$ProgramName: redirecting output to $$log " .
            "and detaching to background\n"
         if $Verbose;
   }
   elsif ($log && !ref $log)            # assume it's a filename
   {
      if ($log =~ /^>/)                 # user already supplied clobber 
         { $stdout = $log }             # or append notation
      else                              # else, we have to figure it out
         { $stdout = ($Clobber ? '>' : '>>') . $log }
         
      $log_existed = -e $log;
      print "$ProgramName: redirecting output to $log " .
            "and detaching to background\n"
         if $Verbose;
   }
   else
   {
      croak "backgroundify: \$log must be a filehandle (glob ref) or filename";
   }

   # First save the current destination of stdout and stderr; they will be
   # restored in the parent, in case the `exit' we do there causes any
   # output.  (This can be important, because the user might have END
   # blocks in his program that will -- if he's not careful -- be executed
   # by both the parent and the child.  Restoring stdout and stderr before
   # we `exit' might help this sort of mistake get caught.)

   local (*SAVE_STDOUT, *SAVE_STDERR);
   open (SAVE_STDOUT, ">&STDOUT") || die "couldn't save STDOUT: $!\n";
   open (SAVE_STDERR, ">&STDERR") || die "couldn't save STDERR: $!\n";

   # Now redirect stdout and stderr.  We do this before forking (thus
   # necessitating the save-and-restore code) because redirection is more
   # likely to cause errors than forking, and we want any such error
   # messages to appear on the original stderr (for immediate visibility)
   # rather than in the log file if at all possible.

   unless (open (STDOUT, $stdout))
   {
      die "$ProgramName: detachment to background failed: couldn't redirect stdout to \"$stdout\" ($!)\n";
   }
   unless (open (STDERR, ">&STDOUT"))
   {
      die "$ProgramName: detachment to background failed: couldn't redirect stderr into stdout ($!)\n";
   }

   my $pid = fork;
   die "$ProgramName: detachment to background failed: couldn't fork: $!\n"
      unless defined $pid;

   if ($pid)                            # in the parent (old process)?
   {
      @options{'cputimes','cleanup'} = 0; # disable normal shutdown sequence
      open (STDOUT, ">&SAVE_STDOUT") || die "couldn't restore STDOUT: $!\n";
      open (STDERR, ">&SAVE_STDERR") || die "couldn't restore STDERR: $!\n";
      exit;                             # and exit
   }

   @start_times = times
      if ($options{'cputimes'});

   # Now, we're in the child (new process) -- print "self announcement" to
   # (redirected) stdout, and carry on as usual

   self_announce (\*STDOUT, $program, $args); # this will go to the log file!

   return 1;                            # return OK in new process

}  # backgroundify

=back

=head1 AUTHOR

Greg Ward, <greg@bic.mni.mcgill.ca>.

=head1 COPYRIGHT

Copyright (c) 1997 by Gregory P. Ward, McConnell Brain Imaging Centre,
Montreal Neurological Institute, McGill University.

This file is part of the MNI Perl Library.  It is free software, and may be
distributed under the same terms as Perl itself.

=cut

1;