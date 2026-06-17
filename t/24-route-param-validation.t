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

# Non-numeric :rid values must 404 at the routing layer (never reach
# the controller). Before route constraints these would silently pass
# through and hit the DB with a string WHERE id = 'abc'.

my @rid_routes = qw(
    /api/full_report_data
    /api/report_data
    /api/logfile
    /api/outfile
    /api/outfle
    /api/reports_from_id
    /report
    /file/log_file
    /file/out_file
);

for my $base (@rid_routes) {
    $t->get_ok("$base/abc")->status_is(404, "$base/abc rejected");
    $t->get_ok("$base/12.3")->status_is(404, "$base/12.3 rejected");
    $t->get_ok("$base/1; DROP TABLE report")->status_is(404, "$base/sqli rejected");
}

# Numeric :rid values must still route correctly (200 or 404 from the
# controller, not from the router).
$t->get_ok('/api/report_data/999999')->status_is(404);
$t->get_ok('/api/reports_from_id/1')->status_is(200);

# Non-numeric :epoch must 404
$t->get_ok('/api/reports_from_date/abc')->status_is(404, 'non-numeric epoch rejected');
$t->get_ok('/api/reports_from_date/-1')->status_is(404, 'negative epoch rejected');
$t->get_ok('/api/reports_from_date/12.5')->status_is(404, 'decimal epoch rejected');

# Numeric epoch still works
$t->get_ok('/api/reports_from_date/9999999999')->status_is(200);

done_testing;
