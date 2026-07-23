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

# ---------------------------------------------------------------------------
# Seed a rich report: FAIL summary, two compilers, four configs,
# failures, compiler messages on disk, user_note.
# ---------------------------------------------------------------------------

my $hash = 'deadbeef12345678deadbeef12345678';
$db->query(<<~'SQL',
    INSERT INTO report
        (perl_id, plevel, osname, osversion, hostname, architecture,
         git_id, git_describe, smoke_date, summary, smoke_branch,
         smoke_version, smoker_version, reporter, reporter_version,
         smoke_perl, username, user_note, cpu_count, cpu_description,
         duration, config_count, applied_patches, skipped_tests,
         harness_only, harness3opts, lc_all, lang,
         report_hash, smoke_revision)
    VALUES (?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?, ?, ?,
            ?, ?)
    SQL
    '5.41.9', '5.041009zzz000', 'linux', '6.8.0',
    'smokebot-01', 'x86_64',
    'aabbccdd', 'v5.41.9-42-gaabbccdd',
    '2025-06-15T08:30:00Z', 'FAIL(Fm)', 'blead',
    '1.80', '0.050', 'Test::Smoke', '0.054',
    '5.38.0', 'smoker', 'Bisected to abc1234; known flaky on ARM',
    '16', 'AMD EPYC 7763 64-Core',
    14400, 4,
    "patch1\npatch2", "t/skip/me.t",
    0, '--jobs=8', 'C', 'en_US.UTF-8',
    $hash, '1.80',
);
my $rid = $db->dbh->last_insert_id(undef, undef, 'report', undef);
ok $rid, "report inserted (id=$rid)";

# Two configs with different compilers
$db->query(
    "INSERT INTO config (report_id, arguments, debugging, duration, cc, ccversion) VALUES (?, ?, ?, ?, ?, ?)",
    $rid, '', 'N', 3600, 'gcc', '13.2.0',
);
my $cid1 = $db->dbh->last_insert_id(undef, undef, 'config', undef);

$db->query(
    "INSERT INTO config (report_id, arguments, debugging, duration, cc, ccversion) VALUES (?, ?, ?, ?, ?, ?)",
    $rid, '-Dusethreads', 'D', 3800, 'gcc', '13.2.0',
);
my $cid2 = $db->dbh->last_insert_id(undef, undef, 'config', undef);

$db->query(
    "INSERT INTO config (report_id, arguments, debugging, duration, cc, ccversion) VALUES (?, ?, ?, ?, ?, ?)",
    $rid, '', 'N', 3500, 'clang', '17.0.1',
);
my $cid3 = $db->dbh->last_insert_id(undef, undef, 'config', undef);

$db->query(
    "INSERT INTO config (report_id, arguments, debugging, duration, cc, ccversion) VALUES (?, ?, ?, ?, ?, ?)",
    $rid, '-Dusethreads', 'D', 3500, 'clang', '17.0.1',
);
my $cid4 = $db->dbh->last_insert_id(undef, undef, 'config', undef);

# Results: mix of O (pass), F (harness fail), m (make fail)
my @results = (
    [$cid1, 'perlio', undef,          'O'],
    [$cid1, 'locale', 'en_US.UTF-8',  'F'],
    [$cid2, 'perlio', undef,          'F'],
    [$cid2, 'locale', 'en_US.UTF-8',  'O'],
    [$cid3, 'perlio', undef,          'O'],
    [$cid3, 'locale', 'en_US.UTF-8',  'm'],
    [$cid4, 'perlio', undef,          'O'],
    [$cid4, 'locale', 'en_US.UTF-8',  'O'],
);
my @resids;
for my $r (@results) {
    $db->query(
        "INSERT INTO result (config_id, io_env, locale, summary) VALUES (?, ?, ?, ?)",
        @$r,
    );
    push @resids, $db->dbh->last_insert_id(undef, undef, 'result', undef);
}

# Failures on the F results (indices 1, 2)
$db->query(
    "INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)",
    'op/magic.t', 'FAILED', 'Failed test at op/magic.t line 42',
);
my $fid1 = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

$db->query(
    "INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)",
    'lib/warnings.t', 'FAILED', '',
);
my $fid2 = $db->dbh->last_insert_id(undef, undef, 'failure', undef);

$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)", $resids[1], $fid1);
$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)", $resids[2], $fid1);
$db->query("INSERT INTO failures_for_env (result_id, failure_id) VALUES (?, ?)", $resids[2], $fid2);

# Write report files (compiler_msgs, manifest_msgs) to disk
my $rf = $h->app->report_files;
$rf->write($hash, {
    compiler_msgs => "gcc: warning: implicit declaration of foo\nclang: note: expanded from macro BAR",
    manifest_msgs => "MANIFEST did not declare 'porting/bench.pl'",
});

# ---------------------------------------------------------------------------
# Test: full page renders with all five tab panels
# ---------------------------------------------------------------------------

subtest 'overview panel' => sub {
    $t->get_ok("/report/$rid")->status_is(200);

    $t->text_like('h1' => qr/Smoke report #\Q$rid\E/);

    $t->content_like(qr/5\.41\.9/,         'perl_id visible');
    $t->content_like(qr/v5\.41\.9-42/,     'git_describe visible');
    $t->content_like(qr/smokebot-01/,      'hostname visible');
    $t->content_like(qr/linux/,            'osname visible');
    $t->content_like(qr/6\.8\.0/,          'osversion visible');
    $t->content_like(qr/x86_64/,           'architecture visible');
    $t->content_like(qr/AMD EPYC/,         'cpu_description visible');
    $t->content_like(qr/blead/,            'smoke_branch visible');
    $t->content_like(qr/smoker/,           'username visible');

    # User note rendered as an alert
    $t->content_like(qr/Bisected to abc1234/, 'user_note rendered');

    # Trust badge: no api_token_id -> Unauthenticated
    $t->content_like(qr/Unauthenticated/, 'unauthenticated badge');

    # Status pill
    $t->element_exists('.badge-danger', 'FAIL summary has danger badge');
};

subtest 'matrix configurations panel' => sub {
    $t->get_ok("/report/$rid")->status_is(200);

    # Two distinct compilers in the overview <dl>
    $t->content_like(qr/gcc\s+13\.2\.0/,   'gcc compiler listed');
    $t->content_like(qr/clang\s+17\.0\.1/, 'clang compiler listed');

    # Matrix config rows: 4 configs rendered
    # Build args column: (default) and -Dusethreads
    $t->content_like(qr/-Dusethreads/,   '-Dusethreads arg in matrix');
    $t->content_like(qr/\(default\)/,    'default args shown');

    # Status cells: we have O, F, m chars
    $t->content_like(qr/<strong>O<\/strong>/, 'O (OK) status cell rendered');
    $t->content_like(qr/<strong>F<\/strong>/, 'F (harness fail) cell rendered');
    $t->content_like(qr/<strong>m<\/strong>/, 'm (make fail) cell rendered');

    # Duration column
    $t->content_like(qr/1h 0m 0s/,  'duration_hms for 3600s config');
};

subtest 'failures panel' => sub {
    $t->get_ok("/report/$rid")->status_is(200);

    # Two distinct failures seeded
    $t->content_like(qr/op\/magic\.t/,     'failure test name op/magic.t');
    $t->content_like(qr/lib\/warnings\.t/, 'failure test name lib/warnings.t');

    # Failure extra text
    $t->content_like(qr/Failed test at op\/magic\.t line 42/, 'failure extra rendered');

    # Submatrix link
    $t->content_like(qr{/submatrix\?test=}, 'submatrix link present');

    # Failure count in tab label
    $t->content_like(qr/Failures\s*\(2\)/, 'failure count in tab label');
};

subtest 'build messages panel' => sub {
    $t->get_ok("/report/$rid")->status_is(200);

    $t->content_like(qr/implicit declaration of foo/, 'compiler_msgs rendered');
    $t->content_like(qr/expanded from macro BAR/,    'compiler_msgs multi-line');
    $t->content_like(qr/MANIFEST did not declare/,   'manifest_msgs rendered');

    # Applied patches and skipped tests (stored as TEXT in report row)
    $t->content_like(qr/patch1/,       'applied_patches rendered');
    $t->content_like(qr/patch2/,       'applied_patches multi-value');
    $t->content_like(qr/t\/skip\/me\.t/, 'skipped_tests rendered');
};

subtest 'about this smoke panel' => sub {
    $t->get_ok("/report/$rid")->status_is(200);

    $t->content_like(qr/1\.80/,          'smoke_version visible');
    $t->content_like(qr/0\.050/,         'smoker_version visible');
    $t->content_like(qr/Test::Smoke/,    'reporter visible');
    $t->content_like(qr/0\.054/,         'reporter_version visible');
    $t->content_like(qr/en_US\.UTF-8/,   'LC_ALL or locale visible');
    $t->content_like(qr/--jobs=8/,       'harness3opts visible');
};

# ---------------------------------------------------------------------------
# Test: report with api_token shows Authenticated badge
# ---------------------------------------------------------------------------

subtest 'authenticated report shows trust badge' => sub {
    $db->query(
        "INSERT INTO api_token (token, note, email) VALUES (?, ?, ?)",
        'tok_test_full_report', 'CI bot', 'ci@example.com',
    );
    my $tok_id = $db->dbh->last_insert_id(undef, undef, 'api_token', undef);
    $db->query("UPDATE report SET api_token_id = ? WHERE id = ?", $tok_id, $rid);

    $t->get_ok("/report/$rid")->status_is(200)
      ->content_like(qr/Authenticated/, 'Authenticated badge shown')
      ->content_like(qr/CI bot/,        'token note shown');

    $db->query("UPDATE report SET api_token_id = NULL WHERE id = ?", $rid);
};

# ---------------------------------------------------------------------------
# Test: log_file and out_file links
# ---------------------------------------------------------------------------

subtest 'file links' => sub {
    # We wrote compiler_msgs but NOT log_file or out_file, so those routes
    # should return 404 while the report page should NOT show log/out links.
    $t->get_ok("/report/$rid")->status_is(200);

    # has_log_file / has_out_file should be false -> no btn_link for them
    $t->content_unlike(qr{href="/file/log_file/$rid"}, 'no log_file link when file absent');
    $t->content_unlike(qr{href="/file/out_file/$rid"}, 'no out_file link when file absent');

    # JSON link always present
    $t->content_like(qr{href="/api/full_report_data/$rid"}, 'JSON API link present');

    # Write a log_file and re-check
    $rf->write($hash, { log_file => "Build log content here" });
    $t->get_ok("/report/$rid")->status_is(200)
      ->content_like(qr{href="/file/log_file/$rid"}, 'log_file link appears after file written');

    $t->get_ok("/file/log_file/$rid")->status_is(200)
      ->content_like(qr/Build log content here/, 'log_file content served');
};

# ---------------------------------------------------------------------------
# Test: 404 for nonexistent report
# ---------------------------------------------------------------------------

subtest '404 for missing report' => sub {
    $t->get_ok('/report/99999')->status_is(404);
};

# ---------------------------------------------------------------------------
# Test: configurations count in tab label
# ---------------------------------------------------------------------------

subtest 'configs count in tab label' => sub {
    $t->get_ok("/report/$rid")->status_is(200)
      ->content_like(qr/Configurations &amp; results \(4\)/, '4 configs in tab label');
};

# ---------------------------------------------------------------------------
# Test: /submatrix web page renders with data from this report
# ---------------------------------------------------------------------------

subtest '/submatrix renders with matching failure' => sub {
    $t->get_ok('/submatrix?test=op/magic.t')->status_is(200)
      ->content_like(qr/Failures for.*op\/magic\.t/, 'test name in page title')
      ->content_like(qr/5\.41\.9/, 'perl_id in submatrix row')
      ->content_like(qr/smokebot-01/, 'hostname in submatrix row')
      ->content_like(qr/linux/, 'osname in submatrix row');
};

subtest '/submatrix filters by pversion' => sub {
    $t->get_ok('/submatrix?test=op/magic.t&pversion=5.41.9')->status_is(200)
      ->content_like(qr/smokebot-01/, 'matching pversion shows report');

    $t->get_ok('/submatrix?test=op/magic.t&pversion=5.99.0')->status_is(200)
      ->content_like(qr/No matching reports/, 'non-matching pversion shows empty state');
};

subtest '/submatrix without test param' => sub {
    $t->get_ok('/submatrix')->status_is(200)
      ->content_like(qr/Missing test parameter/, 'missing test shows help');
};

subtest '/submatrix with nonexistent test' => sub {
    $t->get_ok('/submatrix?test=no/such/test.t')->status_is(200)
      ->content_like(qr/No matching reports/, 'unknown test shows empty state');
};

# ---------------------------------------------------------------------------
# Test: /matrix web page renders heatmap with failure data
# ---------------------------------------------------------------------------

subtest '/matrix renders heatmap' => sub {
    $t->get_ok('/matrix')->status_is(200)
      ->content_like(qr/op\/magic\.t/,     'failing test in matrix')
      ->content_like(qr/lib\/warnings\.t/, 'second failing test in matrix')
      ->element_exists('.heatmap-cell',    'heatmap cells rendered');
};

done_testing;
