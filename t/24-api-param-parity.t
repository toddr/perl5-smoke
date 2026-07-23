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
        $args{perl_id}      // '5.42.0',
        $args{git_id}       // 'abc123',
        $args{git_describe} // 'v5.42.0-1-gabc123',
        $args{hostname},
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.5',
        $args{summary},
        $args{smoke_branch} // 'blead',
        $args{plevel}       // '5.042000zzz000',
        $args{report_hash},
    );
    return $db->dbh->last_insert_id(undef, undef, 'report', undef);
}

# Seed: 2 PASS, 1 FAIL on the same host at different plevels
insert_report(
    hostname    => 'host-a',
    summary     => 'PASS',
    plevel      => '5.042000zzz002',
    smoke_date  => '2024-06-03T10:00:00Z',
    report_hash => 'parity_p1',
    git_id      => 'p1',
);
insert_report(
    hostname    => 'host-b',
    summary     => 'PASS',
    plevel      => '5.042000zzz001',
    smoke_date  => '2024-06-02T10:00:00Z',
    report_hash => 'parity_p2',
    git_id      => 'p2',
);
insert_report(
    hostname    => 'host-c',
    summary     => 'FAIL(F)',
    plevel      => '5.042000zzz000',
    smoke_date  => '2024-06-01T10:00:00Z',
    report_hash => 'parity_f1',
    git_id      => 'f1',
);

# =========================================================================
# /api/latest: selected_summary filter
# =========================================================================

subtest '/api/latest selected_summary=pass' => sub {
    $t->get_ok('/api/latest?selected_summary=pass')
      ->status_is(200)
      ->json_is('/report_count' => 2);
    my $reports = $t->tx->res->json->{reports};
    ok !(grep { $_->{summary} =~ /^FAIL/ } @$reports), 'no FAIL in pass filter';
};

subtest '/api/latest selected_summary=fail' => sub {
    $t->get_ok('/api/latest?selected_summary=fail')
      ->status_is(200)
      ->json_is('/report_count' => 1);
    my $reports = $t->tx->res->json->{reports};
    like $reports->[0]{summary}, qr/^FAIL/, 'only FAIL in fail filter';
};

subtest '/api/latest no filter returns all' => sub {
    $t->get_ok('/api/latest')
      ->status_is(200)
      ->json_is('/report_count' => 3);
};

# JSONRPC parity
subtest 'JSONRPC latest selected_summary=pass' => sub {
    my $res = $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 1,
        method  => 'latest',
        params  => { selected_summary => 'pass' },
    })->status_is(200)->tx->res->json;
    is $res->{result}{report_count}, 2, 'JSONRPC latest pass filter';
};

subtest 'JSONRPC latest selected_summary=fail' => sub {
    my $res = $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 2,
        method  => 'latest',
        params  => { selected_summary => 'fail' },
    })->status_is(200)->tx->res->json;
    is $res->{result}{report_count}, 1, 'JSONRPC latest fail filter';
};

# =========================================================================
# /api/matrix: include_stdio filter
# =========================================================================

# Seed matrix data: one failure linked to perlio, one to stdio
my $rid = insert_report(
    hostname    => 'matrix-host',
    summary     => 'FAIL(F)',
    plevel      => '5.042000zzz010',
    smoke_date  => '2024-07-01T10:00:00Z',
    report_hash => 'parity_mat1',
    git_id      => 'mat1',
);

$db->query("INSERT INTO config (report_id, arguments, debugging) VALUES (?, '', 'N')", $rid);
my $cid = $db->dbh->last_insert_id(undef, undef, 'config', undef);

$db->query("INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F')", $cid);
my $perlio_resid = $db->dbh->last_insert_id(undef, undef, 'result', undef);

$db->query("INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'F')", $cid);
my $stdio_resid = $db->dbh->last_insert_id(undef, undef, 'result', undef);

$db->query("INSERT INTO failure (test, status, extra) VALUES ('op/taint.t', 'FAILED', '')");
my $fid_perlio = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

$db->query("INSERT INTO failure (test, status, extra) VALUES ('io/pipe.t', 'FAILED', '')");
my $fid_stdio = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)", $perlio_resid, $fid_perlio);
$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)", $stdio_resid, $fid_stdio);

subtest '/api/matrix default excludes stdio' => sub {
    $t->get_ok('/api/matrix')->status_is(200);
    my $rows = $t->tx->res->json->{rows};
    my @tests = map { $_->{test} } @$rows;
    ok( (grep { $_ eq 'op/taint.t' } @tests), 'perlio failure present');
    ok(!(grep { $_ eq 'io/pipe.t'  } @tests), 'stdio failure excluded by default');
};

subtest '/api/matrix include_stdio=1' => sub {
    $t->get_ok('/api/matrix?include_stdio=1')->status_is(200);
    my $rows = $t->tx->res->json->{rows};
    my @tests = map { $_->{test} } @$rows;
    ok( (grep { $_ eq 'op/taint.t' } @tests), 'perlio failure present');
    ok( (grep { $_ eq 'io/pipe.t'  } @tests), 'stdio failure included');
};

subtest 'JSONRPC matrix default excludes stdio' => sub {
    my $res = $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 10,
        method  => 'matrix',
    })->status_is(200)->tx->res->json;
    my @tests = map { $_->{test} } @{ $res->{result}{rows} };
    ok(!(grep { $_ eq 'io/pipe.t' } @tests), 'JSONRPC matrix excludes stdio by default');
};

subtest 'JSONRPC matrix include_stdio=1' => sub {
    my $res = $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 11,
        method  => 'matrix',
        params  => { include_stdio => 1 },
    })->status_is(200)->tx->res->json;
    my @tests = map { $_->{test} } @{ $res->{result}{rows} };
    ok( (grep { $_ eq 'io/pipe.t' } @tests), 'JSONRPC matrix includes stdio when asked');
};

done_testing;
