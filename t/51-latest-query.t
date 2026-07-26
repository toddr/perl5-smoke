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

# Host D: two reports at same (hostname, plevel, smoke_date) but
# different architectures -- must return exactly one row, not two.
insert_report(
    hostname     => 'delta',
    plevel       => '5.041009zzz000',
    smoke_date   => '2024-08-01T12:00:00Z',
    report_hash  => 'ddd111',
    git_id       => 'ddd1',
    architecture => 'x86_64',
);
insert_report(
    hostname     => 'delta',
    plevel       => '5.041009zzz000',
    smoke_date   => '2024-08-01T12:00:00Z',
    report_hash  => 'ddd222',
    git_id       => 'ddd2',
    architecture => 'aarch64',
);

$data = $h->app->reports->latest;

my @delta = grep { $_->{hostname} eq 'delta' } @{ $data->{reports} };
is scalar @delta, 1, 'delta: exactly one row despite two reports at same (hostname, plevel, smoke_date)';
is $data->{report_count}, 4, 'four distinct hostnames after adding delta';

# Ordering: results should be plevel DESC, smoke_date DESC
my @plevels = map { $_->{plevel} } @{ $data->{reports} };
my @sorted  = sort { $b cmp $a } @plevels;
is_deeply \@plevels, \@sorted, 'results ordered by plevel DESC';

# Pagination
my $page1 = $h->app->reports->latest({ reports_per_page => 2, page => 1 });
is scalar @{ $page1->{reports} }, 2, 'page 1 has 2 reports';
is $page1->{report_count}, 4, 'total count unaffected by pagination';

my $page2 = $h->app->reports->latest({ reports_per_page => 2, page => 2 });
is scalar @{ $page2->{reports} }, 2, 'page 2 has remaining 2 reports';

done_testing;
