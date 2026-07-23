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
my $db = $h->app->sqlite->db;
my $reports = $h->app->reports;

# =========================================================================
# _sort_perl_ids_desc (via latest_perl_id)
# =========================================================================

subtest 'latest_perl_id returns highest version' => sub {
    # Seed multiple perl versions
    for my $pv (
        ['5.38.0', '5.038000zzz000'],
        ['5.40.0', '5.040000zzz000'],
        ['5.42.0', '5.042000zzz000'],
    ) {
        $db->query(<<~'SQL',
            INSERT INTO report
                (perl_id, plevel, osname, osversion, hostname, architecture,
                 git_id, git_describe, smoke_date, summary, report_hash)
            VALUES (?, ?, 'linux', '6.5', 'sorthost', 'x86_64',
                    ?, ?, datetime('now'), 'PASS', ?)
            SQL
            $pv->[0], $pv->[1],
            "sort-$pv->[0]", "v$pv->[0]-1-gabc", "sort-hash-$pv->[0]",
        );
    }

    is $reports->latest_perl_id, '5.42.0',
        'latest_perl_id returns highest version';
};

subtest 'sort handles two-component versions' => sub {
    $db->query(<<~'SQL',
        INSERT INTO report
            (perl_id, plevel, osname, osversion, hostname, architecture,
             git_id, git_describe, smoke_date, summary, report_hash)
        VALUES ('5.43', '5.043000zzz000', 'linux', '6.5', 'sorthost2', 'x86_64',
                'sort-5.43', 'v5.43-1-gabc', datetime('now'), 'PASS', 'sort-hash-5.43')
        SQL
    );

    is $reports->latest_perl_id, '5.43',
        'two-component perl_id (5.43) sorts above 5.42.0';
};

subtest 'sort with v-prefixed perl_ids produces no warnings' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    # Call the sort function with v-prefixed perl_ids via a direct
    # function call (the DB-backed latest_perl_id already tested above).
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(
        [qw(v5.38.0 v5.42.0 v5.40.0)]
    );

    is_deeply $sorted, [qw(v5.42.0 v5.40.0 v5.38.0)],
        'v-prefixed perl_ids sort correctly descending';
    is scalar @warnings, 0,
        'no warnings from v-prefixed numeric comparison'
        or diag "warnings: @warnings";
};

subtest 'sort handles mixed v-prefixed and plain versions' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(
        ['v5.42.0', '5.40.0', 'v5.38.0']
    );

    is $sorted->[0], 'v5.42.0', 'highest version first (v-prefixed)';
    is $sorted->[1], '5.40.0',  'middle version second (plain)';
    is $sorted->[2], 'v5.38.0', 'lowest version last (v-prefixed)';
    is scalar @warnings, 0, 'no warnings from mixed prefix comparison';
};

subtest 'sort with single element' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc(['5.42.0']);
    is_deeply $sorted, ['5.42.0'], 'single-element list passes through';
};

subtest 'sort with empty list' => sub {
    my $sorted = CoreSmoke::Model::Reports::_sort_perl_ids_desc([]);
    is_deeply $sorted, [], 'empty list returns empty';
};

# =========================================================================
# _summary_buckets
# =========================================================================

subtest 'summary_buckets: PASS' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(['PASS']);
    is_deeply $result, ['PASS'], 'single PASS input yields PASS bucket';
};

subtest 'summary_buckets: FAIL with letters' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(
        ['FAIL(XF)']
    );
    ok( (grep { $_ eq 'FAIL(*)' } @$result), 'FAIL(*) umbrella present');
    ok( (grep { $_ eq 'FAIL(X)' } @$result), 'individual FAIL(X) present');
    ok( (grep { $_ eq 'FAIL(F)' } @$result), 'individual FAIL(F) present');
};

subtest 'summary_buckets: case-sensitive FAIL letters' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(
        ['FAIL(Mm)']
    );
    ok( (grep { $_ eq 'FAIL(M)' } @$result), 'uppercase M present');
    ok( (grep { $_ eq 'FAIL(m)' } @$result), 'lowercase m present');
    ok $result->[0] ne $result->[1], 'M and m are distinct buckets';
};

subtest 'summary_buckets: mixed PASS and FAIL' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(
        ['PASS', 'FAIL(F)', 'FAIL(X)']
    );
    is $result->[0], 'PASS',    'PASS sorts first';
    is $result->[1], 'FAIL(*)', 'FAIL(*) sorts second';
    ok( (grep { $_ eq 'FAIL(F)' } @$result), 'FAIL(F) present');
    ok( (grep { $_ eq 'FAIL(X)' } @$result), 'FAIL(X) present');
};

subtest 'summary_buckets: deduplicated letters across values' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(
        ['FAIL(XF)', 'FAIL(XM)']
    );
    my @fail_opts = grep { /^FAIL\([^*]/ } @$result;
    my %uniq = map { $_ => 1 } @fail_opts;
    is scalar keys %uniq, 3, 'three distinct FAIL letters: X, F, M';
};

subtest 'summary_buckets: unknown summary passes through' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(
        ['PASS', 'UNKNOWN']
    );
    ok( (grep { $_ eq 'UNKNOWN' } @$result), 'UNKNOWN passes through');
    is $result->[0], 'PASS', 'PASS still sorts first';
};

subtest 'summary_buckets: empty FAIL parens' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(['FAIL()']);
    is_deeply $result, ['FAIL(*)'],
        'empty parens produce umbrella only, no individual letters';
};

subtest 'summary_buckets: sort order is PASS < FAIL(*) < FAIL(x) < other' => sub {
    my $result = CoreSmoke::Model::Reports::_summary_buckets(
        ['UNKNOWN', 'FAIL(F)', 'PASS', 'FAIL(X)']
    );
    my @expected_order;
    for my $v (@$result) {
        my $rank = $v eq 'PASS'    ? 0
                 : $v eq 'FAIL(*)' ? 1
                 : $v =~ /^FAIL\(/ ? 2
                 :                    3;
        push @expected_order, $rank;
    }
    my @sorted_order = sort { $a <=> $b } @expected_order;
    is_deeply \@expected_order, \@sorted_order,
        'output sorted by rank: PASS, FAIL(*), individual FAIL, other';
};

done_testing;
