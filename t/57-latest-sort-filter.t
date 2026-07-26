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
        $args{perl_id},
        $args{git_id}       // 'abc123',
        $args{git_describe} // 'v5.41.9-1-gabc123',
        $args{hostname}     // 'testhost',
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.1',
        $args{summary},
        $args{smoke_branch} // 'blead',
        $args{plevel},
        $args{report_hash},
    );
}

# ---- _sort_perl_ids_desc ----

subtest '_sort_perl_ids_desc - basic ordering' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(
        [qw(5.38.0  5.41.9  5.40.0  5.42.0  5.39.1)]
    );
    is_deeply $sorted, [qw(5.42.0  5.41.9  5.40.0  5.39.1  5.38.0)],
        'sorts major.minor.patch descending numerically';
};

subtest '_sort_perl_ids_desc - minor version >9' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(
        [qw(5.9.5  5.10.0  5.10.1  5.8.9)]
    );
    is_deeply $sorted, [qw(5.10.1  5.10.0  5.9.5  5.8.9)],
        '5.10.x sorts higher than 5.9.x (numeric, not lexical)';
};

subtest '_sort_perl_ids_desc - patch >9' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(
        [qw(5.41.9  5.41.10  5.41.2)]
    );
    is_deeply $sorted, [qw(5.41.10  5.41.9  5.41.2)],
        '5.41.10 > 5.41.9 (numeric comparison on patch)';
};

subtest '_sort_perl_ids_desc - two-part versions' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(
        [qw(5.41  5.41.9  5.42)]
    );
    is_deeply $sorted, [qw(5.42  5.41.9  5.41)],
        'two-part versions padded with 0: 5.41 = 5.41.0 < 5.41.9';
};

subtest '_sort_perl_ids_desc - single element' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(['5.40.0']);
    is_deeply $sorted, ['5.40.0'], 'single element returned as-is';
};

subtest '_sort_perl_ids_desc - empty list' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc([]);
    is_deeply $sorted, [], 'empty list returns empty';
};

# ---- latest_perl_id ----

subtest 'latest_perl_id - returns highest version' => sub {
    insert_report(
        perl_id     => '5.40.0',
        plevel      => '5.040000zzz000',
        smoke_date  => '2024-01-01T10:00:00Z',
        summary     => 'PASS',
        report_hash => 'lpi_aaa',
        git_id      => 'lpi1',
    );
    insert_report(
        perl_id     => '5.42.0',
        plevel      => '5.042000zzz000',
        smoke_date  => '2024-02-01T10:00:00Z',
        summary     => 'PASS',
        report_hash => 'lpi_bbb',
        git_id      => 'lpi2',
    );
    insert_report(
        perl_id     => '5.41.9',
        plevel      => '5.041009zzz000',
        smoke_date  => '2024-03-01T10:00:00Z',
        summary     => 'PASS',
        report_hash => 'lpi_ccc',
        git_id      => 'lpi3',
    );

    is $h->app->reports->latest_perl_id, '5.42.0',
        'returns 5.42.0 as highest (numeric sort, not lexical)';
};

# ---- latest() with selected_summary ----

subtest 'latest summary filter - pass only' => sub {
    # Clear and insert controlled data: three hosts, different summaries.
    TestApp::reset_db();
    $h = TestApp->new;
    $t = $h->t;
    $db = $h->app->sqlite->db;

    insert_report(
        hostname    => 'pass-host',
        perl_id     => '5.42.0',
        plevel      => '5.042000zzz000',
        smoke_date  => '2024-06-01T10:00:00Z',
        summary     => 'PASS',
        report_hash => 'sf_pass1',
        git_id      => 'sf1',
    );
    insert_report(
        hostname    => 'fail-host',
        perl_id     => '5.42.0',
        plevel      => '5.042000zzz000',
        smoke_date  => '2024-06-02T10:00:00Z',
        summary     => 'FAIL(F)',
        report_hash => 'sf_fail1',
        git_id      => 'sf2',
    );
    insert_report(
        hostname    => 'failm-host',
        perl_id     => '5.42.0',
        plevel      => '5.042000zzz000',
        smoke_date  => '2024-06-03T10:00:00Z',
        summary     => 'FAIL(mM)',
        report_hash => 'sf_failm',
        git_id      => 'sf3',
    );

    my $all = $h->app->reports->latest;
    is $all->{report_count}, 3, 'unfiltered: 3 hosts';

    my $pass = $h->app->reports->latest({ selected_summary => 'pass' });
    is $pass->{report_count}, 1, 'pass filter: only 1 host';
    is $pass->{reports}[0]{hostname}, 'pass-host', 'pass filter: correct host';

    my $fail = $h->app->reports->latest({ selected_summary => 'fail' });
    is $fail->{report_count}, 2, 'fail filter: 2 hosts (FAIL(F) + FAIL(mM))';
    my @fail_hosts = sort map { $_->{hostname} } @{ $fail->{reports} };
    is_deeply \@fail_hosts, ['fail-host', 'failm-host'],
        'fail filter: correct hosts';
};

subtest 'latest summary filter - case insensitive input' => sub {
    my $upper = $h->app->reports->latest({ selected_summary => 'PASS' });
    is $upper->{report_count}, 1, 'PASS (uppercase) also matches';

    my $mixed = $h->app->reports->latest({ selected_summary => 'Fail' });
    is $mixed->{report_count}, 2, 'Fail (mixed case) also matches';
};

subtest 'latest summary filter - unknown value treated as all' => sub {
    my $bogus = $h->app->reports->latest({ selected_summary => 'bogus' });
    is $bogus->{report_count}, 3,
        'unknown summary value returns all (no filter applied)';
};

subtest 'latest summary filter - pagination count respects filter' => sub {
    my $data = $h->app->reports->latest({
        selected_summary => 'pass',
        reports_per_page => 1,
        page             => 1,
    });
    is $data->{report_count}, 1,
        'total count reflects filter, not all rows';
    is scalar @{ $data->{reports} }, 1,
        'page size applied after filter';
};

# ---- Web endpoint filter behaviour ----

subtest '/latest?selected_summary=pass - web returns only PASS rows' => sub {
    $t->get_ok('/latest?selected_summary=pass')
      ->status_is(200)
      ->content_like(qr/pass-host/,      'PASS host visible')
      ->content_unlike(qr/fail-host/,    'FAIL host not shown')
      ->content_unlike(qr/failm-host/,   'FAIL(mM) host not shown');
};

subtest '/latest?selected_summary=fail - web returns only FAIL rows' => sub {
    $t->get_ok('/latest?selected_summary=fail')
      ->status_is(200)
      ->content_like(qr/fail-host/,      'FAIL host visible')
      ->content_like(qr/failm-host/,     'FAIL(mM) host visible')
      ->content_unlike(qr/pass-host/,    'PASS host not shown');
};

done_testing;
