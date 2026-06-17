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

# Web paths: HTML 404
$t->get_ok('/no-such-page')->status_is(404)
    ->content_type_like(qr{text/html});

# API paths: JSON 404
$t->get_ok('/api/no-such-endpoint')->status_is(404)
    ->content_type_like(qr{application/json})
    ->json_is('/error' => 'Not found.');

$t->get_ok('/api/report_data/99999999')->status_is(404)
    ->json_is('/error' => 'Report not found.');

# /system sub-paths: JSON 404
$t->get_ok('/system/no-such-method')->status_is(404)
    ->content_type_like(qr{application/json})
    ->json_is('/error' => 'Not found.');

done_testing;
