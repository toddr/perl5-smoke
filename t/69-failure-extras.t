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

my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, "report ingested ($resp->{id})";
my $rid = $resp->{id};

my $cfg_id = $db->query(
    "SELECT id FROM config WHERE report_id = ? LIMIT 1", $rid
)->hash->{id};

my $res1_id = $db->query(
    "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F') RETURNING id",
    $cfg_id,
)->hash->{id};

my $res2_id = $db->query(
    "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'F') RETURNING id",
    $cfg_id,
)->hash->{id};

my $f1_id = $db->query(<<~'SQL', 'op/magic.t', 'FAILED', 'perlio: segfault at line 42')->hash->{id};
    INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)
    ON CONFLICT(test, status, extra) DO UPDATE SET test = test
    RETURNING id
SQL

my $f2_id = $db->query(<<~'SQL', 'op/magic.t', 'FAILED', 'stdio: signal 11 at line 99')->hash->{id};
    INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)
    ON CONFLICT(test, status, extra) DO UPDATE SET test = test
    RETURNING id
SQL

isnt $f1_id, $f2_id, 'two distinct failure rows (same test+status, different extra)';

$db->query(
    "INSERT OR IGNORE INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $res1_id, $f1_id,
);
$db->query(
    "INSERT OR IGNORE INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $res2_id, $f2_id,
);

# --- full_report_data must preserve both extras ---

my $report = $h->app->reports->full_report_data($rid);
ok $report, 'full_report_data returned';

my @test_failures = @{ $report->{test_failures} // [] };
my ($magic) = grep { $_->{test} eq 'op/magic.t' } @test_failures;
ok $magic, 'op/magic.t failure found in test_failures';

is scalar @{ $magic->{extras} // [] }, 2,
    'extras array has both distinct extra values';

my %extra_set = map { $_ => 1 } @{ $magic->{extras} };
ok $extra_set{'perlio: segfault at line 42'}, 'first extra preserved';
ok $extra_set{'stdio: signal 11 at line 99'}, 'second extra preserved';

is scalar @{ $magic->{configs} // [] }, 2,
    'both configs listed for the grouped failure';

# --- extra field still present for backward compat ---
ok defined $magic->{extra}, 'extra field still set (backward compat)';

# --- API endpoint returns extras too ---

my $api = $t->get_ok("/api/full_report_data/$rid")->status_is(200)->tx->res->json;
my ($api_magic) = grep { $_->{test} eq 'op/magic.t' } @{ $api->{test_failures} // [] };
ok $api_magic, 'API: op/magic.t failure present';
is scalar @{ $api_magic->{extras} // [] }, 2, 'API: extras array has 2 entries';

# --- Web page renders both extras ---

$t->get_ok("/report/$rid")->status_is(200)
    ->content_like(qr/perlio: segfault at line 42/)
    ->content_like(qr/stdio: signal 11 at line 99/);

# --- Single-extra case still works ---

my $res3_id = $db->query(
    "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F') RETURNING id",
    $cfg_id,
)->hash->{id};
my $f3_id = $db->query(<<~'SQL', 'op/solo.t', 'FAILED', 'only one extra')->hash->{id};
    INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)
    ON CONFLICT(test, status, extra) DO UPDATE SET test = test
    RETURNING id
SQL
$db->query(
    "INSERT OR IGNORE INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $res3_id, $f3_id,
);

my $report2 = $h->app->reports->full_report_data($rid);
my ($solo) = grep { $_->{test} eq 'op/solo.t' } @{ $report2->{test_failures} // [] };
ok $solo, 'single-extra failure found';
is scalar @{ $solo->{extras} }, 1, 'single extra in extras array';
is $solo->{extra}, 'only one extra', 'extra field matches single value';

# --- Empty-extra failure ---

my $res4_id = $db->query(
    "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F') RETURNING id",
    $cfg_id,
)->hash->{id};
my $f4_id = $db->query(<<~'SQL', 'op/empty.t', 'FAILED', '')->hash->{id};
    INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)
    ON CONFLICT(test, status, extra) DO UPDATE SET test = test
    RETURNING id
SQL
$db->query(
    "INSERT OR IGNORE INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $res4_id, $f4_id,
);

my $report3 = $h->app->reports->full_report_data($rid);
my ($empty) = grep { $_->{test} eq 'op/empty.t' } @{ $report3->{test_failures} // [] };
ok $empty, 'empty-extra failure found';
is scalar @{ $empty->{extras} }, 0, 'empty string extra not added to extras array';

done_testing;
