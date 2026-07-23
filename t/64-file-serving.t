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

# Ingest a report so we have a rid and report_hash.
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
my $rid  = $resp->{id};
ok $rid, "ingested fixture (rid=$rid)";

# Look up the report_hash so we can write files to disk.
my $hash = $h->app->sqlite->db->query(
    "SELECT report_hash FROM report WHERE id = ?", $rid,
)->hash->{report_hash};
ok $hash, "report_hash exists";

# --- Without on-disk files: 404 ---

$t->get_ok("/file/log_file/$rid")->status_is(404);
$t->get_ok("/file/out_file/$rid")->status_is(404);
$t->get_ok("/api/logfile/$rid")->status_is(404);
$t->get_ok("/api/outfile/$rid")->status_is(404);

# --- Write files to disk, then verify the happy path ---

my $log_content = "Running make test...\nAll tests successful.\nResult: PASS\n";
my $out_content = "Smoking perl 5.41.2\nConfiguration: -Dusedevel\n";

$h->app->report_files->write($hash, {
    log_file => $log_content,
    out_file => $out_content,
});

# Web routes: render the plain_text template with decompressed content.
$t->get_ok("/file/log_file/$rid")->status_is(200)
  ->content_like(qr/All tests successful/, 'log_file content rendered');

$t->get_ok("/file/out_file/$rid")->status_is(200)
  ->content_like(qr/Smoking perl 5\.41\.2/, 'out_file content rendered');

# API routes: return JSON { file => <content> }.
$t->get_ok("/api/logfile/$rid")->status_is(200)
  ->json_is('/file' => $log_content, 'API logfile returns full content');

$t->get_ok("/api/outfile/$rid")->status_is(200)
  ->json_is('/file' => $out_content, 'API outfile returns full content');

# Legacy /api/outfle typo alias works too.
$t->get_ok("/api/outfle/$rid")->status_is(200)
  ->json_is('/file' => $out_content, 'outfle alias returns same content');

# --- Non-existent report id: 404 ---

$t->get_ok("/file/log_file/999999")->status_is(404);
$t->get_ok("/api/logfile/999999")->status_is(404);

# --- full_report_data reflects on-disk files ---

$t->get_ok("/api/full_report_data/$rid")->status_is(200)
  ->json_is('/has_log_file' => 1, 'full_report_data shows has_log_file=1')
  ->json_is('/has_out_file' => 1, 'full_report_data shows has_out_file=1');

# Web full report page renders with file links.
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr{/file/log_file/$rid}, 'full report links to log_file')
  ->content_like(qr{/file/out_file/$rid}, 'full report links to out_file');

done_testing;
