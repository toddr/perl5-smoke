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
        $args{hostname},
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.1',
        $args{summary}      // 'PASS',
        $args{smoke_branch} // 'blead',
        $args{plevel},
        $args{report_hash},
    );
}

# Host A: two reports at different plevels -- higher plevel should win
insert_report(
    hostname    => 'alpha',
    plevel      => '5.041009zzz000',
    smoke_date  => '2024-06-01T10:00:00Z',
    report_hash => 'aaa111',
    git_id      => 'aaa1',
);
insert_report(
    hostname    => 'alpha',
    plevel      => '5.042001zzz000',
    smoke_date  => '2024-05-01T10:00:00Z',
    report_hash => 'aaa222',
    git_id      => 'aaa2',
);

# Host B: two reports at the SAME plevel -- later smoke_date should win
insert_report(
    hostname    => 'bravo',
    plevel      => '5.041009zzz000',
    smoke_date  => '2024-03-01T10:00:00Z',
    report_hash => 'bbb111',
    git_id      => 'bbb1',
);
insert_report(
    hostname    => 'bravo',
    plevel      => '5.041009zzz000',
    smoke_date  => '2024-07-15T10:00:00Z',
    report_hash => 'bbb222',
    git_id      => 'bbb2',
);

# Host C: single report (trivial case)
insert_report(
    hostname    => 'charlie',
    plevel      => '5.040000zzz000',
    smoke_date  => '2024-01-01T10:00:00Z',
    report_hash => 'ccc111',
    git_id      => 'ccc1',
);

my $data = $h->app->reports->latest;

is $data->{report_count}, 3, 'three distinct hostnames';

my %by_host = map { $_->{hostname} => $_ } @{ $data->{reports} };

is $by_host{alpha}{plevel}, '5.042001zzz000',
    'alpha: higher plevel wins over newer smoke_date';

is $by_host{bravo}{smoke_date}, '2024-07-15T10:00:00Z',
    'bravo: later smoke_date wins within same plevel';

is $by_host{charlie}{plevel}, '5.040000zzz000',
    'charlie: single report returned';

# Ordering: results should be plevel DESC, smoke_date DESC
my @plevels = map { $_->{plevel} } @{ $data->{reports} };
my @sorted  = sort { $b cmp $a } @plevels;
is_deeply \@plevels, \@sorted, 'results ordered by plevel DESC';

# Pagination
my $page1 = $h->app->reports->latest({ reports_per_page => 2, page => 1 });
is scalar @{ $page1->{reports} }, 2, 'page 1 has 2 reports';
is $page1->{report_count}, 3, 'total count unaffected by pagination';

my $page2 = $h->app->reports->latest({ reports_per_page => 2, page => 2 });
is scalar @{ $page2->{reports} }, 1, 'page 2 has remaining 1 report';

# --- Page beyond last page: count must still reflect the true total --------
{
    my $beyond = $h->app->reports->latest({ reports_per_page => 2, page => 99 });
    is scalar @{ $beyond->{reports} }, 0, 'page 99 returns no reports';
    is $beyond->{report_count}, 3,
        'report_count is correct even when page exceeds result set';
}

# --- latest_plevel: should be the highest plevel in the whole DB -----------
{
    is $data->{latest_plevel}, '5.042001zzz000',
        'latest_plevel is the highest plevel across all reports';
}

# --- Summary filter: PASS / FAIL ------------------------------------------

# Add a FAIL report for a new host so we have both PASS and FAIL
insert_report(
    hostname    => 'delta',
    plevel      => '5.041009zzz000',
    smoke_date  => '2024-08-01T10:00:00Z',
    summary     => 'FAIL(F)',
    report_hash => 'ddd111',
    git_id      => 'ddd1',
);

{
    my $all = $h->app->reports->latest({ selected_summary => 'all' });
    is $all->{report_count}, 4, 'selected_summary=all returns all hosts';
}

{
    my $pass = $h->app->reports->latest({ selected_summary => 'pass' });
    is $pass->{report_count}, 3, 'selected_summary=pass returns only PASS hosts';
    ok( !(grep { $_->{summary} =~ /^FAIL/ } @{ $pass->{reports} }),
        'no FAIL reports in pass filter' );
}

{
    my $fail = $h->app->reports->latest({ selected_summary => 'fail' });
    is $fail->{report_count}, 1, 'selected_summary=fail returns only FAIL hosts';
    is $fail->{reports}[0]{hostname}, 'delta', 'FAIL host is delta';
}

{
    my $unknown = $h->app->reports->latest({ selected_summary => 'bogus' });
    is $unknown->{report_count}, 4,
        'unknown summary value treated as all (no filter)';
}

# Summary filter is case-insensitive
{
    my $upper = $h->app->reports->latest({ selected_summary => 'PASS' });
    is $upper->{report_count}, 3, 'PASS (uppercase) works as pass filter';
}

# --- Summary filter + pagination beyond: fallback count must apply filter ---
{
    my $fail_beyond = $h->app->reports->latest({
        selected_summary => 'fail',
        reports_per_page => 25,
        page             => 99,
    });
    is scalar @{ $fail_beyond->{reports} }, 0,
        'fail filter + beyond-page returns no reports';
    is $fail_beyond->{report_count}, 1,
        'fail filter + beyond-page still counts 1 FAIL host';
}

# --- Empty DB: no reports at all -------------------------------------------
{
    $db->query('DELETE FROM report');
    my $empty = $h->app->reports->latest;
    is $empty->{report_count}, 0, 'empty DB returns count 0';
    is scalar @{ $empty->{reports} }, 0, 'empty DB returns no reports';
    is $empty->{latest_plevel}, '', 'empty DB has empty latest_plevel';
}

done_testing;
