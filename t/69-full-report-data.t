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

# Ingest the standard fixture and exercise full_report_data on the result.
my $resp    = $h->ingest_fixture('idefix-gff5bbe677.jsn');
my $rid     = $resp->{id};
my $reports = $h->app->reports;

# --- full_report_data returns all derived keys ---

subtest 'derived keys present' => sub {
    my $full = $reports->full_report_data($rid);
    ok defined $full, 'full_report_data returns data';
    for my $key (qw(
        c_compilers io_labels matrix_rows test_failures
        durations duration_in_hhmm average_in_hhmm
        has_log_file has_out_file authenticated
    )) {
        ok exists $full->{$key}, "key '$key' present";
    }
};

# --- Compiler deduplication ---

subtest 'c_compilers deduped' => sub {
    my $full = $reports->full_report_data($rid);
    my $cc   = $full->{c_compilers};
    is ref $cc, 'ARRAY', 'c_compilers is arrayref';
    is scalar @$cc, 1, 'one distinct compiler (both configs use same cc)';
    is $cc->[0]{cc}, 'cc', 'compiler name';
    like $cc->[0]{ccversion}, qr/LLVM/, 'compiler version';
};

# --- IO labels aggregated and sorted ---

subtest 'io_labels aggregated' => sub {
    my $full   = $reports->full_report_data($rid);
    my $labels = $full->{io_labels};
    is ref $labels, 'ARRAY', 'io_labels is arrayref';
    is scalar @$labels, 3, 'three distinct io labels';
    is $labels->[0], 'locale-nl_NL.UTF8', 'locale label includes locale name';
    is $labels->[1], 'perlio', 'perlio label';
    is $labels->[2], 'stdio', 'stdio label';
};

# --- Matrix rows ---

subtest 'matrix_rows structure' => sub {
    my $full = $reports->full_report_data($rid);
    my $rows = $full->{matrix_rows};
    is ref $rows, 'ARRAY', 'matrix_rows is arrayref';
    is scalar @$rows, 2, 'two matrix rows (one per config)';

    my $row0 = $rows->[0];
    ok exists $row0->{arguments}, 'row has arguments';
    ok exists $row0->{debugging}, 'row has debugging';
    ok exists $row0->{duration},  'row has duration';
    is ref $row0->{results}, 'ARRAY', 'row results is arrayref';
    is scalar @{$row0->{results}}, 3, 'three results per config';

    my $r = $row0->{results}[0];
    ok exists $r->{io_env},  'result has io_env';
    ok exists $r->{locale},  'result has locale';
    ok exists $r->{label},   'result has label';
    ok exists $r->{summary}, 'result has summary';
    is $r->{summary}, 'O', 'result summary is O (OK)';
};

# --- Test failures: PASS report has none ---

subtest 'test_failures empty for PASS report' => sub {
    my $full = $reports->full_report_data($rid);
    is ref $full->{test_failures}, 'ARRAY', 'test_failures is arrayref';
    is scalar @{$full->{test_failures}}, 0, 'no failures for PASS report';
};

# --- Duration calculations ---

subtest 'duration calculations' => sub {
    my $full  = $reports->full_report_data($rid);
    my $total = $full->{durations};
    is $total, 7900, 'total duration = 3800 + 4100';
    is $full->{duration_in_hhmm}, '2:11', 'formatted total: 2:11';
    is $full->{average_in_hhmm}, '1:05',  'formatted average: 1:05';
};

# --- On-disk file indicators ---

subtest 'on-disk file indicators' => sub {
    my $full = $reports->full_report_data($rid);
    is $full->{has_log_file}, 0, 'no log_file (fixture has null log)';
    is $full->{has_out_file}, 0, 'no out_file (fixture has null out)';
    like $full->{manifest_msgs_text}, qr/MANIFEST/,
        'manifest_msgs_text populated from disk';
    ok !defined $full->{compiler_msgs_text},
        'compiler_msgs_text undef (fixture has empty compiler_msgs)';
    ok !defined $full->{nonfatal_msgs_text},
        'nonfatal_msgs_text undef (fixture has empty nonfatal_msgs)';
};

# --- Token provenance on unauthenticated report ---

subtest 'unauthenticated report trust' => sub {
    my $full = $reports->full_report_data($rid);
    ok !${$full->{authenticated}}, 'authenticated is false (no token)';
    ok !defined $full->{api_token_id}, 'no api_token_id';
};

# --- Minimal report: only NOT NULL columns, no configs ---

subtest 'minimal report with no configs' => sub {
    my $db = $h->app->sqlite->db;
    $db->query(<<~'SQL',
        INSERT INTO report (
            smoke_date, perl_id, git_id, git_describe, hostname,
            architecture, osname, osversion, summary, plevel, report_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        '2024-01-01T00:00:00Z', '5.40.0', 'abc123', 'v5.40.0',
        'minimal-host', 'x86_64', 'linux', '6.1',
        'PASS', '5.040000zzz000', 'minimal_hash_value_001',
    );
    my $min_rid = $db->dbh->last_insert_id(undef, undef, 'report', undef);

    my $full = $reports->full_report_data($min_rid);
    ok defined $full, 'full_report_data succeeds for minimal report';
    is ref $full->{c_compilers}, 'ARRAY', 'c_compilers present';
    is scalar @{$full->{c_compilers}}, 0, 'no compilers for config-less report';
    is ref $full->{matrix_rows}, 'ARRAY', 'matrix_rows present';
    is scalar @{$full->{matrix_rows}}, 0, 'no matrix rows';
    is ref $full->{test_failures}, 'ARRAY', 'test_failures present';
    is scalar @{$full->{test_failures}}, 0, 'no failures';
    is $full->{durations}, 0, 'zero total duration';
    is $full->{duration_in_hhmm}, '0:00', 'formatted zero duration';
    is $full->{average_in_hhmm}, '0:00', 'formatted zero average';
};

# --- Report with test failures: grouping and deduplication ---

subtest 'failure grouping across configs' => sub {
    my $db = $h->app->sqlite->db;

    $db->query(<<~'SQL',
        INSERT INTO report (
            smoke_date, perl_id, git_id, git_describe, hostname,
            architecture, osname, osversion, summary, plevel, report_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        '2024-06-15T12:00:00Z', '5.41.1', 'def456', 'v5.41.1-5-gdef456',
        'fail-host', 'x86_64', 'linux', '6.5',
        'FAIL(F)', '5.041001zzz000', 'fail_hash_value_001',
    );
    my $fail_rid = $db->dbh->last_insert_id(undef, undef, 'report', undef);

    # Two configs, both hitting the same failing test
    for my $debug (qw(N D)) {
        $db->query(
            "INSERT INTO config (report_id, arguments, debugging, cc, ccversion) VALUES (?, ?, ?, ?, ?)",
            $fail_rid, '', $debug, 'gcc', '13.2',
        );
        my $cid = $db->dbh->last_insert_id(undef, undef, 'config', undef);

        $db->query(
            "INSERT INTO result (config_id, io_env, summary) VALUES (?, ?, ?)",
            $cid, 'perlio', 'F',
        );
        my $resid = $db->dbh->last_insert_id(undef, undef, 'result', undef);

        my $fid = $db->query(<<~'SQL', 't/op/taint.t', 'FAILED', 'signal 11')->hash->{id};
            INSERT INTO failure (test, status, extra)
            VALUES (?, ?, ?)
            ON CONFLICT(test, status, extra) DO UPDATE SET test = test
            RETURNING id
            SQL

        $db->query(
            "INSERT OR IGNORE INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
            $resid, $fid,
        );
    }

    my $full = $reports->full_report_data($fail_rid);
    ok defined $full, 'full_report_data for failing report';

    my $failures = $full->{test_failures};
    is ref $failures, 'ARRAY', 'test_failures is arrayref';
    is scalar @$failures, 1, 'one distinct test failure (deduped across configs)';

    my $f = $failures->[0];
    is $f->{test},   't/op/taint.t', 'failure test name';
    is $f->{status}, 'FAILED',       'failure status';
    is $f->{extra},  'signal 11',    'failure extra';
    is ref $f->{configs}, 'ARRAY', 'failure configs is arrayref';
    is scalar @{$f->{configs}}, 2, 'two config entries for the same failure';
};

done_testing;
