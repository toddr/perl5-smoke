use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use File::Temp  qw(tempdir);
use DBI;

my $script  = "$FindBin::Bin/../script/import-from-pgdump";
my $fixture = "$FindBin::Bin/data/mini-pgdump.sql";

-x $script  or plan skip_all => "import-from-pgdump not executable";
-r $fixture or plan skip_all => "mini-pgdump.sql fixture missing";

my $tmpdir = tempdir(CLEANUP => 1);
my $db     = "$tmpdir/import-test.db";

subtest 'first import succeeds' => sub {
    my $out = `$^X $script --source $fixture --target $db 2>&1`;
    my $rc  = $? >> 8;
    is $rc, 0, 'exit code 0' or diag $out;

    like $out, qr/\[migrate\] schema applied/,     'schema applied';
    like $out, qr/public\.smoke_config:\s*2 rows/,  'smoke_config: 2 rows';
    like $out, qr/public\.report:\s*2 rows/,         'report: 2 rows';
    like $out, qr/public\.config:\s*2 rows/,         'config: 2 rows';
    like $out, qr/public\.result:\s*2 rows/,         'result: 2 rows';
    like $out, qr/public\.failure:\s*1 rows/,        'failure: 1 row';
    like $out, qr/public\.failures_for_env:\s*1 rows/, 'failures_for_env: 1 row';
    like $out, qr/tsgateway_config.*handled by migration/i, 'tsgateway_config skipped';
};

my $dbh = DBI->connect("dbi:SQLite:dbname=$db", undef, undef,
    { RaiseError => 1, AutoCommit => 1 });

subtest 'row counts match' => sub {
    for my $pair (
        [ smoke_config     => 2 ],
        [ report           => 2 ],
        [ config           => 2 ],
        [ result           => 2 ],
        [ failure          => 1 ],
        [ failures_for_env => 1 ],
    ) {
        my ($tbl, $want) = @$pair;
        my ($got) = $dbh->selectrow_array("SELECT COUNT(*) FROM $tbl");
        is $got, $want, "$tbl: $want rows";
    }
};

subtest 'report data fidelity' => sub {
    my $r1 = $dbh->selectrow_hashref("SELECT * FROM report WHERE id = 1");
    is $r1->{sconfig_id},    1,                          'sconfig_id preserved';
    is $r1->{hostname},      'testhost',                 'hostname preserved';
    is $r1->{architecture},  'x86_64/linux',             'architecture preserved';
    is $r1->{summary},       'PASS',                     'summary preserved';
    is $r1->{smoke_branch},  'blead',                    'smoke_branch preserved';
    is $r1->{git_describe},  'v5.42.0',                  'git_describe preserved';
    like $r1->{smoke_date},  qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
        'smoke_date is ISO 8601 UTC';
    is $r1->{smoke_date},    '2024-06-15T12:30:00Z',     'timezone offset +02 applied';
    ok defined $r1->{plevel},                             'plevel computed';
    ok defined $r1->{report_hash},                        'report_hash computed';
    like $r1->{report_hash}, qr/^[a-f0-9]{32}$/,         'report_hash is md5 hex';
};

subtest 'second report: tab in user_note decoded' => sub {
    my $r2 = $dbh->selectrow_hashref("SELECT * FROM report WHERE id = 2");
    like $r2->{user_note}, qr/\t/, 'backslash-t decoded to literal tab';
    is $r2->{smoke_date},  '2024-06-16T09:00:00Z', 'UTC+00 timestamp preserved';
    is $r2->{summary},     'FAIL(F)',               'FAIL summary preserved';
};

subtest 'config timestamps converted' => sub {
    my $c1 = $dbh->selectrow_hashref("SELECT * FROM config WHERE id = 1");
    is $c1->{started}, '2024-06-15T11:00:00Z', 'config.started +02 converted';
    is $c1->{cc},      'gcc',                  'cc preserved';

    my $c2 = $dbh->selectrow_hashref("SELECT * FROM config WHERE id = 2");
    is $c2->{started}, '2024-06-16T08:30:00Z', 'config.started +00 converted';
};

subtest 'failure chain intact' => sub {
    my $f = $dbh->selectrow_hashref("SELECT * FROM failure WHERE id = 1");
    is $f->{test},   't/op/die.t', 'failure test name';
    is $f->{status}, 'FAILED',     'failure status';

    my ($link) = $dbh->selectrow_array(
        "SELECT COUNT(*) FROM failures_for_env WHERE result_id = 2 AND failure_id = 1");
    is $link, 1, 'failures_for_env link present';
};

subtest 'sqlite_sequence bumped' => sub {
    my ($seq) = $dbh->selectrow_array(
        "SELECT seq FROM sqlite_sequence WHERE name = 'report'");
    is $seq, 2, 'report sequence at max(id)';
};

subtest 'pragmas restored' => sub {
    my ($jm) = $dbh->selectrow_array("PRAGMA journal_mode");
    is $jm, 'wal', 'journal_mode set to WAL';
};

$dbh->disconnect;

subtest 'resumability: second import is a no-op' => sub {
    my $out = `$^X $script --source $fixture --target $db 2>&1`;
    my $rc  = $? >> 8;
    is $rc, 0, 'second import exits cleanly (INSERT OR IGNORE)' or diag $out;

    my $dbh2 = DBI->connect("dbi:SQLite:dbname=$db", undef, undef,
        { RaiseError => 1, AutoCommit => 1 });
    my ($cnt) = $dbh2->selectrow_array("SELECT COUNT(*) FROM report");
    is $cnt, 2, 'row count unchanged after re-import';
    $dbh2->disconnect;
};

subtest 'fresh flag replaces existing DB' => sub {
    my $out = `$^X $script --source $fixture --target $db --fresh 2>&1`;
    my $rc  = $? >> 8;
    is $rc, 0, '--fresh import succeeds' or diag $out;
    like $out, qr/\[fresh\]/, 'fresh flag acknowledged';

    my $dbh2 = DBI->connect("dbi:SQLite:dbname=$db", undef, undef,
        { RaiseError => 1, AutoCommit => 1 });
    my ($cnt) = $dbh2->selectrow_array("SELECT COUNT(*) FROM report");
    is $cnt, 2, 'same rows after fresh reimport';
    $dbh2->disconnect;
};

done_testing;
