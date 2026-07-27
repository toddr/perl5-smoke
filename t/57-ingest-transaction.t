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
my $db = $h->app->sqlite->db;

my $base = $h->fixture('idefix-gff5bbe677.jsn');

# --- Test: successful ingest is fully atomic ---
{
    my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
    ok $resp->{id}, 'happy-path ingest returns id';

    my $report = $db->query("SELECT id FROM report WHERE id = ?", $resp->{id})->hash;
    ok $report, 'report row committed';

    my $cfg_count = $db->query(
        "SELECT COUNT(*) AS c FROM config WHERE report_id = ?", $resp->{id}
    )->hash->{c};
    ok $cfg_count > 0, "configs committed ($cfg_count rows)";

    my $res_count = $db->query(<<~'SQL', $resp->{id})->hash->{c};
        SELECT COUNT(*) AS c FROM result r
        JOIN config c ON c.id = r.config_id
        WHERE c.report_id = ?
        SQL
    ok $res_count > 0, "results committed ($res_count rows)";
}

# --- Test: failed sub-insert rolls back the entire transaction ---
# Craft a payload where a failure entry has test=undef (NOT NULL violation).
# The report row must NOT survive.
{
    my %bad = %$base;
    $bad{sysinfo} = { %{$base->{sysinfo}}, hostname => 'rollback-test' };
    $bad{configs} = [
        {
            arguments  => '-Dusedevel',
            debugging  => 'N',
            cc         => 'gcc',
            ccversion  => '12.0',
            results    => [
                {
                    io_env  => 'perlio',
                    summary => 'PASS',
                    failures => [
                        { status => 'FAILED' },
                    ],
                },
            ],
        },
    ];

    my $before = $db->query("SELECT COUNT(*) AS c FROM report")->hash->{c};

    my $died = !eval {
        $h->app->ingest->post_report(\%bad);
        1;
    };
    ok $died, 'post_report dies on NOT NULL violation in failure insert';

    my $after = $db->query("SELECT COUNT(*) AS c FROM report")->hash->{c};
    is $after, $before, 'report row rolled back (no orphaned row)';

    my $orphan = $db->query(
        "SELECT id FROM report WHERE hostname = ?", 'rollback-test'
    )->hash;
    is $orphan, undef, 'no orphaned report row with hostname rollback-test';
}

# --- Test: duplicate failures within one ingest are deduplicated ---
{
    my %dup = %$base;
    $dup{sysinfo} = { %{$base->{sysinfo}}, hostname => 'dedup-test' };
    $dup{configs} = [
        {
            arguments  => '-Dusedevel',
            debugging  => 'N',
            cc         => 'gcc',
            ccversion  => '12.0',
            results    => [
                {
                    io_env  => 'perlio',
                    summary => 'FAIL(F)',
                    failures => [
                        { test => 'op/basic.t', status => 'FAILED', extra => '' },
                        { test => 'op/basic.t', status => 'FAILED', extra => '' },
                    ],
                },
            ],
        },
    ];

    my $resp = $h->app->ingest->post_report(\%dup);
    ok $resp->{id}, 'duplicate-failure payload ingests successfully';

    my $fail_dedup = $db->query(
        "SELECT COUNT(*) AS c FROM failure WHERE test = 'op/basic.t' AND status = 'FAILED'"
    )->hash->{c};
    is $fail_dedup, 1, 'duplicate failures within one ingest are deduplicated';
}

done_testing;
