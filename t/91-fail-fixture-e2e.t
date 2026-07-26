use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use Mojo::Util qw(url_escape);

my $h = TestApp->new;
my $t = $h->t;

# Ingest the FAIL fixture.
my $resp = $h->ingest_fixture('fail-report.jsn');
ok $resp->{id}, "FAIL report ingested (id=$resp->{id})";
my $rid = $resp->{id};

# ---------------------------------------------------------------
# Full report page: verify failure rendering
# ---------------------------------------------------------------
$t->get_ok("/report/$rid")->status_is(200)
  ->text_like('h1' => qr/Smoke report #\Q$rid\E/)
  ->content_like(qr/FAIL\(F\)/, 'summary shows FAIL(F)')
  ->content_like(qr/failbox/,   'hostname rendered');

# Failures tab shows the count.
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/Failures\s*\(\s*2\s*\)/, 'failures tab shows count of 2');

# Each failing test appears as a danger alert with test name and status.
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/op\/magic\.t/,  'op/magic.t failure listed')
  ->content_like(qr/op\/taint\.t/,  'op/taint.t failure listed')
  ->content_like(qr/FAILED/,        'FAILED status shown');

# Failure extra detail (TAP output) is rendered.
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/got:\s*undef/, 'op/magic.t extra detail rendered')
  ->content_like(qr/expected:\s*42/, 'expected value in extra');

# Failure config list: op/magic.t fails in stdio on both configs.
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/\[stdio\]/, 'stdio io_env listed in failure configs');

# Submatrix link for each failure.
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr{/submatrix\?test=op%2Fmagic\.t}, 'submatrix link for op/magic.t');

# Configuration matrix: cells show F (danger) and O (success).
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/status-cell-danger/,  'danger cell for F result')
  ->content_like(qr/status-cell-success/, 'success cell for O result');

# ---------------------------------------------------------------
# Build messages tab: compiler, manifest, nonfatal, patches, skipped
# ---------------------------------------------------------------
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/Compiler messages/,  'compiler messages section rendered')
  ->content_like(qr/implicit declaration/, 'compiler_msgs content rendered')
  ->content_like(qr/unused variable/,      'second compiler msg rendered');

$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/Manifest messages/,    'manifest messages section rendered')
  ->content_like(qr/extra_file\.txt/,       'second manifest msg rendered');

$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/Non-fatal messages/,   'nonfatal messages section rendered')
  ->content_like(qr/nonfatal warning/,      'nonfatal msg content rendered');

$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/Applied patches/,      'applied patches section rendered')
  ->content_like(qr/PATCH-1234/,            'first patch rendered')
  ->content_like(qr/PATCH-5678/,            'second patch rendered');

$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/Skipped tests/,        'skipped tests section rendered')
  ->content_like(qr{ext/POSIX/t/time\.t},  'skipped test name rendered');

# ---------------------------------------------------------------
# log_file and out_file serving (issue #54)
# ---------------------------------------------------------------
$t->get_ok("/file/log_file/$rid")->status_is(200)
  ->content_like(qr/Smoking patch 5\.37\.3/, 'log_file serves decompressed content')
  ->content_like(qr/Failed 2 tests/,         'log_file contains failure summary');

$t->get_ok("/file/out_file/$rid")->status_is(200)
  ->content_like(qr/op\/magic\.t.*FAILED/,   'out_file serves magic.t failure output')
  ->content_like(qr/op\/taint\.t.*FAILED/,   'out_file serves taint.t failure output');

# Full report header shows log_file and out_file action buttons.
$t->get_ok("/report/$rid")->status_is(200)
  ->element_exists("a[href='/file/log_file/$rid']",  'log_file button in header')
  ->element_exists("a[href='/file/out_file/$rid']",  'out_file button in header');

# ---------------------------------------------------------------
# /latest: FAIL report appears, searchable by summary filter
# ---------------------------------------------------------------
$t->get_ok('/latest')->status_is(200)
  ->content_like(qr/failbox/, 'FAIL report hostname appears on /latest');

$t->get_ok('/latest?selected_summary=fail')->status_is(200)
  ->content_like(qr/failbox/, 'fail filter includes failbox');

$t->get_ok('/latest?selected_summary=pass')->status_is(200)
  ->content_unlike(qr/failbox/, 'pass filter excludes failbox');

# ---------------------------------------------------------------
# /search: FAIL report findable
# ---------------------------------------------------------------
$t->get_ok('/search?hostname=failbox')->status_is(200)
  ->content_like(qr/failbox/, 'search by hostname finds FAIL report');

$t->get_ok('/search?selected_summary=FAIL(F)')->status_is(200)
  ->content_like(qr/failbox/, 'search by summary FAIL(F) finds FAIL report');

# ---------------------------------------------------------------
# /matrix: failures appear in the heatmap
# ---------------------------------------------------------------
# Default matrix excludes stdio; op/taint.t (locale) shows, op/magic.t (stdio-only) does not.
$t->get_ok('/matrix')->status_is(200)
  ->content_like(qr/op\/taint\.t/,   'op/taint.t (locale) appears in default matrix')
  ->content_unlike(qr/op\/magic\.t/, 'op/magic.t (stdio-only) excluded from default matrix');

# With include_stdio=1, op/magic.t appears too.
$t->get_ok('/matrix?include_stdio=1')->status_is(200)
  ->content_like(qr/op\/magic\.t/, 'op/magic.t appears with include_stdio=1')
  ->content_like(qr/op\/taint\.t/, 'op/taint.t still appears with include_stdio=1');

# ---------------------------------------------------------------
# /submatrix: drill down on a specific failing test
# ---------------------------------------------------------------
$t->get_ok('/submatrix?test=' . url_escape('op/magic.t'))
  ->status_is(200)
  ->content_like(qr/failbox/, 'submatrix shows failbox for op/magic.t');

# ---------------------------------------------------------------
# API: full_report_data JSON includes failures
# ---------------------------------------------------------------
$t->get_ok("/api/full_report_data/$rid")->status_is(200)
  ->json_has('/test_failures')
  ->json_like('/test_failures/0/test' => qr/op\/(magic|taint)\.t/)
  ->json_is('/summary' => 'FAIL(F)');

done_testing;
