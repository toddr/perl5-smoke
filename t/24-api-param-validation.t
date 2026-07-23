use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use Mojo::JSON qw(encode_json);

my $h  = TestApp->new;
my $t  = $h->t;

# ---- /api/*/:rid endpoints reject non-numeric rid ------------------------

my @rid_endpoints = qw(
    full_report_data
    report_data
    logfile
    outfile
    reports_from_id
);

for my $ep (@rid_endpoints) {
    $t->get_ok("/api/$ep/abc")
      ->status_is(400)
      ->json_like('/error' => qr/rid/)
      ->or(sub { diag "FAIL: /api/$ep/abc should return 400" });

    $t->get_ok("/api/$ep/-1")
      ->status_is(400, "/api/$ep/-1 rejects negative rid");

    $t->get_ok("/api/$ep/0")
      ->status_is(400, "/api/$ep/0 rejects zero rid");
}

# Valid but nonexistent rid should get past validation (404 or empty result)
for my $ep (qw(full_report_data report_data logfile outfile)) {
    $t->get_ok("/api/$ep/999999")
      ->status_is(404, "/api/$ep/999999 passes validation, returns 404");
}

$t->get_ok('/api/reports_from_id/999999')
  ->status_is(200, 'reports_from_id with valid rid passes validation');

# ---- /api/reports_from_date/:epoch rejects non-numeric epoch -------------

$t->get_ok('/api/reports_from_date/abc')
  ->status_is(400)
  ->json_like('/error' => qr/epoch/);

$t->get_ok('/api/reports_from_date/-1')
  ->status_is(400, 'negative epoch rejected');

# Zero epoch is valid (Unix epoch 0 = 1970-01-01)
$t->get_ok('/api/reports_from_date/0')
  ->status_is(200, 'epoch 0 accepted');

# ---- /api/latest pagination clamping ------------------------------------

$t->get_ok('/api/latest?reports_per_page=-1')
  ->status_is(200, 'negative rpp clamped, not rejected');

my $body = $t->tx->res->json;
ok !ref $body->{reports} || ref $body->{reports} eq 'ARRAY',
    'response still well-formed after rpp clamping';

$t->get_ok('/api/latest?page=-5')
  ->status_is(200, 'negative page clamped');

$t->get_ok('/api/latest?reports_per_page=9999')
  ->status_is(200, 'oversized rpp clamped');

# ---- /api/reports_from_id limit clamping --------------------------------

$t->get_ok('/api/reports_from_id/999999?limit=-1')
  ->status_is(200, 'negative limit clamped');

$t->get_ok('/api/reports_from_id/999999?limit=9999')
  ->status_is(200, 'oversized limit clamped');

$t->get_ok('/api/reports_from_id/999999?limit=abc')
  ->status_is(200, 'non-numeric limit gets default');

# ---- JSONRPC rid validation ----------------------------------------------

my @jsonrpc_methods_with_rid = qw(
    full_report_data report_data logfile outfile reports_from_id
);

for my $method (@jsonrpc_methods_with_rid) {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 1,
        method  => $method,
        params  => { rid => 'abc' },
    })->status_is(200);

    my $res = $t->tx->res->json;
    ok $res->{error}, "JSONRPC $method rejects non-numeric rid";
    is $res->{error}{code}, -32602, "JSONRPC $method returns -32602 for bad rid"
        if $res->{error};
}

# ---- JSONRPC epoch validation --------------------------------------------

$t->post_ok('/api', json => {
    jsonrpc => '2.0', id => 1,
    method  => 'reports_from_date',
    params  => { epoch => 'abc' },
})->status_is(200);

my $res = $t->tx->res->json;
ok $res->{error}, 'JSONRPC reports_from_date rejects non-numeric epoch';
is $res->{error}{code}, -32602, 'returns -32602 for bad epoch'
    if $res->{error};

# ---- JSONRPC pagination clamping (should not error) ----------------------

$t->post_ok('/api', json => {
    jsonrpc => '2.0', id => 1,
    method  => 'latest',
    params  => { page => -5, reports_per_page => -1 },
})->status_is(200);

$res = $t->tx->res->json;
ok $res->{result}, 'JSONRPC latest clamps bad pagination instead of erroring';

done_testing;
