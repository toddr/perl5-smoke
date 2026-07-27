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
        $args{summary},
        $args{smoke_branch} // 'blead',
        $args{plevel}       // '5.041009zzz000',
        $args{report_hash},
    );
}

# --- Empty DB: all stats should be 0 ---
$t->get_ok('/latest')->status_is(200)
  ->text_is('.stat:nth-child(3) .stat-value' => '0')
  ->text_is('.stat:nth-child(4) .stat-value' => '0')
  ->text_is('.stat:nth-child(5) .stat-value' => '0');

# --- Insert reports: 2 recent PASS, 1 recent FAIL, 1 old PASS ---
my $recent = do {
    my @t = gmtime(time - 3600);
    sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0];
};

insert_report(smoke_date => $recent, summary => 'PASS',
    report_hash => 'hero01', hostname => 'h1', git_id => 'g1');
insert_report(smoke_date => $recent, summary => 'PASS',
    report_hash => 'hero02', hostname => 'h2', git_id => 'g2');
insert_report(smoke_date => $recent, summary => 'FAIL(F)',
    report_hash => 'hero03', hostname => 'h3', git_id => 'g3');
insert_report(smoke_date => '2020-01-01T00:00:00Z', summary => 'PASS',
    report_hash => 'hero04', hostname => 'h4', git_id => 'g4');

$t->get_ok('/latest')->status_is(200)
  ->text_is('.stat:nth-child(3) .stat-value' => '2')
  ->text_is('.stat:nth-child(4) .stat-value' => '1')
  ->text_is('.stat:nth-child(5) .stat-value' => '4');

# --- PASS variant (e.g. with trailing info) should count as a pass ---
insert_report(smoke_date => $recent, summary => 'PASS(X)',
    report_hash => 'hero05', hostname => 'h5', git_id => 'g5');

$t->get_ok('/latest')->status_is(200)
  ->text_is('.stat:nth-child(3) .stat-value' => '3',
            'PASS variant counted in pass_24h')
  ->text_is('.stat:nth-child(5) .stat-value' => '5',
            'total includes PASS variant');

# --- HTMX request should NOT include hero stats ---
$t->get_ok('/latest' => { 'HX-Request' => 'true' })->status_is(200)
  ->element_exists_not('.hero-meta');

done_testing;
