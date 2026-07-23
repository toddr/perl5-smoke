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

# Ingest fixture so we have data.
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, "ingested report $resp->{id}";

# ---- Common path (no config join, window function) -----------------------

$t->get_ok('/api/searchresults')
  ->status_is(200)
  ->json_is('/report_count' => 1, 'unfiltered: correct count')
  ->json_is('/page' => 1)
  ->json_is('/reports_per_page' => 25);

my $reports = $t->tx->res->json->{reports};
is scalar @$reports, 1, 'unfiltered: 1 report row';
ok !exists $reports->[0]{_total_count},
    'window function column stripped from output';

# Architecture filter -- still no config join
$t->get_ok('/api/searchresults?selected_arch=arm64')
  ->status_is(200)
  ->json_is('/report_count' => 1, 'arch filter: correct count');

$t->get_ok('/api/searchresults?selected_arch=x86_64')
  ->status_is(200)
  ->json_is('/report_count' => 0, 'arch mismatch: 0 count');

# ---- Config join path (compiler filter, two queries) ---------------------

$t->get_ok('/api/searchresults?selected_comp=cc')
  ->status_is(200)
  ->json_is('/report_count' => 1, 'compiler filter: correct count');

$t->get_ok('/api/searchresults?selected_comp=gcc')
  ->status_is(200)
  ->json_is('/report_count' => 0, 'compiler mismatch: 0 count');

# ---- Pagination ----------------------------------------------------------

$t->get_ok('/api/searchresults?reports_per_page=1&page=1')
  ->status_is(200)
  ->json_is('/report_count' => 1, 'page 1 of 1: correct count');

# Past-the-end: page 2 with 1 result total.
$t->get_ok('/api/searchresults?reports_per_page=1&page=2')
  ->status_is(200)
  ->json_is('/report_count' => 1, 'past-the-end: still reports total count');

my $empty = $t->tx->res->json->{reports};
is scalar @$empty, 0, 'past-the-end: no rows returned';

# ---- Empty result set (page 1) -------------------------------------------

$t->get_ok('/api/searchresults?selected_arch=nonexistent')
  ->status_is(200)
  ->json_is('/report_count' => 0, 'no match page 1: 0 count')
  ->json_is('/reports' => [], 'no match: empty list');

done_testing;
