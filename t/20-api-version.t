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

$t->get_ok('/api/version')->status_is(200)
  ->json_is('/version'        => '2.0')
  ->json_is('/schema_version' => '4')
  ->json_is('/db_version'     => '4');

# Empty DB shapes
$t->get_ok('/api/latest')->status_is(200)
  ->json_is('/report_count' => 0)
  ->json_is('/page'         => 1)
  ->json_is('/reports_per_page' => 25);

$t->get_ok('/api/searchparameters')->status_is(200)
  ->json_has('/sel_arch_os_ver')
  ->json_has('/sel_comp_ver')
  ->json_has('/branches')
  ->json_has('/perl_versions');

$t->get_ok('/api/searchresults?selected_perl=all')->status_is(200)
  ->json_is('/report_count' => 0)
  ->json_is('/reports_per_page' => 25);

$t->get_ok('/api/matrix')->status_is(200)
  ->json_is('/perl_versions' => [])
  ->json_is('/rows' => []);

$t->get_ok('/api/submatrix?test=lib/foo.t')->status_is(200);
$t->get_ok('/api/submatrix')->status_is(422);   # missing test param

# 404 paths
$t->get_ok('/api/full_report_data/9999')->status_is(404);
$t->get_ok('/api/report_data/9999')     ->status_is(404);
$t->get_ok('/api/logfile/9999')         ->status_is(404);
$t->get_ok('/api/outfile/9999')         ->status_is(404);
$t->get_ok('/api/outfle/9999')          ->status_is(404);   # legacy typo intentionally removed

# CORS header on /api/* responses
$t->get_ok('/api/version')->status_is(200)
  ->header_is('Access-Control-Allow-Origin' => '*');

done_testing;
