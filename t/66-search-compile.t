use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use CoreSmoke::Model::Search;

my $h     = TestApp->new;
my $sqlite = $h->app->sqlite;
my $s     = CoreSmoke::Model::Search->new(sqlite => $sqlite);

# Empty params -> no filter
{
    my ($from, $where, $bind) = $s->compile({});
    is $from, "FROM report r", 'empty params: no config join';
    is $where, '', 'empty params: no where clause';
    is_deeply $bind, [], 'empty params: no bind values';
}

# Single equality on architecture
{
    my ($from, $where, $bind) = $s->compile({ selected_arch => 'x86_64' });
    is $from, "FROM report r", 'arch only: no config join';
    like $where, qr/r\.architecture = \?/, 'arch =';
    is_deeply $bind, ['x86_64'], 'bind value';
}

# AND/NOT inversion flips equality to inequality
{
    my ($from, $where, $bind) = $s->compile({
        selected_arch  => 'x86_64',
        andnotsel_arch => 1,
    });
    like $where, qr/r\.architecture <> \?/, 'and-not flips to <>';
    is_deeply $bind, ['x86_64'], 'bind value';
}

# `latest` is resolved by Reports::searchresults / available_filter_values
# into a concrete perl_id (via RPM-style sort) before Search::compile is
# called, so the compiler treats `latest` as a no-op and emits no clause.
{
    my ($from, $where, $bind) = $s->compile({ selected_perl => 'latest' });
    is $where, '', 'compile leaves bare `latest` untouched';
    is_deeply $bind, [], 'no bind for latest';
}

# Compiler filters force the config join
{
    my ($from, $where, $bind) = $s->compile({ selected_comp => 'gcc' });
    like $from, qr/JOIN config c/, 'comp triggers config join';
    like $where, qr/c\.cc = \?/, 'cc = ?';
    is_deeply $bind, ['gcc'], 'bind value';
}

# Smoker version filter uses report table
{
    my ($from, $where, $bind) = $s->compile({ selected_smkv => '1.86' });
    is $from, "FROM report r", 'smkv only: no config join';
    like $where, qr/r\.smoke_version = \?/, 'smoke_version =';
    is_deeply $bind, ['1.86'], 'bind value';
}

# `all` is treated as no filter
{
    my (undef, $where, $bind) = $s->compile({
        selected_arch => 'all',
        selected_perl => 'all',
    });
    is $where, '', 'all -> no where';
    is_deeply $bind, [], 'all -> no bind';
}

# date_from produces >= on smoke_date
{
    my ($from, $where, $bind) = $s->compile({ date_from => '2024-06-01' });
    is $from, "FROM report r", 'date_from: no config join';
    like $where, qr/r\.smoke_date >= \?/, 'date_from >=';
    is_deeply $bind, ['2024-06-01'], 'date_from bind value';
}

# date_to produces < date(?, '+1 day') for end-of-day inclusivity
{
    my ($from, $where, $bind) = $s->compile({ date_to => '2024-06-30' });
    like $where, qr/r\.smoke_date < date\(\?, '\+1 day'\)/, 'date_to < next day';
    is_deeply $bind, ['2024-06-30'], 'date_to bind value';
}

# Both date_from and date_to together
{
    my ($from, $where, $bind) = $s->compile({
        date_from => '2024-01-01',
        date_to   => '2024-12-31',
    });
    like $where, qr/r\.smoke_date >= \?/, 'range: date_from >=';
    like $where, qr/r\.smoke_date < date/, 'range: date_to <';
    is_deeply $bind, ['2024-01-01', '2024-12-31'], 'range: both bind values';
}

# Empty date params are ignored
{
    my (undef, $where, $bind) = $s->compile({ date_from => '', date_to => '' });
    is $where, '', 'empty date params: no where';
    is_deeply $bind, [], 'empty date params: no bind';
}

# summary GLOB: PASS bucket
{
    my ($from, $where, $bind) = $s->compile({ selected_summary => 'PASS' });
    like $where, qr/r\.summary GLOB \?/, 'summary PASS -> GLOB';
    is_deeply $bind, ['PASS*'], 'summary PASS bind';
}

# summary GLOB: FAIL(*) any-failure bucket
{
    my ($from, $where, $bind) = $s->compile({ selected_summary => 'FAIL(*)' });
    like $where, qr/r\.summary GLOB \?/, 'summary FAIL(*) -> GLOB';
    is_deeply $bind, ['FAIL(*'], 'summary FAIL(*) bind';
}

# summary GLOB: specific FAIL(F) bucket
{
    my ($from, $where, $bind) = $s->compile({ selected_summary => 'FAIL(F)' });
    like $where, qr/r\.summary GLOB \?/, 'summary FAIL(F) -> GLOB';
    is_deeply $bind, ['FAIL(*F*)'], 'summary FAIL(F) bind';
}

# andnotsel_summary negates PASS -> NOT GLOB
{
    my ($from, $where, $bind) = $s->compile({
        selected_summary  => 'PASS',
        andnotsel_summary => 1,
    });
    like $where, qr/r\.summary NOT GLOB \?/, 'andnotsel_summary PASS -> NOT GLOB';
    is_deeply $bind, ['PASS*'], 'negated PASS bind unchanged';
}

# andnotsel_summary negates FAIL(*) -> NOT GLOB
{
    my ($from, $where, $bind) = $s->compile({
        selected_summary  => 'FAIL(*)',
        andnotsel_summary => 1,
    });
    like $where, qr/r\.summary NOT GLOB \?/, 'andnotsel_summary FAIL(*) -> NOT GLOB';
    is_deeply $bind, ['FAIL(*'], 'negated FAIL(*) bind unchanged';
}

# andnotsel_summary negates specific FAIL(m) -> NOT GLOB
{
    my ($from, $where, $bind) = $s->compile({
        selected_summary  => 'FAIL(m)',
        andnotsel_summary => 1,
    });
    like $where, qr/r\.summary NOT GLOB \?/, 'andnotsel_summary FAIL(m) -> NOT GLOB';
    is_deeply $bind, ['FAIL(*m*)'], 'negated FAIL(m) bind unchanged';
}

# andnotsel_summary negates unknown bucket -> <>
{
    my ($from, $where, $bind) = $s->compile({
        selected_summary  => 'UNKNOWN',
        andnotsel_summary => 1,
    });
    like $where, qr/r\.summary <> \?/, 'andnotsel_summary unknown -> <>';
    is_deeply $bind, ['UNKNOWN'], 'negated unknown bind unchanged';
}

# AND/NOT inversion on branch flips to inequality
{
    my ($from, $where, $bind) = $s->compile({
        selected_branch  => 'blead',
        andnotsel_branch => 1,
    });
    like $where, qr/r\.smoke_branch <> \?/, 'andnotsel_branch flips to <>';
    is_deeply $bind, ['blead'], 'bind value';
}


# search_params() returns the full list
{
    my @sp = CoreSmoke::Model::Search::search_params();
    ok @sp > 10, 'search_params returns non-trivial list';
    my %sp = map { $_ => 1 } @sp;
    ok $sp{selected_arch},     'search_params includes selected_arch';
    ok $sp{selected_cver},     'search_params includes selected_cver';
    ok $sp{andnotsel_comp},    'search_params includes andnotsel_comp';
    ok $sp{date_from},         'search_params includes date_from';
    ok $sp{page},              'search_params includes page';
    ok $sp{reports_per_page},  'search_params includes reports_per_page';
}

# ccversion filter triggers config join
{
    my ($from, $where, $bind) = $s->compile({ selected_cver => '13.2' });
    like $from, qr/JOIN config c/, 'cver triggers config join';
    like $where, qr/c\.ccversion = \?/, 'ccversion = ?';
    is_deeply $bind, ['13.2'], 'cver bind value';
}

# comp + cver together: both columns in WHERE
{
    my ($from, $where, $bind) = $s->compile({
        selected_comp => 'gcc',
        selected_cver => '13.2',
    });
    like $from,  qr/JOIN config c/, 'comp+cver: config join';
    like $where, qr/c\.cc = \?/,       'comp+cver: cc clause';
    like $where, qr/c\.ccversion = \?/, 'comp+cver: ccversion clause';
    is_deeply $bind, ['gcc', '13.2'], 'comp+cver: both bind values';
}

# andnotsel_comp negates compiler filter
{
    my ($from, $where, $bind) = $s->compile({
        selected_comp  => 'clang',
        andnotsel_comp => 1,
    });
    like $from, qr/JOIN config c/, 'andnotsel_comp: config join';
    like $where, qr/c\.cc <> \?/, 'andnotsel_comp flips to <>';
    is_deeply $bind, ['clang'], 'andnotsel_comp bind value';
}

# andnotsel_cver negates ccversion filter
{
    my ($from, $where, $bind) = $s->compile({
        selected_cver  => '12.0',
        andnotsel_cver => 1,
    });
    like $from, qr/JOIN config c/, 'andnotsel_cver: config join';
    like $where, qr/c\.ccversion <> \?/, 'andnotsel_cver flips to <>';
    is_deeply $bind, ['12.0'], 'andnotsel_cver bind value';
}

# osname filter
{
    my ($from, $where, $bind) = $s->compile({ selected_osnm => 'linux' });
    is $from, "FROM report r", 'osnm: no config join';
    like $where, qr/r\.osname = \?/, 'osnm =';
    is_deeply $bind, ['linux'], 'osnm bind value';
}

# andnotsel_osnm negation
{
    my ($from, $where, $bind) = $s->compile({
        selected_osnm  => 'MSWin32',
        andnotsel_osnm => 1,
    });
    like $where, qr/r\.osname <> \?/, 'andnotsel_osnm flips to <>';
    is_deeply $bind, ['MSWin32'], 'andnotsel_osnm bind value';
}

# osversion filter
{
    my ($from, $where, $bind) = $s->compile({ selected_osvs => '6.1' });
    like $where, qr/r\.osversion = \?/, 'osvs =';
    is_deeply $bind, ['6.1'], 'osvs bind value';
}

# andnotsel_osvs negation
{
    my ($from, $where, $bind) = $s->compile({
        selected_osvs  => '10.0',
        andnotsel_osvs => 1,
    });
    like $where, qr/r\.osversion <> \?/, 'andnotsel_osvs flips to <>';
}

# hostname filter
{
    my ($from, $where, $bind) = $s->compile({ selected_host => 'smoker1' });
    like $where, qr/r\.hostname = \?/, 'host =';
    is_deeply $bind, ['smoker1'], 'host bind value';
}

# andnotsel_host negation
{
    my ($from, $where, $bind) = $s->compile({
        selected_host  => 'smoker1',
        andnotsel_host => 1,
    });
    like $where, qr/r\.hostname <> \?/, 'andnotsel_host flips to <>';
}

# andnotsel_smkv negation
{
    my ($from, $where, $bind) = $s->compile({
        selected_smkv  => '1.86',
        andnotsel_smkv => 1,
    });
    like $where, qr/r\.smoke_version <> \?/, 'andnotsel_smkv flips to <>';
}

# concrete perl_id filter
{
    my ($from, $where, $bind) = $s->compile({ selected_perl => '5.42.0' });
    like $where, qr/r\.perl_id = \?/, 'concrete perl_id: perl_id =';
    is_deeply $bind, ['5.42.0'], 'concrete perl_id bind value';
}

# perl_id 'all' => no filter (already tested), '' => no filter
{
    my (undef, $where, $bind) = $s->compile({ selected_perl => '' });
    is $where, '', 'empty perl_id: no where clause';
    is_deeply $bind, [], 'empty perl_id: no bind';
}

# Multi-filter combination: arch + branch + date
{
    my ($from, $where, $bind) = $s->compile({
        selected_arch   => 'aarch64',
        selected_branch => 'maint-5.40',
        date_from       => '2024-01-01',
    });
    is $from, "FROM report r", 'multi-filter: no config join';
    like $where, qr/r\.architecture = \?/, 'multi-filter: arch';
    like $where, qr/r\.smoke_branch = \?/, 'multi-filter: branch';
    like $where, qr/r\.smoke_date >= \?/,  'multi-filter: date_from';
    is_deeply $bind, ['aarch64', 'maint-5.40', '2024-01-01'],
        'multi-filter: bind values in order';
}

# run() against an empty DB returns the empty shape
{
    my $out = $s->run({});
    is $out->{report_count},     0,  'empty DB: 0 reports';
    is_deeply $out->{reports},   [], 'empty DB: empty list';
    is $out->{page},             1,  'default page';
    is $out->{reports_per_page}, 25, 'default rpp';
}

# ---- run() with seeded data ----
my $db = $sqlite->db;

sub insert_report (%args) {
    $db->query(<<~'SQL',
        INSERT INTO report (
            smoke_date, perl_id, git_id, git_describe,
            hostname, architecture, osname, osversion,
            summary, smoke_branch, smoke_version, plevel, report_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        $args{smoke_date},
        $args{perl_id}      // '5.41.9',
        $args{git_id}       // 'abc' . int(rand 999999),
        $args{git_describe} // 'v5.41.9-1-g' . int(rand 999999),
        $args{hostname}     // 'testhost',
        $args{architecture} // 'x86_64',
        $args{osname}       // 'linux',
        $args{osversion}    // '6.1',
        $args{summary}      // 'PASS',
        $args{smoke_branch} // 'blead',
        $args{smoke_version} // '1.86',
        $args{plevel},
        $args{report_hash},
    );
    return $db->dbh->last_insert_id(undef, undef, 'report', undef);
}

sub insert_config (%args) {
    $db->query(<<~'SQL',
        INSERT INTO config (report_id, arguments, debugging, cc, ccversion)
        VALUES (?, ?, ?, ?, ?)
        SQL
        $args{report_id},
        $args{arguments}  // '',
        $args{debugging}  // 'DEBUGGING',
        $args{cc}         // 'gcc',
        $args{ccversion}  // '13.2',
    );
}

# Seed 5 reports with varied attributes
my $r1_id = insert_report(
    smoke_date  => '2024-06-01T10:00:00Z',
    perl_id     => '5.42.0',
    hostname    => 'alpha',
    osname      => 'linux',
    osversion   => '6.1',
    summary     => 'PASS',
    plevel      => '5.042000zzz000',
    report_hash => 'search_r1',
);
insert_config(report_id => $r1_id, cc => 'gcc', ccversion => '13.2');

my $r2_id = insert_report(
    smoke_date  => '2024-05-15T10:00:00Z',
    perl_id     => '5.42.0',
    hostname    => 'bravo',
    osname      => 'MSWin32',
    osversion   => '10.0',
    summary     => 'FAIL(F)',
    plevel      => '5.042000zzz000',
    report_hash => 'search_r2',
);
insert_config(report_id => $r2_id, cc => 'cl', ccversion => '19.0');

my $r3_id = insert_report(
    smoke_date  => '2024-04-01T10:00:00Z',
    perl_id     => '5.40.0',
    hostname    => 'charlie',
    osname      => 'darwin',
    osversion   => '23.1',
    summary     => 'PASS',
    smoke_branch => 'maint-5.40',
    plevel      => '5.040000zzz000',
    report_hash => 'search_r3',
);
insert_config(report_id => $r3_id, cc => 'clang', ccversion => '15.0');

my $r4_id = insert_report(
    smoke_date  => '2024-07-10T10:00:00Z',
    perl_id     => '5.42.0',
    hostname    => 'delta',
    osname      => 'linux',
    osversion   => '5.15',
    summary     => 'FAIL(m)',
    smoke_version => '1.85',
    plevel      => '5.042000zzz001',
    report_hash => 'search_r4',
);
insert_config(report_id => $r4_id, cc => 'gcc', ccversion => '12.3');

my $r5_id = insert_report(
    smoke_date  => '2024-03-20T10:00:00Z',
    perl_id     => '5.38.2',
    hostname    => 'echo',
    osname      => 'freebsd',
    osversion   => '14.0',
    summary     => 'PASS',
    smoke_branch => 'maint-5.38',
    plevel      => '5.038002zzz000',
    report_hash => 'search_r5',
);
insert_config(report_id => $r5_id, cc => 'clang', ccversion => '16.0');

# run() no filter: all 5 reports
{
    my $out = $s->run({});
    is $out->{report_count}, 5, 'run: all 5 reports';
    is scalar @{$out->{reports}}, 5, 'run: 5 rows returned';
}

# run() filtered by osname
{
    my $out = $s->run({ selected_osnm => 'linux' });
    is $out->{report_count}, 2, 'run osnm=linux: 2 matches';
    my %hosts = map { $_->{hostname} => 1 } @{$out->{reports}};
    ok $hosts{alpha} && $hosts{delta}, 'run osnm=linux: correct hosts';
}

# run() filtered by concrete perl_id
{
    my $out = $s->run({ selected_perl => '5.40.0' });
    is $out->{report_count}, 1, 'run perl_id=5.40.0: 1 match';
    is $out->{reports}[0]{hostname}, 'charlie', 'run perl_id: correct host';
}

# run() filtered by compiler (config join)
{
    my $out = $s->run({ selected_comp => 'gcc' });
    is $out->{report_count}, 2, 'run comp=gcc: 2 matches';
    my %hosts = map { $_->{hostname} => 1 } @{$out->{reports}};
    ok $hosts{alpha} && $hosts{delta}, 'run comp=gcc: correct hosts';
}

# run() filtered by ccversion (config join)
{
    my $out = $s->run({ selected_cver => '15.0' });
    is $out->{report_count}, 1, 'run cver=15.0: 1 match';
    is $out->{reports}[0]{hostname}, 'charlie', 'run cver: correct host';
}

# run() negated filter: osnm != MSWin32
{
    my $out = $s->run({
        selected_osnm  => 'MSWin32',
        andnotsel_osnm => 1,
    });
    is $out->{report_count}, 4, 'run NOT osnm=MSWin32: 4 matches';
    my %hosts = map { $_->{hostname} => 1 } @{$out->{reports}};
    ok !$hosts{bravo}, 'run NOT osnm: bravo excluded';
}

# run() summary filter: FAIL(*) matches both FAIL types
{
    my $out = $s->run({ selected_summary => 'FAIL(*)' });
    is $out->{report_count}, 2, 'run FAIL(*): 2 matches';
    my %hosts = map { $_->{hostname} => 1 } @{$out->{reports}};
    ok $hosts{bravo} && $hosts{delta}, 'run FAIL(*): correct hosts';
}

# run() date range
{
    my $out = $s->run({
        date_from => '2024-05-01',
        date_to   => '2024-06-30',
    });
    is $out->{report_count}, 2, 'run date range: 2 matches';
    my %hosts = map { $_->{hostname} => 1 } @{$out->{reports}};
    ok $hosts{alpha} && $hosts{bravo}, 'run date range: correct hosts';
}

# run() pagination: page 1
{
    my $out = $s->run({ reports_per_page => 2, page => 1 });
    is scalar @{$out->{reports}}, 2, 'run page 1: 2 rows';
    is $out->{report_count}, 5, 'run page 1: total unchanged';
    is $out->{page}, 1, 'run page 1: page=1';
    is $out->{reports_per_page}, 2, 'run page 1: rpp=2';
}

# run() pagination: page 2
{
    my $out = $s->run({ reports_per_page => 2, page => 2 });
    is scalar @{$out->{reports}}, 2, 'run page 2: 2 rows';
}

# run() pagination: page 3 (last page)
{
    my $out = $s->run({ reports_per_page => 2, page => 3 });
    is scalar @{$out->{reports}}, 1, 'run page 3: 1 remaining row';
}

# run() pagination: page beyond data
{
    my $out = $s->run({ reports_per_page => 2, page => 99 });
    is scalar @{$out->{reports}}, 0, 'run page 99: no rows';
    is $out->{report_count}, 5, 'run page 99: total still 5';
}

# run() page clamping: page < 1 becomes 1
{
    my $out = $s->run({ page => -5 });
    is $out->{page}, 1, 'run negative page clamped to 1';
}

# run() rpp capping: > 500 becomes 500
{
    my $out = $s->run({ reports_per_page => 9999 });
    is $out->{reports_per_page}, 500, 'run rpp capped at 500';
}

# run() ordering: plevel DESC, smoke_date DESC
{
    my $out = $s->run({});
    my @plevels = map { $_->{plevel} } @{$out->{reports}};
    my @sorted  = sort { $b cmp $a } @plevels;
    is_deeply \@plevels, \@sorted, 'run: results ordered by plevel DESC';
}

# run() combined: comp filter + date + pagination
{
    my $out = $s->run({
        selected_comp => 'gcc',
        date_from     => '2024-01-01',
        reports_per_page => 1,
        page          => 1,
    });
    is $out->{report_count}, 2, 'run combined: 2 gcc reports in range';
    is scalar @{$out->{reports}}, 1, 'run combined: page of 1';
}

done_testing;
