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

# HX-Request flips /latest into a fragment template (no <html>, no <body>)
$t->get_ok('/latest', { 'HX-Request' => 'true' })
  ->status_is(200)
  ->content_unlike(qr{<html|<body}, '/latest with HX-Request returns fragment');

$t->get_ok('/search?selected_perl=all', { 'HX-Request' => 'true' })
  ->status_is(200)
  ->content_unlike(qr{<html|<body}, '/search with HX-Request returns fragment');

# Without HX-Request, full page including layout
$t->get_ok('/latest')->status_is(200)
  ->content_like(qr{<html}, '/latest without HX-Request returns full page');

# -- OOB pagination summary on infinite-scroll ----------------------

# /latest infinite-scroll (HX-Request without HX-Trigger matching form id)
# emits OOB summary targeting #latest-summary
$t->get_ok('/latest?page=1', { 'HX-Request' => 'true' })
  ->status_is(200)
  ->content_like(qr{id="latest-summary".*hx-swap-oob="true"}s,
    '/latest infinite-scroll emits OOB #latest-summary');

# /search infinite-scroll emits OOB summary targeting #search-summary
$t->get_ok('/search?page=1', { 'HX-Request' => 'true' })
  ->status_is(200)
  ->content_like(qr{id="search-summary".*hx-swap-oob="true"}s,
    '/search infinite-scroll emits OOB #search-summary');

# /search full-page render has the summary with id (for OOB targeting)
$t->get_ok('/search')
  ->status_is(200)
  ->content_like(qr{id="search-summary"}, '/search full page has #search-summary element');

# /search form-change does NOT emit OOB (the region itself is swapped)
$t->get_ok('/search?page=1', { 'HX-Request' => 'true', 'HX-Trigger' => 'search-form' })
  ->status_is(200)
  ->content_unlike(qr{hx-swap-oob="true"},
    '/search form-change does not emit OOB summary');

done_testing;
