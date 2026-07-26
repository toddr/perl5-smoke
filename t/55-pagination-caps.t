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
    hostname    => 'host-a',
    plevel      => '5.041009zzz000',
    smoke_date  => '2024-06-01T10:00:00Z',
    report_hash => 'pag001',
    git_id      => 'pag1',
);

# -- Model::Reports::latest -- rpp capped at 500 -------------------

my $data = $h->app->reports->latest({ reports_per_page => 9999, page => 1 });
is $data->{rpp}, 500, 'latest: reports_per_page capped at 500';

# -- Model::Reports::latest -- page floored at 1 -------------------

$data = $h->app->reports->latest({ page => -5 });
is $data->{page}, 1, 'latest: negative page clamped to 1';

$data = $h->app->reports->latest({ page => 0 });
is $data->{page}, 1, 'latest: zero page defaults to 1';

# -- Model::Reports::reports_from_id -- limit capped at 500 --------

my $ids = $h->app->reports->reports_from_id(1, 9999);
ok ref $ids eq 'ARRAY', 'reports_from_id returns arrayref';

# -- Search::run -- rpp capped, page floored ------------------------

my $search = $h->app->reports->searchresults({
    reports_per_page => 9999,
    page             => -3,
});
is $search->{reports_per_page}, 500, 'searchresults: rpp capped at 500';
is $search->{page},              1,  'searchresults: negative page clamped to 1';

# -- Negative rpp floored at 1 (SQLite LIMIT -1 = unlimited) -------

$data = $h->app->reports->latest({ reports_per_page => -1, page => 1 });
is $data->{rpp}, 1, 'latest: negative rpp floored at 1';

$search = $h->app->reports->searchresults({
    reports_per_page => -5,
    page             => 1,
});
is $search->{reports_per_page}, 1, 'searchresults: negative rpp floored at 1';

# -- Web endpoints accept extreme params without error --------------

$t->get_ok('/latest?reports_per_page=9999&page=-1')
  ->status_is(200);

$t->get_ok('/search?reports_per_page=9999&page=-1')
  ->status_is(200);

$t->get_ok('/latest?reports_per_page=-1')
  ->status_is(200);

$t->get_ok('/search?reports_per_page=-1')
  ->status_is(200);

# -- API endpoints accept extreme params without error --------------

$t->get_ok('/api/latest?reports_per_page=9999&page=-1')
  ->status_is(200)
  ->json_is('/rpp'  => 500, 'API latest: rpp capped at 500')
  ->json_is('/page' => 1,   'API latest: page clamped to 1');

$t->get_ok('/api/latest?reports_per_page=-1')
  ->status_is(200)
  ->json_is('/rpp' => 1, 'API latest: negative rpp floored at 1');

$t->get_ok('/api/searchresults?reports_per_page=9999&page=-1')
  ->status_is(200)
  ->json_is('/reports_per_page' => 500, 'API search: rpp capped at 500')
  ->json_is('/page'             => 1,   'API search: page clamped to 1');

$t->get_ok('/api/searchresults?reports_per_page=-1')
  ->status_is(200)
  ->json_is('/reports_per_page' => 1, 'API search: negative rpp floored at 1');

done_testing;
