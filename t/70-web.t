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

# Empty DB
$t->get_ok('/')      ->status_is(200)->content_like(qr/Latest\s+<em>smoke<\/em>\s+results|Latest smoke results/i);
$t->get_ok('/latest')->status_is(200);
$t->get_ok('/search')->status_is(200);
$t->get_ok('/matrix')->status_is(200);
$t->get_ok('/about') ->status_is(200);
$t->get_ok('/report/9999')        ->status_is(404);
$t->get_ok('/file/log_file/9999') ->status_is(404);
$t->get_ok('/file/out_file/9999') ->status_is(404);

# Layout includes the nav
$t->get_ok('/latest')->status_is(200)
  ->text_like('nav a' => qr/Latest|Search|Matrix|About/);

# Ingest a fixture and check the populated pages render
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
my $rid  = $resp->{id};

$t->get_ok('/latest')->status_is(200)
  ->content_like(qr/idefix/)                  # hostname appears in row
  ->content_like(qr/1\.77/);                  # smoke_version appears in row

$t->get_ok("/report/$rid")->status_is(200)
  ->text_like('h1' => qr/Smoke report #\Q$rid\E/)
  ->content_like(qr/v5\.37/, 'full_report shows git_describe value');

# Trust badge appears, Note section absent (no user_note in fixture)
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/<dt>Trust<\/dt>/)
  ->content_like(qr/Unauthenticated/)
  ->content_unlike(qr/<dt>Note<\/dt>/, 'no Note row when user_note is empty');

# Inject a user_note to exercise the Note rendering path and verify
# the Trust <dd> is properly closed before the Note <dt> opens.
$h->app->sqlite->db->query(
    "UPDATE report SET user_note = 'test note here' WHERE id = ?", $rid
);
$t->get_ok("/report/$rid")->status_is(200)
  ->content_like(qr/<dt>Note<\/dt>/, 'Note row appears with user_note')
  ->content_like(qr/test note here/);
# Verify Trust <dd> closes before Note <dt> (no nesting)
my $html = $t->tx->res->body;
if ($html =~ m{<dt>Trust</dt>\s*<dd>(.*?)</dd>}s) {
    unlike $1, qr/<dt>Note/, 'Note section is not nested inside Trust <dd>';
}
$h->app->sqlite->db->query(
    "UPDATE report SET user_note = NULL WHERE id = ?", $rid
);

# manifest_msgs is on disk; the file route reads it back through xz
# (we ingested an empty log_file so log_file path stays 404)
$t->get_ok("/file/log_file/$rid")->status_is(404);

# /latest exposes a Summary filter (All / Fail / Pass)
$t->get_ok('/latest')->status_is(200)
  ->element_exists('form#latest-form select[name=selected_summary]',
                   'summary filter exists on /latest')
  ->element_exists('option[value=all]')
  ->element_exists('option[value=fail]')
  ->element_exists('option[value=pass]');

# Filter shrinks the row set. The ingested fixture (idefix) has
# summary=PASS, so 'pass' and 'all' include it; 'fail' drops it.
$t->get_ok('/latest?selected_summary=pass')->status_is(200)
  ->content_like(qr/\bidefix\b/, 'pass filter keeps idefix (PASS)');
$t->get_ok('/latest?selected_summary=fail')->status_is(200)
  ->content_unlike(qr/\bidefix\b/, 'fail filter drops idefix');
$t->get_ok('/latest?selected_summary=all')->status_is(200)
  ->content_like(qr/\bidefix\b/, 'all filter keeps idefix');

# HTMX form-change response returns the latest-region partial
$t->get_ok('/latest?selected_summary=fail' =>
            { 'HX-Request' => 'true', 'HX-Trigger' => 'latest-form' })
  ->status_is(200)
  ->content_like(qr/id="latest-region"/, 'form-change returns region wrapper')
  ->content_like(qr/id="latest-form"/,   'form-change re-renders the form');

# HTMX infinite-scroll response (no HX-Trigger=latest-form) returns the
# rows-only partial: <tr> markup but no form/region wrapper.
$t->get_ok('/latest?selected_summary=fail' => { 'HX-Request' => 'true' })
  ->status_is(200)
  ->content_unlike(qr/id="latest-region"/, 'infinite-scroll skips the wrapper')
  ->content_unlike(qr/id="latest-form"/,   'infinite-scroll skips the form');

# /search shows smoker version column and filter dropdown
$t->get_ok('/search')->status_is(200)
  ->element_exists('select[name=selected_smkv]', 'smoker filter exists')
  ->content_like(qr/<th[^>]*>\s*Smoker\s*<\/th>/);

# Smoker filter narrows results
$t->get_ok('/search?selected_smkv=1.77')->status_is(200)
  ->content_like(qr/idefix/);
$t->get_ok('/search?selected_smkv=99.99')->status_is(200)
  ->content_unlike(qr/idefix/);

# Date range filter: date_from/date_to on /search
# Fixture has smoke_date 2022-07-31T01:05:08Z (UTC)
$t->get_ok('/search?date_from=2022-07-31&date_to=2022-07-31')->status_is(200)
  ->content_like(qr/idefix/, 'date range includes matching report');
$t->get_ok('/search?date_from=2022-07-31')->status_is(200)
  ->content_like(qr/idefix/, 'date_from alone includes report');
$t->get_ok('/search?date_to=2023-01-01')->status_is(200)
  ->content_like(qr/idefix/, 'date_to alone includes report');
$t->get_ok('/search?date_from=2023-01-01')->status_is(200)
  ->content_unlike(qr/idefix/, 'date_from after report excludes it');
$t->get_ok('/search?date_to=2022-07-30')->status_is(200)
  ->content_unlike(qr/idefix/, 'date_to before report excludes it');

# Date inputs render in the search form
$t->get_ok('/search')->status_is(200)
  ->element_exists('input[name=date_from][type=date]', 'date_from input exists')
  ->element_exists('input[name=date_to][type=date]',   'date_to input exists');

# "Clear all" button appears only when filters are active
$t->get_ok('/search')->status_is(200)
  ->element_exists_not('button[hx-get="/search"]',
                       'no clear button when no filters active');
$t->get_ok('/search?selected_arch=x86_64')->status_is(200)
  ->element_exists('button[hx-get="/search"]',
                   'clear button appears with a filter active')
  ->text_like('.filter-count' => qr/1 active filter/);
$t->get_ok('/search?selected_arch=x86_64&selected_branch=blead')->status_is(200)
  ->text_like('.filter-count' => qr/2 active filters/);

# About page shows Perl + Mojo + DB versions
$t->get_ok('/about')->status_is(200)
  ->content_like(qr/Mojolicious/)
  ->content_like(qr/SQLite/)
  ->content_like(qr/DB version/);

done_testing;
