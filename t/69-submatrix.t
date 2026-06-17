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

my $h  = TestApp->new;
my $t  = $h->t;
my $db = $h->app->sqlite->db;
my $m  = CoreSmoke::Model::Matrix->new(sqlite => $h->app->sqlite);

# ---------------------------------------------------------------------------
# Seed: two reports with perlio + stdio results and distinct failures
# ---------------------------------------------------------------------------
#   Report 1: v5.42.0 on linux-6.5 (perlio + stdio)
#   Report 2: v5.40.0 on darwin-23 (perlio + stdio)
#
#   op/magic.t  FAILED via perlio results in both reports
#   io/stdio.t  FAILED via stdio  results in both reports

my @reports = (
    {
        perl_id  => 'v5.42.0', plevel => '5.042000',
        osname   => 'linux',   osversion => '6.5',
        hostname => 'build-a', architecture => 'x86_64',
        git_id   => 'aaa1111', git_describe => 'v5.42.0-1-gaaa1111',
        smoke_date => '2025-01-15 10:00:00',
    },
    {
        perl_id  => 'v5.40.0', plevel => '5.040000',
        osname   => 'darwin',  osversion => '23.0',
        hostname => 'mac-ci',  architecture => 'arm64',
        git_id   => 'bbb2222', git_describe => 'v5.40.0-1-gbbb2222',
        smoke_date => '2025-01-14 10:00:00',
    },
);

my @rids;
for my $r (@reports) {
    $db->query(<<~'SQL',
        INSERT INTO report
            (perl_id, plevel, osname, osversion, hostname, architecture,
             git_id, git_describe, smoke_date, summary, report_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'FAIL', ?)
        SQL
        $r->{perl_id}, $r->{plevel}, $r->{osname}, $r->{osversion},
        $r->{hostname}, $r->{architecture}, $r->{git_id}, $r->{git_describe},
        $r->{smoke_date}, $r->{git_id} . '_hash',
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

my (@perlio_rids, @stdio_rids);
for my $cid (@cids) {
    $db->query(
        "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'perlio', 'F')",
        $cid,
    );
    push @perlio_rids, $db->dbh->last_insert_id(undef, undef, 'result', undef);

    $db->query(
        "INSERT INTO result (config_id, io_env, summary) VALUES (?, 'stdio', 'F')",
        $cid,
    );
    push @stdio_rids, $db->dbh->last_insert_id(undef, undef, 'result', undef);
}

my %fid;
for my $f (['op/magic.t', 'FAILED', undef],
           ['io/stdio.t', 'FAILED', undef]) {
    $db->query(
        "INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)",
        @$f,
    );
    $fid{ $f->[0] } = $db->dbh->last_insert_id(undef, undef, 'failure', undef);
}

# op/magic.t -> perlio results (both reports)
for my $idx (0, 1) {
    $db->query(
        "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
        $perlio_rids[$idx], $fid{'op/magic.t'},
    );
}

# io/stdio.t -> stdio results (both reports)
for my $idx (0, 1) {
    $db->query(
        "INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
        $stdio_rids[$idx], $fid{'io/stdio.t'},
    );
}

# =========================================================================
# Model: submatrix default excludes stdio
# =========================================================================

subtest 'model: perlio test visible by default' => sub {
    my $rows = $m->submatrix('op/magic.t');
    is scalar @$rows, 2, 'op/magic.t returns 2 reports (perlio only)';
    ok exists $rows->[0]{smoke_date}, 'smoke_date included in output';
};

subtest 'model: stdio-only test hidden by default' => sub {
    my $rows = $m->submatrix('io/stdio.t');
    is scalar @$rows, 0, 'io/stdio.t returns 0 when stdio excluded';
};

subtest 'model: include_stdio shows stdio failures' => sub {
    my $rows = $m->submatrix('io/stdio.t', undef, include_stdio => 1);
    is scalar @$rows, 2, 'io/stdio.t returns 2 with include_stdio';
};

subtest 'model: pversion filter' => sub {
    my $rows = $m->submatrix('op/magic.t', 'v5.42.0');
    is scalar @$rows, 1, 'pversion filter narrows to 1 report';
    is $rows->[0]{perl_id}, 'v5.42.0', 'correct perl_id in result';
};

subtest 'model: order is plevel DESC, smoke_date DESC' => sub {
    my $rows = $m->submatrix('op/magic.t');
    is $rows->[0]{perl_id}, 'v5.42.0', 'higher plevel first';
    is $rows->[1]{perl_id}, 'v5.40.0', 'lower plevel second';
};

# =========================================================================
# Web routes: /submatrix
# =========================================================================

subtest 'web: submatrix without test param' => sub {
    $t->get_ok('/submatrix')
      ->status_is(200)
      ->content_like(qr/Missing test parameter/);
};

subtest 'web: submatrix with perlio test' => sub {
    $t->get_ok('/submatrix?test=op/magic.t')
      ->status_is(200)
      ->content_like(qr/op\/magic\.t/)
      ->content_like(qr/v5\.42\.0/)
      ->content_like(qr/v5\.40\.0/);
};

subtest 'web: submatrix excludes stdio by default' => sub {
    $t->get_ok('/submatrix?test=io/stdio.t')
      ->status_is(200)
      ->content_like(qr/No matching reports/);
};

subtest 'web: submatrix with include_stdio' => sub {
    $t->get_ok('/submatrix?test=io/stdio.t&include_stdio=1')
      ->status_is(200)
      ->content_unlike(qr/No matching reports/);
};

# =========================================================================
# API routes: /api/submatrix
# =========================================================================

subtest 'api: submatrix missing test' => sub {
    $t->get_ok('/api/submatrix')
      ->status_is(422)
      ->json_like('/error' => qr/Missing test/);
};

subtest 'api: submatrix perlio default' => sub {
    $t->get_ok('/api/submatrix?test=op/magic.t')
      ->status_is(200)
      ->json_has('/0')
      ->json_has('/1');
    is scalar @{ $t->tx->res->json }, 2, 'API returns 2 reports';
};

subtest 'api: submatrix excludes stdio by default' => sub {
    $t->get_ok('/api/submatrix?test=io/stdio.t')
      ->status_is(200);
    is scalar @{ $t->tx->res->json }, 0, 'stdio test returns 0 by default';
};

subtest 'api: submatrix with include_stdio' => sub {
    $t->get_ok('/api/submatrix?test=io/stdio.t&include_stdio=1')
      ->status_is(200);
    is scalar @{ $t->tx->res->json }, 2, 'include_stdio returns stdio failures';
};

subtest 'api: submatrix with pversion filter' => sub {
    $t->get_ok('/api/submatrix?test=op/magic.t&pversion=v5.42.0')
      ->status_is(200);
    my $json = $t->tx->res->json;
    is scalar @$json, 1, 'pversion filter returns 1';
    is $json->[0]{perl_id}, 'v5.42.0', 'correct perl_id';
};

done_testing;
