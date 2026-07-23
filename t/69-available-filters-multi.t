use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use Digest::MD5 qw(md5_hex);

my $h  = TestApp->new;
my $db = $h->app->sqlite->db;
my $reports = $h->app->reports;

# Seed multiple reports with diverse attributes so we can exercise:
#   - summary bucketing (PASS, FAIL(F), FAIL(Xm), bare FAIL)
#   - case-insensitive hostname sorting
#   - RPM-style perl_id desc sorting
#   - cascading filter narrowing
#   - compiler-dimension config-join
#   - date filtering interaction

my @seeds = (
    {
        hostname     => 'Alpha',
        architecture => 'x86_64',
        osname       => 'linux',
        osversion    => '6.1',
        perl_id      => '5.41.9',
        git_describe => 'v5.41.9-10-gabcdef1',
        git_id       => 'abcdef1',
        summary      => 'PASS',
        smoke_branch => 'blead',
        smoke_date   => '2025-07-01T10:00:00Z',
        duration     => 3600,
        cc           => 'gcc',
        ccversion    => '13.2',
        smoke_version => '1.86',
    },
    {
        hostname     => 'beta',
        architecture => 'aarch64',
        osname       => 'darwin',
        osversion    => '23.0',
        perl_id      => '5.40.0',
        git_describe => 'v5.40.0-5-g1234567',
        git_id       => '1234567',
        summary      => 'FAIL(F)',
        smoke_branch => 'blead',
        smoke_date   => '2025-07-01T11:00:00Z',
        duration     => 2400,
        cc           => 'clang',
        ccversion    => '15.0',
        smoke_version => '1.85',
    },
    {
        hostname     => 'CHARLIE',
        architecture => 'x86_64',
        osname       => 'linux',
        osversion    => '5.15',
        perl_id      => '5.39.7',
        git_describe => 'v5.39.7-2-gaaa1111',
        git_id       => 'aaa1111',
        summary      => 'FAIL(Xm)',
        smoke_branch => 'maint-5.38',
        smoke_date   => '2025-06-15T09:00:00Z',
        duration     => 1800,
        cc           => 'gcc',
        ccversion    => '12.0',
        smoke_version => '1.77',
    },
    {
        hostname     => 'delta',
        architecture => 'aarch64',
        osname       => 'linux',
        osversion    => '6.1',
        perl_id      => '5.41.9',
        git_describe => 'v5.41.9-15-gbbb2222',
        git_id       => 'bbb2222',
        summary      => 'FAIL(M)',
        smoke_branch => 'blead',
        smoke_date   => '2025-07-02T08:00:00Z',
        duration     => 4200,
        cc           => 'gcc',
        ccversion    => '13.2',
        smoke_version => '1.86',
    },
);

for my $s (@seeds) {
    my $plevel = CoreSmoke::Model::Plevel::from_git_describe(
        $s->{git_describe}, $s->{perl_id},
    );
    my $hash = md5_hex(join "\0",
        map { $s->{$_} // '' } qw(git_id smoke_date duration hostname architecture));

    $db->query(<<~'SQL',
        INSERT INTO report
            (hostname, architecture, osname, osversion, perl_id,
             git_describe, git_id, summary, smoke_branch, smoke_date,
             duration, smoke_version, plevel, report_hash)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        SQL
        @{$s}{qw(hostname architecture osname osversion perl_id
                  git_describe git_id summary smoke_branch smoke_date
                  duration smoke_version)},
        $plevel, $hash,
    );
    my $rid = $db->dbh->last_insert_id(undef, undef, 'report', undef);
    $db->query(
        "INSERT INTO config (report_id, arguments, debugging, cc, ccversion) VALUES (?,?,?,?,?)",
        $rid, '', 'N', $s->{cc}, $s->{ccversion},
    );
}

require CoreSmoke::Model::Plevel;

# ------------------------------------------------------------------
# 1. Unfiltered: all dimensions populated with correct values
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({});

    # Architectures: aarch64, x86_64 (sorted)
    is_deeply $av->{architectures}, [qw(aarch64 x86_64)],
        'architectures sorted';

    # OS names
    is_deeply $av->{osnames}, [qw(darwin linux)],
        'osnames sorted';

    # Perl versions in RPM desc order: 5.41.9, 5.40.0, 5.39.7
    is_deeply $av->{perl_versions}, [qw(5.41.9 5.40.0 5.39.7)],
        'perl_versions in RPM desc order';

    # Branches sorted
    is_deeply $av->{branches}, [qw(blead maint-5.38)],
        'branches sorted';

    # Hostnames: case-insensitive sort
    # Alpha, beta, CHARLIE, delta -> Alpha, beta, CHARLIE, delta
    is_deeply $av->{hostnames}, [qw(Alpha beta CHARLIE delta)],
        'hostnames sorted case-insensitively';

    # Compilers
    is_deeply $av->{compilers}, [qw(clang gcc)],
        'compilers sorted';

    # Summary buckets from (PASS, FAIL(F), FAIL(Xm), FAIL(M)):
    #   PASS -> PASS
    #   FAIL(F) -> FAIL(*), FAIL(F)
    #   FAIL(Xm) -> FAIL(*), FAIL(X), FAIL(m)
    #   FAIL(M) -> FAIL(*), FAIL(M)
    # Deduplicated: PASS, FAIL(*), FAIL(F), FAIL(M), FAIL(X), FAIL(m)
    # Order: PASS first, FAIL(*) second, then FAIL(x) sorted lex
    is_deeply $av->{summaries},
        [qw(PASS), 'FAIL(*)', qw(FAIL(F) FAIL(M) FAIL(X) FAIL(m))],
        'summary buckets: correct order and deduplication';

    # Smoker versions
    is_deeply $av->{smoker_versions}, [qw(1.77 1.85 1.86)],
        'smoker_versions sorted';
}

# ------------------------------------------------------------------
# 2. Cascading: filtering by architecture narrows other dimensions
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        selected_arch => 'aarch64',
    });

    # Only beta and delta have aarch64
    is_deeply $av->{hostnames}, [qw(beta delta)],
        'aarch64 filter -> only aarch64 hosts';

    # Perl versions for aarch64: 5.41.9 (delta), 5.40.0 (beta)
    is_deeply $av->{perl_versions}, [qw(5.41.9 5.40.0)],
        'aarch64 filter -> only matching perl versions';

    # Architectures dropdown still shows ALL (own filter excluded)
    is_deeply $av->{architectures}, [qw(aarch64 x86_64)],
        'architecture dropdown unaffected by own filter';
}

# ------------------------------------------------------------------
# 3. Cascading: filtering by perl_id narrows architectures
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        selected_perl => '5.39.7',
    });

    # Only CHARLIE has 5.39.7 -> only x86_64
    is_deeply $av->{architectures}, [qw(x86_64)],
        'perl 5.39.7 -> only x86_64';

    is_deeply $av->{hostnames}, [qw(CHARLIE)],
        'perl 5.39.7 -> only CHARLIE';

    is_deeply $av->{branches}, [qw(maint-5.38)],
        'perl 5.39.7 -> only maint-5.38 branch';

    # But perl_versions still shows all (own filter excluded)
    is_deeply $av->{perl_versions}, [qw(5.41.9 5.40.0 5.39.7)],
        'perl dropdown unaffected by own filter';
}

# ------------------------------------------------------------------
# 4. Cascading: filtering by branch narrows available hosts
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        selected_branch => 'maint-5.38',
    });

    is_deeply $av->{hostnames}, [qw(CHARLIE)],
        'maint-5.38 -> only CHARLIE';

    is_deeply $av->{perl_versions}, [qw(5.39.7)],
        'maint-5.38 -> only 5.39.7';

    # Summaries for CHARLIE only: FAIL(Xm) -> FAIL(*), FAIL(X), FAIL(m)
    is_deeply $av->{summaries},
        ['FAIL(*)', 'FAIL(X)', 'FAIL(m)'],
        'maint-5.38 -> only FAIL summaries from CHARLIE';
}

# ------------------------------------------------------------------
# 5. Cascading: compiler filter (config-join dimension)
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        selected_comp => 'clang',
    });

    # Only beta uses clang
    is_deeply $av->{hostnames}, [qw(beta)],
        'clang filter -> only beta';

    is_deeply $av->{perl_versions}, [qw(5.40.0)],
        'clang filter -> only 5.40.0';

    # Compilers dropdown still shows all
    is_deeply $av->{compilers}, [qw(clang gcc)],
        'compiler dropdown unaffected by own filter';
}

# ------------------------------------------------------------------
# 6. 'latest' perl filter resolves to highest perl_id
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        selected_perl => 'latest',
    });

    # 'latest' resolves to 5.41.9 (highest by RPM sort)
    # Reports with 5.41.9: Alpha (x86_64) and delta (aarch64)
    is_deeply $av->{architectures}, [qw(aarch64 x86_64)],
        'latest perl -> both architectures that have 5.41.9';

    is_deeply $av->{hostnames}, [qw(Alpha delta)],
        'latest perl -> Alpha and delta';
}

# ------------------------------------------------------------------
# 7. Date filter interaction
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        date_from => '2025-07-01',
    });

    # Reports on/after 2025-07-01: Alpha, beta, delta (CHARLIE is June)
    is_deeply $av->{hostnames}, [qw(Alpha beta delta)],
        'date_from 2025-07-01 excludes CHARLIE (June)';

    ok !( grep { $_ eq '5.39.7' } @{ $av->{perl_versions} } ),
        'date_from excludes 5.39.7 (only on CHARLIE)';
}

{
    my $av = $reports->available_filter_values({
        date_to => '2025-06-30',
    });

    # Only CHARLIE is before June 30 (inclusive of whole day)
    is_deeply $av->{hostnames}, [qw(CHARLIE)],
        'date_to 2025-06-30 -> only CHARLIE';
}

# ------------------------------------------------------------------
# 8. Multiple filters combine
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        selected_arch   => 'x86_64',
        selected_branch => 'blead',
    });

    # x86_64 + blead: only Alpha (CHARLIE is maint-5.38)
    is_deeply $av->{hostnames}, [qw(Alpha)],
        'x86_64+blead -> only Alpha';

    is_deeply $av->{summaries}, [qw(PASS)],
        'x86_64+blead -> only PASS';

    # Each dimension's own filter excluded independently:
    # architectures excludes selected_arch -> shows all archs matching blead
    is_deeply $av->{architectures}, [qw(aarch64 x86_64)],
        'arch dropdown shows all archs in blead';
    # branches excludes selected_branch -> shows all branches matching x86_64
    is_deeply $av->{branches}, [qw(blead maint-5.38)],
        'branch dropdown shows all branches for x86_64';
}

# ------------------------------------------------------------------
# 9. Impossible filter combination -> empty dimensions
# ------------------------------------------------------------------

{
    my $av = $reports->available_filter_values({
        selected_arch   => 'aarch64',
        selected_branch => 'maint-5.38',
    });

    # No report has aarch64 + maint-5.38
    is_deeply $av->{hostnames}, [],
        'impossible combo -> empty hostnames';
    is_deeply $av->{perl_versions}, [],
        'impossible combo -> empty perl_versions';

    # But architecture and branch dropdowns show available options
    # (each excludes its own filter)
    ok scalar @{ $av->{architectures} } >= 1,
        'arch dropdown still populated';
    ok scalar @{ $av->{branches} } >= 1,
        'branch dropdown still populated';
}

done_testing;
