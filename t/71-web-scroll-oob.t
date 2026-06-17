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
        $args{smoke_date}   // '2025-01-01T00:00:00Z',
        $args{perl_id}      // '5.41.9',
        $args{git_id}       // 'abc123',
        $args{git_describe} // 'v5.41.9-1-gabc123',
        $args{hostname},
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.1',
        $args{summary}      // 'PASS',
        $args{smoke_branch} // 'blead',
        $args{plevel}       // '5.041009zzz000',
        $args{report_hash},
    );
}

insert_report(hostname => "host-$_", report_hash => "oob-$_") for 1..3;

# --- /latest: page 2 infinite-scroll emits OOB summary ---
$t->get_ok('/latest?page=2&reports_per_page=2' => {
        'HX-Request' => 'true',
    })
    ->status_is(200)
    ->element_exists('#latest-summary[hx-swap-oob]',
        '/latest scroll emits OOB #latest-summary');

# --- /latest: form-change does NOT emit OOB (whole region is replaced) ---
$t->get_ok('/latest?page=1&reports_per_page=2' => {
        'HX-Request' => 'true',
        'HX-Trigger' => 'latest-form',
    })
    ->status_is(200)
    ->element_exists_not('[hx-swap-oob]',
        '/latest form-change has no OOB');

# --- /search: page 2 infinite-scroll emits OOB summary ---
$t->get_ok('/search?page=2&reports_per_page=2' => {
        'HX-Request' => 'true',
    })
    ->status_is(200)
    ->element_exists('#search-summary[hx-swap-oob]',
        '/search scroll emits OOB #search-summary');

# --- /search: form-change does NOT emit OOB ---
$t->get_ok('/search?page=1&reports_per_page=2' => {
        'HX-Request' => 'true',
        'HX-Trigger' => 'search-form',
    })
    ->status_is(200)
    ->element_exists_not('[hx-swap-oob]',
        '/search form-change has no OOB');

# --- /search: full page has search-summary id ---
$t->get_ok('/search')
    ->status_is(200)
    ->element_exists('#search-summary',
        '/search full page has #search-summary');

done_testing;
