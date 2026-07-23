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

my $h = TestApp->new;
my $t = $h->t;

# ---- Ingest controller error responses -----------------------------------
# These exercise _extract_report_data error paths in Controller::Ingest
# that no existing test covers.

subtest 'JSON body: empty body -> 422' => sub {
    $t->post_ok('/api/report' =>
        { 'Content-Type' => 'application/json' } => '')
      ->status_is(422)
      ->json_like('/error' => qr/[Mm]issing/);
};

subtest 'JSON body: missing report_data key -> 422' => sub {
    $t->post_ok('/api/report', json => { foo => 'bar' })
      ->status_is(422)
      ->json_like('/error' => qr/report_data/);
};

subtest 'JSON body: invalid JSON -> 400' => sub {
    $t->post_ok('/api/report' =>
        { 'Content-Type' => 'application/json' } => '{broken json')
      ->status_is(400)
      ->json_like('/error' => qr/[Ii]nvalid JSON/);
};

subtest 'form body: missing json param -> 422' => sub {
    $t->post_ok('/api/report' =>
        { 'Content-Type' => 'application/x-www-form-urlencoded' } =>
        'something=else')
      ->status_is(422)
      ->json_like('/error' => qr/json param/i);
};

subtest 'form body: bad JSON in json param -> 400' => sub {
    $t->post_ok('/api/report' =>
        { 'Content-Type' => 'application/x-www-form-urlencoded' } =>
        'json=%7Bbroken')
      ->status_is(400)
      ->json_like('/error' => qr/[Bb]ad JSON/);
};

subtest 'JSON body: report_data is not a hash -> 409' => sub {
    $t->post_ok('/api/report', json => { report_data => 'just a string' })
      ->status_is(409)
      ->json_like('/error' => qr/[Mm]issing report_data/);
};

subtest 'JSON body: report_data is array -> 409' => sub {
    $t->post_ok('/api/report', json => { report_data => [1, 2, 3] })
      ->status_is(409)
      ->json_like('/error' => qr/[Mm]issing report_data/);
};

# ---- Ingest model edge cases --------------------------------------------

subtest 'post_report with non-hash $raw -> error' => sub {
    my $ingest = $h->app->ingest;
    my $result = $ingest->post_report('not a hash');
    ok $result->{error}, 'non-hash raw returns error';
    like $result->{error}, qr/[Mm]issing report_data/, 'error message is correct';
};

subtest '_upsert_smoke_config with undef -> returns undef' => sub {
    my $ingest = $h->app->ingest;
    my $id = $ingest->_upsert_smoke_config(undef);
    ok !defined $id, 'undef config returns undef id';
};

# ---- Plevel fallback path ------------------------------------------------

subtest 'Plevel::from_git_describe with bare SHA + perl_id fallback' => sub {
    use CoreSmoke::Model::Plevel;

    my $pl = CoreSmoke::Model::Plevel::from_git_describe('abc123def456', '5.41.9');
    is $pl, '5.041009zzz000', 'bare SHA falls back to perl_id-derived plevel';
};

subtest 'Plevel::from_git_describe with bare SHA, no perl_id' => sub {
    my $pl = CoreSmoke::Model::Plevel::from_git_describe('abc123def456');
    is $pl, '0.000000zzz000', 'bare SHA without perl_id returns low sentinel';
};

subtest 'Plevel::_from_perl_id edge cases' => sub {
    is CoreSmoke::Model::Plevel::_from_perl_id('5.41.9'),
       '5.041009zzz000', 'three-part version';
    is CoreSmoke::Model::Plevel::_from_perl_id('5.42'),
       '5.042000zzz000', 'two-part version (patch defaults to 0)';
    ok !defined CoreSmoke::Model::Plevel::_from_perl_id('bogus'),
       'malformed perl_id returns undef';
    ok !defined CoreSmoke::Model::Plevel::_from_perl_id(undef),
       'undef perl_id returns undef';
    ok !defined CoreSmoke::Model::Plevel::_from_perl_id(''),
       'empty perl_id returns undef';
};

# ---- Reports model: _summary_buckets ------------------------------------

subtest '_summary_buckets decomposition' => sub {
    my $buckets = CoreSmoke::Model::Reports::_summary_buckets([
        'PASS', 'FAIL(F)', 'FAIL(XM)', 'FAIL(m)', 'UNKNOWN',
    ]);
    ok((grep { $_ eq 'PASS' } @$buckets), 'PASS present');
    ok((grep { $_ eq 'FAIL(*)' } @$buckets), 'FAIL(*) umbrella present');
    ok((grep { $_ eq 'FAIL(F)' } @$buckets), 'FAIL(F) from FAIL(F)');
    ok((grep { $_ eq 'FAIL(X)' } @$buckets), 'FAIL(X) from FAIL(XM)');
    ok((grep { $_ eq 'FAIL(M)' } @$buckets), 'FAIL(M) from FAIL(XM)');
    ok((grep { $_ eq 'FAIL(m)' } @$buckets), 'FAIL(m) case-sensitive');
    ok((grep { $_ eq 'UNKNOWN' } @$buckets), 'UNKNOWN passes through');

    my $idx_pass = 0;
    my $idx_fail_star;
    for my $i (0 .. $#$buckets) {
        $idx_pass = $i if $buckets->[$i] eq 'PASS';
        $idx_fail_star = $i if $buckets->[$i] eq 'FAIL(*)';
    }
    ok $idx_pass < $idx_fail_star, 'PASS sorts before FAIL(*)';
};

subtest '_summary_buckets empty input' => sub {
    my $buckets = CoreSmoke::Model::Reports::_summary_buckets([]);
    is_deeply $buckets, [], 'empty input yields empty output';
};

subtest '_summary_buckets PASS-only' => sub {
    my $buckets = CoreSmoke::Model::Reports::_summary_buckets(['PASS', 'PASS(something)']);
    is scalar(@$buckets), 1, 'PASS variants collapse to one entry';
    is $buckets->[0], 'PASS', 'single PASS bucket';
};

# ---- Reports model: _sort_perl_ids_desc ---------------------------------

subtest '_sort_perl_ids_desc RPM-style ordering' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc([
        '5.38.0', '5.40.1', '5.41.9', '5.8.9', '5.40.0',
    ]);
    is_deeply $sorted, ['5.41.9', '5.40.1', '5.40.0', '5.38.0', '5.8.9'],
       'versions sorted highest-first by numeric components';
};

subtest '_sort_perl_ids_desc single entry' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(['5.42.0']);
    is_deeply $sorted, ['5.42.0'], 'single entry unchanged';
};

subtest '_sort_perl_ids_desc empty' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc([]);
    is_deeply $sorted, [], 'empty input yields empty output';
};

# ---- Reports model: _hhmm -----------------------------------------------

subtest '_hhmm formatting' => sub {
    is CoreSmoke::Model::Reports::_hhmm(0), '0:00', 'zero seconds';
    is CoreSmoke::Model::Reports::_hhmm(59), '0:00', '59 seconds rounds to 0:00';
    is CoreSmoke::Model::Reports::_hhmm(60), '0:01', '60 seconds = 0:01';
    is CoreSmoke::Model::Reports::_hhmm(3661), '1:01', '3661 seconds = 1:01';
    is CoreSmoke::Model::Reports::_hhmm(undef), '0:00', 'undef returns 0:00';
    is CoreSmoke::Model::Reports::_hhmm(-5), '0:00', 'negative returns 0:00';
};

done_testing;
