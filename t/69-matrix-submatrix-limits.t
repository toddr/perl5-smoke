use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use CoreSmoke::Model::Matrix;
use Mojo::JSON qw(encode_json);

my $h  = TestApp->new;
my $t  = $h->t;
my $db = $h->app->sqlite->db;
my $m  = CoreSmoke::Model::Matrix->new(sqlite => $h->app->sqlite);

# Seed 6 reports with failures so submatrix returns multiple rows
my @rids;
for my $i (1..6) {
    $db->query(<<~'SQL',
        INSERT INTO report
            (perl_id, plevel, osname, osversion, hostname, architecture,
             git_id, git_describe, smoke_date, summary, report_hash)
        VALUES (?, ?, 'linux', '6.5', ?, 'x86_64',
                ?, ?, datetime('now'), 'FAIL', ?)
        SQL
        '5.42.0', '5.042000zzz000',
        "host-$i", "git$i", "v5.42.0-$i-ggit$i", "hash_limit_$i",
    );
    push @rids, $db->dbh->last_insert_id(undef, undef, 'report', undef);
}

my @cids;
for my $rid (@rids) {
    $db->query(
        "INSERT INTO config (report_id, arguments, debugging) VALUES (?, '', 'N')",
        $rid,
    );
    push @cids, $db->dbh->last_insert_id(undef, undef, 'config', undef);
}

my @result_ids;
for my $cid (@cids) {
    $db->query(
        "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F')",
        $cid,
    );
    push @result_ids, $db->dbh->last_insert_id(undef, undef, 'result', undef);
}

$db->query("INSERT INTO failure (test, status, extra) VALUES ('t/limit.t', 'FAILED', NULL)");
my $fid = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

for my $rid (@result_ids) {
    $db->query(
        "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
        $rid, $fid,
    );
}

# Also seed a stdio failure for include_stdio tests
$db->query("INSERT INTO failure (test, status, extra) VALUES ('t/stdio_only.t', 'FAILED', NULL)");
my $stdio_fid = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

$db->query(
    "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'F')",
    $cids[0],
);
my $stdio_rid = $db->dbh->last_insert_id(undef, undef, 'result', undef);
$db->query(
    "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
    $stdio_rid, $stdio_fid,
);

# =========================================================================
# submatrix limit tests (model layer)
# =========================================================================

subtest 'submatrix default limit returns all when under cap' => sub {
    my $rows = $m->submatrix('t/limit.t');
    is scalar @$rows, 6, 'all 6 reports returned (under 500 cap)';
};

subtest 'submatrix explicit limit=3 caps output' => sub {
    my $rows = $m->submatrix('t/limit.t', undef, 3);
    is scalar @$rows, 3, 'only 3 reports returned';
};

subtest 'submatrix limit=0 treated as default' => sub {
    my $rows = $m->submatrix('t/limit.t', undef, 0);
    is scalar @$rows, 6, 'limit=0 falls back to 500 (returns all 6)';
};

subtest 'submatrix negative limit clamped to 1' => sub {
    my $rows = $m->submatrix('t/limit.t', undef, -5);
    is scalar @$rows, 1, 'negative limit clamped to 1';
};

# =========================================================================
# REST API: /api/submatrix?limit=N
# =========================================================================

subtest 'API submatrix default' => sub {
    $t->get_ok('/api/submatrix?test=t/limit.t')
      ->status_is(200)
      ->json_has('/0/id');
    my $json = $t->tx->res->json;
    is scalar @$json, 6, 'API returns all 6 by default';
};

subtest 'API submatrix with limit=2' => sub {
    $t->get_ok('/api/submatrix?test=t/limit.t&limit=2')
      ->status_is(200);
    my $json = $t->tx->res->json;
    is scalar @$json, 2, 'API returns 2 with limit=2';
};

# =========================================================================
# REST API: /api/matrix?include_stdio=1
# =========================================================================

subtest 'API matrix excludes stdio by default' => sub {
    $t->get_ok('/api/matrix')
      ->status_is(200);
    my $json = $t->tx->res->json;
    my @tests = map { $_->{test} } @{ $json->{rows} // [] };
    ok !(grep { $_ eq 't/stdio_only.t' } @tests),
        'stdio-only test excluded by default';
};

subtest 'API matrix includes stdio when requested' => sub {
    $t->get_ok('/api/matrix?include_stdio=1')
      ->status_is(200);
    my $json = $t->tx->res->json;
    my @tests = map { $_->{test} } @{ $json->{rows} // [] };
    ok(( grep { $_ eq 't/stdio_only.t' } @tests),
        'stdio-only test included with include_stdio=1');
};

# =========================================================================
# JSONRPC: matrix with include_stdio
# =========================================================================

subtest 'JSONRPC matrix excludes stdio by default' => sub {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 1,
        method => 'matrix', params => {},
    })->status_is(200);
    my $result = $t->tx->res->json->{result};
    my @tests = map { $_->{test} } @{ $result->{rows} // [] };
    ok !(grep { $_ eq 't/stdio_only.t' } @tests),
        'JSONRPC matrix excludes stdio by default';
};

subtest 'JSONRPC matrix includes stdio when requested' => sub {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 2,
        method => 'matrix', params => { include_stdio => 1 },
    })->status_is(200);
    my $result = $t->tx->res->json->{result};
    my @tests = map { $_->{test} } @{ $result->{rows} // [] };
    ok(( grep { $_ eq 't/stdio_only.t' } @tests),
        'JSONRPC matrix includes stdio when requested');
};

# =========================================================================
# JSONRPC: submatrix with limit
# =========================================================================

subtest 'JSONRPC submatrix with limit' => sub {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 3,
        method => 'submatrix', params => { test => 't/limit.t', limit => 2 },
    })->status_is(200);
    my $result = $t->tx->res->json->{result};
    is scalar @$result, 2, 'JSONRPC submatrix respects limit';
};

done_testing;
