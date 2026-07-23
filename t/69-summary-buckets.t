use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use Test::Deep;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;

my $h = TestApp->new;
my $t = $h->t;
my $db = $h->app->sqlite->db;
my $reports = $h->app->reports;

my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, 'fixture ingested';
my $rid = $resp->{id};

# --- PASS-only baseline: summaries should contain only 'PASS' ----------------

{
    my $av = $reports->available_filter_values({});
    is_deeply $av->{summaries}, ['PASS'],
        'PASS-only DB yields single PASS bucket';
}

# --- Insert a FAIL(F) report to trigger bucketing ----------------------------
# Clone the row with a different git_id so report_hash is unique.

$db->query(<<~'SQL', $rid);
    INSERT INTO report (
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, git_id, git_describe, applied_patches,
        hostname, architecture, osname, osversion, cpu_count,
        cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        summary, smoke_branch, plevel, report_hash
    )
    SELECT
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, 'fake-git-id-fail-f', git_describe,
        applied_patches, hostname, architecture, osname, osversion,
        cpu_count, cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        'FAIL(F)', smoke_branch, plevel, 'hash-fail-f'
    FROM report WHERE id = ?
SQL

{
    my $av = $reports->available_filter_values({});
    cmp_deeply $av->{summaries},
        bag('PASS', 'FAIL(*)', 'FAIL(F)'),
        'FAIL(F) produces PASS + FAIL(*) umbrella + FAIL(F) specific';
}

# --- Add FAIL(XM): multi-letter, contributes FAIL(X) and FAIL(M) ------------

$db->query(<<~'SQL', $rid);
    INSERT INTO report (
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, git_id, git_describe, applied_patches,
        hostname, architecture, osname, osversion, cpu_count,
        cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        summary, smoke_branch, plevel, report_hash
    )
    SELECT
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, 'fake-git-id-fail-xm', git_describe,
        applied_patches, hostname, architecture, osname, osversion,
        cpu_count, cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        'FAIL(XM)', smoke_branch, plevel, 'hash-fail-xm'
    FROM report WHERE id = ?
SQL

{
    my $av = $reports->available_filter_values({});
    cmp_deeply $av->{summaries},
        bag('PASS', 'FAIL(*)', 'FAIL(F)', 'FAIL(M)', 'FAIL(X)'),
        'FAIL(XM) splits into per-letter buckets (deduped with prior FAIL(F))';
}

# --- Case sensitivity: FAIL(Mm) produces both uppercase M and lowercase m ----

$db->query(<<~'SQL', $rid);
    INSERT INTO report (
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, git_id, git_describe, applied_patches,
        hostname, architecture, osname, osversion, cpu_count,
        cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        summary, smoke_branch, plevel, report_hash
    )
    SELECT
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, 'fake-git-id-fail-mm', git_describe,
        applied_patches, hostname, architecture, osname, osversion,
        cpu_count, cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        'FAIL(Mm)', smoke_branch, plevel, 'hash-fail-mm'
    FROM report WHERE id = ?
SQL

{
    my $av = $reports->available_filter_values({});
    cmp_deeply $av->{summaries},
        bag('PASS', 'FAIL(*)', 'FAIL(F)', 'FAIL(M)', 'FAIL(X)', 'FAIL(m)'),
        'FAIL(Mm) adds lowercase m distinct from uppercase M';
}

# --- Ordering: PASS first, FAIL(*) second, specific FAILs, then unknowns ----

{
    my $av = $reports->available_filter_values({});
    my @s = @{ $av->{summaries} };
    is $s[0], 'PASS', 'PASS sorts first';
    is $s[1], 'FAIL(*)', 'FAIL(*) sorts second';

    my @fails = grep { /^FAIL\([^*]/ } @s;
    is_deeply \@fails, [sort @fails],
        'specific FAIL letters are sorted lexically';
}

# --- Add UNKNOWN summary: passes through verbatim, sorts last ---------------

$db->query(<<~'SQL', $rid);
    INSERT INTO report (
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, git_id, git_describe, applied_patches,
        hostname, architecture, osname, osversion, cpu_count,
        cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        summary, smoke_branch, plevel, report_hash
    )
    SELECT
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, 'fake-git-id-unknown', git_describe,
        applied_patches, hostname, architecture, osname, osversion,
        cpu_count, cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        'UNKNOWN', smoke_branch, plevel, 'hash-unknown'
    FROM report WHERE id = ?
SQL

{
    my $av = $reports->available_filter_values({});
    my @s = @{ $av->{summaries} };
    is $s[-1], 'UNKNOWN', 'non-PASS/FAIL summaries sort last';
    ok( (grep { $_ eq 'UNKNOWN' } @s), 'UNKNOWN passes through verbatim');
}

# --- Hostname sorting is case-insensitive ------------------------------------
# Insert a report from a host whose name sorts differently by case.

$db->query(<<~'SQL', $rid);
    INSERT INTO report (
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, git_id, git_describe, applied_patches,
        hostname, architecture, osname, osversion, cpu_count,
        cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        summary, smoke_branch, plevel, report_hash
    )
    SELECT
        sconfig_id, duration, config_count, reporter, reporter_version,
        smoke_perl, smoke_revision, smoke_version, smoker_version,
        smoke_date, perl_id, 'fake-git-id-host', git_describe,
        applied_patches, 'Asterix', architecture, osname, osversion,
        cpu_count, cpu_description, username, test_jobs, lc_all, lang,
        user_note, skipped_tests, harness_only, harness3opts,
        'PASS', smoke_branch, plevel, 'hash-host'
    FROM report WHERE id = ?
SQL

{
    my $av = $reports->available_filter_values({});
    my @hosts = @{ $av->{hostnames} };
    ok scalar @hosts >= 2, 'at least two hostnames present';
    my @lc = map { lc } @hosts;
    is_deeply \@lc, [sort @lc],
        'hostnames are sorted case-insensitively';
}

done_testing;
