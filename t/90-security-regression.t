use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use Mojo::Util qw(url_escape);
use TestApp;

my $h = TestApp->new;
my $t = $h->t;

my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
my $rid  = $resp->{id};
ok $rid, "ingested fixture report (id=$rid)";

# ======================================================================
# Issue #56 -- path traversal regression tests for /file/* routes
#
# The :rid placeholder flows into a parameterized SQL query
# (WHERE id = ?), so non-integer values return no rows -> 404.
# The file path is built from report_hash (DB column), never from :rid.
# These tests guard against a future refactor that might read :rid
# directly into a file path.
# ======================================================================

subtest 'path traversal: /file/log_file' => sub {
    $t->get_ok('/file/log_file/abc')->status_is(404);
    $t->get_ok('/file/log_file/-1')->status_is(404);
    $t->get_ok('/file/log_file/0')->status_is(404);
    $t->get_ok('/file/log_file/999999999')->status_is(404);
};

subtest 'path traversal: /file/out_file' => sub {
    $t->get_ok('/file/out_file/abc')->status_is(404);
    $t->get_ok('/file/out_file/-1')->status_is(404);
    $t->get_ok('/file/out_file/0')->status_is(404);
    $t->get_ok('/file/out_file/999999999')->status_is(404);
};

subtest 'path traversal: encoded slashes' => sub {
    my $encoded = url_escape('1/../../etc/passwd');
    $t->get_ok("/file/log_file/$encoded")->status_is(404);
    $t->get_ok("/file/out_file/$encoded")->status_is(404);
};

subtest 'path traversal: SQL injection in rid' => sub {
    my $sqli = url_escape('1 OR 1=1');
    $t->get_ok("/file/log_file/$sqli")->status_is(404);
    $t->get_ok("/file/out_file/$sqli")->status_is(404);
};

# ======================================================================
# Issue #55 -- SQL injection regression tests for search endpoints
#
# All filter values in Model::Search::compile() flow through
# parameterized ? binds. Column names come from a hardcoded map.
# These tests verify injection payloads are treated as literal strings,
# and the DB remains intact afterward.
# ======================================================================

subtest 'SQL injection: hostname filter' => sub {
    my $payload = "'; DROP TABLE report; --";
    $t->get_ok('/api/searchresults?selected_host=' . url_escape($payload))
      ->status_is(200)
      ->json_is('/report_count', 0, 'injection payload matches no reports');
};

subtest 'SQL injection: summary filter (GLOB path)' => sub {
    my $payload = 'PASS*; DELETE FROM report';
    $t->get_ok('/api/searchresults?selected_summary=' . url_escape($payload))
      ->status_is(200)
      ->json_is('/report_count', 0, 'injection in GLOB path returns 0');
};

subtest 'SQL injection: date filter' => sub {
    my $payload = "2024-01-01'; DROP TABLE report; --";
    $t->get_ok('/api/searchresults?date_from=' . url_escape($payload))
      ->status_is(200);
};

subtest 'SQL injection: architecture filter' => sub {
    my $payload = "x86_64' UNION SELECT * FROM config--";
    $t->get_ok('/api/searchresults?selected_arch=' . url_escape($payload))
      ->status_is(200)
      ->json_is('/report_count', 0, 'UNION injection matches nothing');
};

subtest 'SQL injection: branch filter with boolean bypass' => sub {
    my $payload = "blead' OR '1'='1";
    $t->get_ok('/api/searchresults?selected_branch=' . url_escape($payload))
      ->status_is(200)
      ->json_is('/report_count', 0, 'boolean bypass matches nothing');
};

subtest 'DB integrity after injection attempts' => sub {
    $t->get_ok('/api/searchresults')
      ->status_is(200)
      ->json_is('/report_count', 1, 'report table intact, original report still present');

    $t->get_ok("/report/$rid")
      ->status_is(200);
};

subtest 'SQL injection: /search web endpoint' => sub {
    my $payload = "'; DROP TABLE report; --";
    $t->get_ok('/search?selected_host=' . url_escape($payload))
      ->status_is(200);

    $t->get_ok('/api/searchresults')
      ->status_is(200)
      ->json_is('/report_count', 1, 'DB intact after web search injection attempt');
};

done_testing;
