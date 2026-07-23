use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;

my $h = TestApp->new;
my $t = $h->t;
my $db = $h->app->sqlite->db;

# Ingest the base fixture to get a report + config + result.
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, "report ingested ($resp->{id})";

my $config = $db->query(
    "SELECT id FROM config WHERE report_id = ? LIMIT 1", $resp->{id}
)->hash;
my $result = $db->query(
    "SELECT id FROM result WHERE config_id = ? LIMIT 1", $config->{id}
)->hash;

my $ingest = $h->app->ingest;

# --- Test: duplicate failure insertion must not crash ---
# If a concurrent INSERT lands between SELECT and INSERT (the old
# find_or_create pattern), the UNIQUE constraint fires.  After the fix,
# INSERT OR IGNORE absorbs the conflict silently.


my @failures = (
    { test => 'op/magic.t', status => 'FAILED', extra => 'some details' },
);

$ingest->_insert_failures($db, $result->{id}, \@failures);

my $first_fid = $db->query(
    "SELECT id FROM failure WHERE test = ? AND status = ?",
    'op/magic.t', 'FAILED',
)->hash->{id};
ok $first_fid, 'first failure inserted';

# Insert the same failure again for a different result.
my $result2 = $db->query(
    "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'FAIL') RETURNING id",
    $config->{id},
)->hash;

$ingest->_insert_failures($db, $result2->{id}, \@failures);

my $second_fid = $db->query(
    "SELECT id FROM failure WHERE test = ? AND status = ?",
    'op/magic.t', 'FAILED',
)->hash->{id};
is $second_fid, $first_fid, 'second insert reuses same failure row (no duplicate)';

# Verify failure count -- should be exactly one row.
my $count = $db->query(
    "SELECT COUNT(*) AS c FROM failure WHERE test = ?", 'op/magic.t'
)->hash->{c};
is $count, 1, 'exactly one failure row (deduplicated)';

# --- Test: pre-seeded row simulating concurrent insert ---
# Seed a failure row directly, then call _insert_failures for the same tuple.
# Under the old SELECT-then-INSERT pattern, this could race. Under INSERT OR
# IGNORE + SELECT, it must succeed without error.

$db->query(
    "INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)",
    'op/taint.t', 'FAILED', 'taint check',
);
my $seeded_id = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

my $result3 = $db->query(
    "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'FAIL') RETURNING id",
    $config->{id},
)->hash;

$ingest->_insert_failures($db, $result3->{id}, [
    { test => 'op/taint.t', status => 'FAILED', extra => 'taint check' },
]);

my $retrieved_id = $db->query(
    "SELECT id FROM failure WHERE test = ? AND status = ? AND extra = ?",
    'op/taint.t', 'FAILED', 'taint check',
)->hash->{id};
is $retrieved_id, $seeded_id, 'pre-seeded row reused (simulated concurrent insert)';

# --- Test: undef extra normalised consistently ---
$ingest->_insert_failures($db, $result->{id}, [
    { test => 'op/null.t', status => 'FAILED', extra => undef },
]);

my $null_row = $db->query(
    "SELECT id, extra FROM failure WHERE test = ?", 'op/null.t'
)->hash;
ok $null_row, 'failure with undef extra inserted';

# Insert again -- must not create a second row.
$ingest->_insert_failures($db, $result2->{id}, [
    { test => 'op/null.t', status => 'FAILED', extra => undef },
]);
my $null_count = $db->query(
    "SELECT COUNT(*) AS c FROM failure WHERE test = ?", 'op/null.t'
)->hash->{c};
is $null_count, 1, 'undef extra: deduplicated across calls';

# --- Test: query efficiency (INSERT RETURNING eliminates SELECT) ---
# Each failure should require exactly 2 queries: one upsert+RETURNING for
# the failure id, one INSERT OR IGNORE for failures_for_env.
{
    my $result4 = $db->query(
        "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'FAIL') RETURNING id",
        $config->{id},
    )->hash;

    my @efficiency_failures = (
        { test => 'op/eff1.t', status => 'FAILED', extra => '' },
        { test => 'op/eff2.t', status => 'FAILED', extra => '' },
        { test => 'op/eff3.t', status => 'FAILED', extra => '' },
    );

    my $query_count = 0;
    my $orig_query = $db->can('query');
    no warnings qw(redefine once);
    local *Mojo::SQLite::Database::query = sub {
        $query_count++;
        $orig_query->(@_);
    };
    use warnings qw(redefine once);

    $ingest->_insert_failures($db, $result4->{id}, \@efficiency_failures);
    is $query_count, 6, '3 failures x 2 queries each = 6 total (no separate SELECT)';
}

done_testing;
