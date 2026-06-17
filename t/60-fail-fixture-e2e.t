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

# --- Ingest the FAIL fixture ---
my $resp = $h->ingest_fixture('fail-report.jsn');
ok $resp->{id}, "FAIL report ingested (id=$resp->{id})";
my $rid = $resp->{id};

# Verify DB row basics
my $row = $h->app->sqlite->db->query(
    "SELECT summary, hostname, perl_id FROM report WHERE id = ?", $rid
)->hash;
is $row->{summary},  'FAIL(F)',   'summary stored as FAIL(F)';
is $row->{hostname}, 'smokebox',  'hostname from sysinfo';
is $row->{perl_id},  '5.39.1',   'perl_id from sysinfo';

# --- On-disk files: log_file and out_file should be written ---
my $log = $h->app->report_files->read($rid, 'log_file');
like $log, qr/build log for perl/, 'log_file round-trips through disk';

my $out = $h->app->report_files->read($rid, 'out_file');
like $out, qr/FAIL\(F\)/, 'out_file round-trips through disk';

my $compiler = $h->app->report_files->read($rid, 'compiler_msgs');
like $compiler, qr/unused variable/, 'compiler_msgs round-trips through disk';

# --- Configs and results with failures ---
my $configs = $h->app->sqlite->db->query(
    "SELECT id, arguments, debugging FROM config WHERE report_id = ? ORDER BY id",
    $rid,
)->hashes->to_array;
is scalar(@$configs), 2, 'two configs inserted';
is $configs->[0]{debugging}, 'N', 'first config non-debug';
is $configs->[1]{debugging}, 'D', 'second config debug';

my $results = $h->app->sqlite->db->query(
    "SELECT id, io_env, summary FROM result WHERE config_id = ? ORDER BY id",
    $configs->[0]{id},
)->hashes->to_array;
is scalar(@$results), 3, 'three results for first config';
is $results->[0]{summary}, 'F', 'stdio result is F (fail)';
is $results->[1]{summary}, 'F', 'perlio result is F (fail)';
is $results->[2]{summary}, 'O', 'locale result is O (pass)';

# Failure rows deduplicated in the failure table
my $fail_count = $h->app->sqlite->db->query(
    "SELECT COUNT(*) AS c FROM failure",
)->hash->{c};
is $fail_count, 2, 'exactly 2 distinct failures (op/magic.t + op/taint.t)';

# failures_for_env links: op/magic.t appears in 2 results (stdio + perlio)
my $magic_envs = $h->app->sqlite->db->query(<<~'SQL')->hash->{c};
    SELECT COUNT(*) AS c
    FROM failures_for_env fe
    JOIN failure f ON f.id = fe.failure_id
    WHERE f.test = 'op/magic.t'
    SQL
is $magic_envs, 2, 'op/magic.t linked to 2 result environments';

# --- API: full_report_data includes failures ---
my $full = $t->get_ok("/api/full_report_data/$rid")->status_is(200)
    ->json_has('/configs')
    ->json_has('/test_failures')
    ->json_has('/c_compilers')
    ->json_has('/durations')
    ->tx->res->json;

ok scalar(@{ $full->{test_failures} }) >= 2,
   'full_report_data.test_failures has at least 2 entries';

my @test_names = map { $_->{test} } @{ $full->{test_failures} };
ok((grep { $_ eq 'op/magic.t' } @test_names), 'op/magic.t in test_failures');
ok((grep { $_ eq 'op/taint.t' } @test_names), 'op/taint.t in test_failures');

like $full->{compiler_msgs_text}, qr/unused variable/,
     'full_report_data includes compiler_msgs_text from disk';

# has_log_file / has_out_file flags
ok $full->{has_log_file}, 'has_log_file is true';
ok $full->{has_out_file}, 'has_out_file is true';

# --- File serving: log and out files accessible ---
$t->get_ok("/file/log_file/$rid")->status_is(200)
  ->content_like(qr/build log for perl/);
$t->get_ok("/file/out_file/$rid")->status_is(200)
  ->content_like(qr/FAIL\(F\)/);

$t->get_ok("/api/logfile/$rid")->status_is(200)
  ->content_like(qr/build log for perl/);
$t->get_ok("/api/outfile/$rid")->status_is(200)
  ->content_like(qr/FAIL\(F\)/);

# --- Web: /report/:rid renders failure panel ---
$t->get_ok("/report/$rid")->status_is(200)
  ->text_like('h1' => qr/Smoke report #\Q$rid\E/)
  ->content_like(qr/op\/magic\.t/,  'failure op/magic.t rendered on report page')
  ->content_like(qr/op\/taint\.t/,  'failure op/taint.t rendered on report page')
  ->content_like(qr/FAILED/,        'FAILED status shown')
  ->content_like(qr/Failures \(2\)/, 'failure tab shows count of 2');

# Status pill on report page should show FAIL
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/FAIL\(F\)/,     'FAIL(F) status pill on report page');

# Compiler messages visible
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/unused variable/, 'compiler messages rendered');

# log_file / out_file buttons should be present
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr{/file/log_file/$rid}, 'log_file link present')
  ->content_like(qr{/file/out_file/$rid}, 'out_file link present');

# --- Web: /latest shows the FAIL report ---
$t->get_ok('/latest')->status_is(200)
  ->content_like(qr/smokebox/,   'hostname appears on /latest')
  ->content_like(qr/FAIL/,       'FAIL summary visible on /latest');

# Summary filter: fail keeps it, pass drops it
$t->get_ok('/latest?selected_summary=fail')->status_is(200)
  ->content_like(qr/smokebox/, 'fail filter keeps FAIL report');
$t->get_ok('/latest?selected_summary=pass')->status_is(200)
  ->content_unlike(qr/smokebox/, 'pass filter drops FAIL report');

# --- Web: /search finds the FAIL report ---
$t->get_ok('/search?selected_summary=FAIL(F)')->status_is(200)
  ->content_like(qr/smokebox/, 'search FAIL(F) finds smokebox report');
$t->get_ok('/search?selected_summary=PASS')->status_is(200)
  ->content_unlike(qr/smokebox/, 'search PASS excludes FAIL report');

# --- Matrix: failure appears ---
$t->get_ok('/matrix')->status_is(200)
  ->content_like(qr/op\/magic\.t/, 'matrix shows op/magic.t failure');

# API matrix
$t->get_ok('/api/matrix')->status_is(200);
my $matrix = $t->tx->res->json;
ok scalar(@{ $matrix->{rows} // [] }) >= 1,
   'API matrix has at least 1 failure row';

# --- Submatrix: drill down on a specific failure ---
$t->get_ok('/submatrix?test=op%2Fmagic.t')->status_is(200)
  ->content_like(qr/smokebox/, 'submatrix shows smokebox for op/magic.t');

# --- Duplicate detection still works ---
$t->post_ok('/api/report', json => { report_data => $h->fixture('fail-report.jsn') })
  ->status_is(409)
  ->json_is('/error' => 'Report already posted.');

done_testing;
