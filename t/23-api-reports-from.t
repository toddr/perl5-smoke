use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;

my $h  = TestApp->new;
my $t  = $h->t;
my $db = $h->app->sqlite->db;

sub insert_report (%args) {
    $db->query(<<~'SQL',
        INSERT INTO report (
            smoke_date, perl_id, git_id, git_describe,
            hostname, architecture, osname, osversion,
            summary, smoke_branch, plevel, report_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        $args{smoke_date},
        $args{perl_id}      // '5.41.9',
        $args{git_id}       // 'abc123',
        $args{git_describe} // 'v5.41.9-1-gabc123',
        $args{hostname}     // 'testhost',
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.1',
        $args{summary}      // 'PASS',
        $args{smoke_branch} // 'blead',
        $args{plevel},
        $args{report_hash},
    );
}

insert_report(
    smoke_date  => '2024-06-01T10:00:00Z',
    plevel      => '5.041009zzz000',
    report_hash => 'rfrom001',
    git_id      => 'rf1',
);

insert_report(
    smoke_date  => '2024-07-15T12:00:00Z',
    plevel      => '5.041009zzz001',
    report_hash => 'rfrom002',
    git_id      => 'rf2',
);

my @ids = map { $_->{id} } @{ $db->query('SELECT id FROM report ORDER BY id')->hashes->to_array };

# ---- /api/reports_from_id/:rid ----------------------------------------

$t->get_ok("/api/reports_from_id/$ids[0]")
  ->status_is(200)
  ->json_is('/0' => $ids[0], 'first report id returned');

my $body = $t->tx->res->json;
ok ref $body eq 'ARRAY', 'reports_from_id returns an array';
is scalar @$body, 2, 'both reports returned when starting from first id';

$t->get_ok("/api/reports_from_id/$ids[0]?limit=1")
  ->status_is(200);
is scalar @{ $t->tx->res->json }, 1, 'limit=1 returns exactly one report';

$t->get_ok("/api/reports_from_id/$ids[1]")
  ->status_is(200)
  ->json_is('/0' => $ids[1], 'starting from second id returns second report');

$t->get_ok('/api/reports_from_id/999999')
  ->status_is(200);
is_deeply $t->tx->res->json, [], 'non-existent rid returns empty array';

# ---- /api/reports_from_date/:epoch ------------------------------------

# Epoch before both reports (Sep 2001)
my $old_epoch = 1000000000;
$t->get_ok("/api/reports_from_date/$old_epoch")
  ->status_is(200);
$body = $t->tx->res->json;
ok ref $body eq 'ARRAY', 'reports_from_date returns an array';
is scalar @$body, 2, 'old epoch returns all reports';

# Epoch between the two reports: 2024-07-01T00:00:00Z
my $mid_epoch = 1719792000;
$t->get_ok("/api/reports_from_date/$mid_epoch")
  ->status_is(200);
$body = $t->tx->res->json;
is scalar @$body, 1, 'mid epoch returns only the later report';
is $body->[0], $ids[1], 'mid epoch returns the second report id';

# Epoch in the far future
my $future_epoch = 9999999999;
$t->get_ok("/api/reports_from_date/$future_epoch")
  ->status_is(200);
is_deeply $t->tx->res->json, [], 'future epoch returns empty array';

# ---- reports_from_date limit parameter -----------------------------------

$t->get_ok("/api/reports_from_date/$old_epoch?limit=1")
  ->status_is(200);
is scalar @{ $t->tx->res->json }, 1, 'reports_from_date limit=1 returns one report';

$t->get_ok("/api/reports_from_date/$old_epoch?limit=999")
  ->status_is(200);
is scalar @{ $t->tx->res->json }, 2, 'reports_from_date limit>500 clamped, still returns both';

$t->get_ok("/api/reports_from_date/$old_epoch?limit=-5")
  ->status_is(200);
is scalar @{ $t->tx->res->json }, 1, 'reports_from_date negative limit clamped to 1';

done_testing;
