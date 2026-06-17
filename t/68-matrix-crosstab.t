use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use CoreSmoke::Model::Matrix;

my $h  = TestApp->new;
my $db = $h->app->sqlite->db;
my $m  = CoreSmoke::Model::Matrix->new(sqlite => $h->app->sqlite);

# ---------------------------------------------------------------------------
# Seed: two perl versions, three reports, multiple failures with stdio/perlio
# ---------------------------------------------------------------------------
#
#   Report 1: v5.42.0 on linux-6.5      (plevel 5.042000)
#   Report 2: v5.40.0 on darwin-23.0     (plevel 5.040000)
#   Report 3: v5.42.0 on darwin-23.0     (plevel 5.042000)
#
# Failures seeded:
#   op/magic.t   FAILED  -- perlio results in reports 1,2,3  (3 hits)
#   lib/warns.t  FAILED  -- perlio result  in report 1 only  (1 hit)
#   io/stdio.t   FAILED  -- stdio results  in reports 1,2   (2 hits, hidden by default)

my @reports = (
    {
        perl_id  => 'v5.42.0', plevel => '5.042000',
        osname   => 'linux',   osversion => '6.5',
        hostname => 'buildbot-a', architecture => 'x86_64',
        git_id   => 'abc1234', git_describe => 'v5.42.0-1-gabc1234',
    },
    {
        perl_id  => 'v5.40.0', plevel => '5.040000',
        osname   => 'darwin',  osversion => '23.0',
        hostname => 'mac-ci',  architecture => 'arm64',
        git_id   => 'def5678', git_describe => 'v5.40.0-1-gdef5678',
    },
    {
        perl_id  => 'v5.42.0', plevel => '5.042000',
        osname   => 'darwin',  osversion => '23.0',
        hostname => 'mac-ci2', architecture => 'arm64',
        git_id   => 'abc1235', git_describe => 'v5.42.0-2-gabc1235',
    },
);

my @rids;
for my $r (@reports) {
    $db->query(<<~'SQL',
        INSERT INTO report
            (perl_id, plevel, osname, osversion, hostname, architecture,
             git_id, git_describe, smoke_date, summary, report_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), 'FAIL', ?)
        SQL
        $r->{perl_id}, $r->{plevel}, $r->{osname}, $r->{osversion},
        $r->{hostname}, $r->{architecture}, $r->{git_id}, $r->{git_describe},
        $r->{git_id} . '_hash',
    );
    push @rids, $db->dbh->last_insert_id(undef, undef, 'report', undef);
}

my @cids;
for my $rid (@rids) {
    $db->query(
        "INSERT INTO config (report_id, arguments, debugging) VALUES (?, '', 'N')",
        $rid,
    );
    push @cids, $db->dbh->last_insert_id(undef, undef, 'config', undef);
}

# Each config gets a perlio result + a stdio result
my (@perlio_rids, @stdio_rids);
for my $cid (@cids) {
    $db->query(
        "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F')",
        $cid,
    );
    push @perlio_rids, $db->dbh->last_insert_id(undef, undef, 'result', undef);

    $db->query(
        "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'F')",
        $cid,
    );
    push @stdio_rids, $db->dbh->last_insert_id(undef, undef, 'result', undef);
}

# Seed failure rows (UNIQUE on test,status,extra)
my %fid;
for my $f (['op/magic.t', 'FAILED', undef],
           ['lib/warns.t', 'FAILED', undef],
           ['io/stdio.t', 'FAILED', undef]) {
    $db->query(
        "INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)",
        @$f,
    );
    $fid{ $f->[0] } = $db->dbh->last_insert_id(undef, undef, 'failure', undef);
}

# Link failures to perlio results:
#   op/magic.t  -> perlio results 0,1,2  (all three reports)
#   lib/warns.t -> perlio result 0 only  (report 1 only)
for my $idx (0, 1, 2) {
    $db->query(
        "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
        $perlio_rids[$idx], $fid{'op/magic.t'},
    );
}
$db->query(
    "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $perlio_rids[0], $fid{'lib/warns.t'},
);

# Link io/stdio.t to stdio results for reports 0 and 1
for my $idx (0, 1) {
    $db->query(
        "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
        $stdio_rids[$idx], $fid{'io/stdio.t'},
    );
}

# =========================================================================
# Test 1: matrix() default -- stdio excluded
# =========================================================================

my $mat = $m->matrix;

is scalar @{ $mat->{perl_versions} }, 2,
    'two distinct perl_ids detected';

# plevel DESC => v5.42.0 first, v5.40.0 second
is $mat->{perl_versions}[0], 'v5.42.0', 'highest plevel first';
is $mat->{perl_versions}[1], 'v5.40.0', 'lower plevel second';

# With stdio excluded: op/magic.t (3 perlio hits) and lib/warns.t (1 perlio hit).
# io/stdio.t should be absent.
my @tests = map { $_->{test} } @{ $mat->{rows} };
ok( (grep { $_ eq 'op/magic.t' } @tests),  'op/magic.t present');
ok( (grep { $_ eq 'lib/warns.t' } @tests), 'lib/warns.t present');
ok(!(grep { $_ eq 'io/stdio.t' } @tests),  'io/stdio.t excluded (stdio filter)');

# Sort order: op/magic.t (total=3) before lib/warns.t (total=1)
is $mat->{rows}[0]{test}, 'op/magic.t',  'highest-count test first';
is $mat->{rows}[1]{test}, 'lib/warns.t', 'lower-count test second';

# Cell counts for op/magic.t
my $magic = $mat->{rows}[0];
is $magic->{'v5.42.0'}{cnt}, 2, 'op/magic.t x v5.42.0 = 2 (reports 1+3)';
is $magic->{'v5.40.0'}{cnt}, 1, 'op/magic.t x v5.40.0 = 1';

# Cell counts for lib/warns.t
my $warns = $mat->{rows}[1];
is $warns->{'v5.42.0'}{cnt}, 1, 'lib/warns.t x v5.42.0 = 1';
ok !exists $warns->{'v5.40.0'}, 'lib/warns.t x v5.40.0 = absent (no failure)';

# GROUP_CONCAT: op/magic.t x v5.42.0 spans linux-6.5 and darwin-23.0
my @alts = sort split /,/, ($magic->{'v5.42.0'}{alt} // '');
is_deeply \@alts, ['darwin-23.0', 'linux-6.5'],
    'GROUP_CONCAT has distinct os pairs for v5.42.0';

# Single-OS cell: op/magic.t x v5.40.0 only on darwin-23.0
is $magic->{'v5.40.0'}{alt}, 'darwin-23.0',
    'single-os cell shows one os pair';

# =========================================================================
# Test 2: matrix(include_stdio => 1) -- stdio included
# =========================================================================

my $mat_stdio = $m->matrix(include_stdio => 1);

my @tests_stdio = map { $_->{test} } @{ $mat_stdio->{rows} };
ok( (grep { $_ eq 'io/stdio.t' } @tests_stdio),
    'io/stdio.t present when include_stdio=1');

# io/stdio.t has 2 stdio hits (reports 0,1 -> v5.42.0 and v5.40.0)
my ($stdio_row) = grep { $_->{test} eq 'io/stdio.t' } @{ $mat_stdio->{rows} };
is $stdio_row->{'v5.42.0'}{cnt}, 1, 'io/stdio.t x v5.42.0 = 1 (stdio)';
is $stdio_row->{'v5.40.0'}{cnt}, 1, 'io/stdio.t x v5.40.0 = 1 (stdio)';

# op/magic.t count unchanged (no magic failures in stdio results)
my ($magic_stdio) = grep { $_->{test} eq 'op/magic.t' } @{ $mat_stdio->{rows} };
is $magic_stdio->{'v5.42.0'}{cnt}, 2,
    'op/magic.t count unchanged with stdio (no stdio magic failures)';

# =========================================================================
# Test 3: sort order -- tie-breaking by test name
# =========================================================================

# Add a second failure to lib/warns.t for v5.40.0 so its total matches
# io/stdio.t (both 2). When totals tie, alphabetical test name wins.
$db->query(
    "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $perlio_rids[1], $fid{'lib/warns.t'},
);

my $mat_tie = $m->matrix(include_stdio => 1);
my @tied = grep { $_->{test} =~ /^(io\/stdio|lib\/warns)/ } @{ $mat_tie->{rows} };
is scalar @tied, 2, 'two tied-count tests found';
is $tied[0]{test}, 'io/stdio.t',  'alphabetical tie-break: io/ before lib/';
is $tied[1]{test}, 'lib/warns.t', 'alphabetical tie-break: lib/ after io/';

# =========================================================================
# Test 4: submatrix returns matching reports
# =========================================================================

my $sub = $m->submatrix('op/magic.t');
is scalar @$sub, 3, 'submatrix(op/magic.t) returns 3 reports';

my $sub_pv = $m->submatrix('op/magic.t', 'v5.40.0');
is scalar @$sub_pv, 1, 'submatrix filtered by pversion returns 1';
is $sub_pv->[0]{perl_id}, 'v5.40.0', 'filtered submatrix has correct perl_id';

# =========================================================================
# Test 5: perl_versions ordering with multiple plevels per perl_id
# =========================================================================
# When the same perl_id has multiple plevels (different git commits), the
# matrix must pick the highest plevel per perl_id for ordering. This
# verifies the GROUP BY + MAX(plevel) approach works correctly.

$db->query(<<~'SQL',
    INSERT INTO report
        (perl_id, plevel, osname, osversion, hostname, architecture,
         git_id, git_describe, smoke_date, summary, report_hash)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), 'FAIL', ?)
    SQL
    'v5.40.0', '5.040000zzz099',
    'linux', '6.5', 'buildbot-b', 'x86_64',
    'fff9999', 'v5.40.0-99-gfff9999',
    'fff9999_hash',
);
my $new_rid = $db->dbh->last_insert_id(undef, undef, 'report', undef);
$db->query("INSERT INTO config (report_id, arguments, debugging) VALUES (?, '', 'N')", $new_rid);
my $new_cid = $db->dbh->last_insert_id(undef, undef, 'config', undef);
$db->query("INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F')", $new_cid);
my $new_resid = $db->dbh->last_insert_id(undef, undef, 'result', undef);
$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $new_resid, $fid{'op/magic.t'});

my $mat_multi = $m->matrix;
is $mat_multi->{perl_versions}[0], 'v5.42.0',
    'v5.42.0 still first despite v5.40.0 having a high plevel commit';
is $mat_multi->{perl_versions}[1], 'v5.40.0',
    'v5.40.0 second (MAX plevel 5.040000zzz099 < 5.042000zzz000)';

done_testing;
