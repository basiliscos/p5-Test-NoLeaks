package Test::NoLeaks;

use strict;
use warnings;
use POSIX qw/sysconf _SC_PAGESIZE/;
use Test::Builder;
use Test::More;

our $VERSION = '0.02';

use base qw(Exporter);

our @EXPORT = qw/test_noleaks/;
our @EXPORT_OK = qw/noleaks/;


=head1 NAME

Test::NoLeaks - Memory and file descriptor leak detector

=head1 VERSION

0.02

=head1 SYNOPSYS

  use Test::NoLeaks;

  test_noleaks (
      code          => sub{
        # code that might leak
      },
      track_memory  => 1,
      track_fds     => 1,
      passes        => 2,
      warmup_passes => 1,
      tolerate_hits => 0,
  );

  test_noleaks (
      code          => sub { ... },
      track_memory  => 1,
      passes        => 2,
  );

  # old-school way
  use Test::More;
  use Test::NoLeaks qw/noleaks/;
  ok noleaks(
      code          => sub { ... },
      track_memory  => ...,
      track_fds     => ...,
      passes        => ...,
      warmup_passes => ...,
    ), "non-leaked code description";

=head1 DESCRIPTION

It is hard to track memory leaks. There are a lot of perl modules (e.g.
L<Test::LeakTrace>), that try to B<detect> and B<point> leaks. Unfortunately,
they do not always work, and they are rather limited because they are not
able to detect leaks in XS-code or external libraries.

Instead of examining perl internals, this module offers a bit naive empirical
approach: let the suspicious code to be launched in infinite loop
some time and watch (via tools like C<top>)if the memory consumption by
perl process increses over time. If it does, while it is expected to
be constant (stabilized), then, surely, there are leaks.

This approach is able only to B<detect> and not able to B<point> them. The
module C<Test::NoLeaks> implements the general idea of the approach, which
might be enough in many cases.

=head1 INTERFACE

=head3 C<< test_noleaks >>

=head3 C<< noleaks >>

The mandatory hash has the following members

=over 2

=item * C<code>

Suspicious for leaks subroutine, that will be executed multiple times.

=item * C<track_memory>

=item * C<track_fds>

Track memory or file descriptor leaks. At leas one of them should be
specified.

In B<Unices>, every socket is file descriptor too, so, C<track_fds>
will be able to track unclosed sockets, i.e. network connections.

=item * C<passes>

How many times C<code> should be executed. If memory leak is too small,
number of passes should be large enough to trigger additional pages
allocation for perl process, and the leak will be detected.

Page size is 4kb on linux, so, if C<code> leaks 4 bytes on every
pass, then C<1024> passes should be specified.

In general, the more passes are specified, the more chance to
detect possible leaks.

Default value is C<100>. Minimal value is C<2>.

=item * C<warmup_passes>

How many times the C<code> should be executed before module starts
tracking resources consumption on executing the C<code> C<passes>
times.

If you have caches, memoizes etc., then C<warmup_passes> is your
friend.

Default value is C<0>.

=item * C<tolerate_hits>

How many passes, which considered leaked, should be ingnored, i.e.
maximal number of possible false leak reports.

Even if your code has no leaks, it might cause perl interpreter
allocate additional memory pages, e.g. due to memory fragmentation.
Those allocations are legal, and should not be treated as leaks.

Default value is C<0>.

=back

=cut

my $PAGE_SIZE;

BEGIN {
    no strict "subs";

    $PAGE_SIZE = sysconf(_SC_PAGESIZE)
      or die("page size cannot be determined, Test::NoLeaks cannot be used");

    open(my $statm, '<', '/proc/self/statm')
        or die("couldn't access /proc/self/status : $!");
    *_platform_mem_size = sub {
        my $line = <$statm>;
        seek($statm, 0, 0);
        my ($pages) = (split / /, $line)[0];
        return $pages * $PAGE_SIZE;
    };

    my $fd_dir = '/proc/self/fd';
    opendir(my $dh, $fd_dir)
      or die "can't opendir $fd_dir: $!";
    *_platform_fds = sub {
        my $open_fd_count = () = readdir($dh);
        rewinddir($dh);
        return $open_fd_count;
    };
}

sub _noleaks {
    my %args = @_;

    # check arguments
    my $code = $args{code};
    die("code argument (CODEREF) isn't provided")
        if (!$code || !(ref($code) eq 'CODE'));

    my $track_memory = $args{'track_memory'};
    my $track_fds    = $args{'track_fds'};
    die("don't know what to track (i.e. no 'track_memory' nor 'track_fds' are specified)")
        if (!$track_memory && !$track_fds);

    my $passes = $args{passes} || 100;
    die("passes count too small (should be at least 2)")
        if $passes < 2;

    my $warmup_passes = $args{warmup_passes} || 0;
    die("warmup_passes count too small (should be non-negative)")
        if $passes < 0;

    # warm-up phase
    # a) warm up code
    $code->() for (1 .. $warmup_passes);

    # b) warm-up package itself, as it might cause additional memory (re) allocations
    # (ignore results)
    _platform_mem_size if $track_memory;
    _platform_fds if $track_fds;
    my @leaked_at = map { [0, 0] } (1 .. $passes); # index: pass, value array[$mem_leak, $fds_leak]

    # pre-allocate all variables, including those, which are used in cycle only
    my ($total_mem_leak, $total_fds_leak, $memory_hits) = (0, 0, 0);
    my ($mem_t0, $fds_t0, $mem_t1, $fds_t1) = (0, 0, 0, 0);

    # execution phase
    for my $pass (0 .. $passes - 1) {
        $mem_t0 = _platform_mem_size if $track_memory;
        $fds_t0 = _platform_fds if $track_fds;
        $code->();
        $mem_t1 = _platform_mem_size if $track_memory;
        $fds_t1 = _platform_fds if $track_fds;

        my $leaked_mem = $mem_t1 - $mem_t0;
        $leaked_mem = 0 if ($leaked_mem < 0);

        my $leaked_fds = $fds_t1 - $fds_t0;
        $leaked_fds = 0 if ($leaked_fds < 0);

        $leaked_at[$pass]->[0] = $leaked_mem;
        $leaked_at[$pass]->[1] = $leaked_fds;
        $total_mem_leak += $leaked_mem;
        $total_fds_leak += $leaked_fds;

        $memory_hits++ if ($leaked_mem > 0);
    }

    return ($total_mem_leak, $total_fds_leak, $memory_hits, \@leaked_at);
}



sub noleaks(%) {
    my %args = @_;

    my ($mem, $fds, $mem_hits) = _noleaks(%args);

    my $tolerate_hits = $args{tolerate_hits} || 0;
    my $track_memory  = $args{'track_memory'};
    my $track_fds     = $args{'track_fds'};

    my $has_fd_leaks = $track_fds && ($fds > 0);
    my $has_mem_leaks = $track_memory && ($mem > 0) && ($mem_hits > $tolerate_hits);
    return !($has_fd_leaks || $has_mem_leaks);
}

sub test_noleaks(%) {
    my %args = @_;
    my ($mem, $fds, $mem_hits, $details) = _noleaks(%args);

    my $tolerate_hits = $args{tolerate_hits} || 0;
    my $track_memory  = $args{'track_memory'};
    my $track_fds     = $args{'track_fds'};

    my $has_fd_leaks = $track_fds && ($fds > 0);
    my $has_mem_leaks = $track_memory && ($mem > 0) && ($mem_hits > $tolerate_hits);
    my $has_leaks = $has_fd_leaks || $has_mem_leaks;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    if (!$has_leaks) {
        pass("no leaks have been found");
    } else {
      my $summary = "Leaked "
        . ($track_memory ? "$mem bytes ($mem_hits hits) " : "")
        . ($track_fds    ? "$fds file descriptors" : "");

      my @lines;
      for my $pass (1 .. @$details) {
        my $v = $details->[$pass-1];
        my ($mem, $fds) = @$v;
        if ($mem || $fds) {
          my $line = "pass $pass, leaked: "
            . ($track_memory ? $mem . " bytes " : "")
            . ($track_fds    ? $fds . " file descriptors" : "");
          push @lines, $line;
        }
      }
      my $report = join("\n", @lines);

      note($report);
      fail("$summary");
    }
}

=head1 SOURCE CODE

L<GitHub|https://github.com/binary-com/perl-Test-NoLeaks>

=head1 AUTHOR

binary.com, C<< <perl at binary.com> >>

=head1 BUGS

Please report any bugs or feature requests to
L<https://github.com/binary-com/perl-Test-NoLeaks/issues>.

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2015 binary.com

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

1;
