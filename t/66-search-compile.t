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

# GLOB metacharacters in summary: bracket falls through to equality
{
    my ($from, $where, $bind) = $s->compile({ selected_summary => 'FAIL([)' });
    like $where, qr/r\.summary = \?/, 'FAIL([) -> equality, not GLOB';
    is_deeply $bind, ['FAIL([)'], 'metachar bracket: literal bind';
}

# GLOB metacharacters in summary: question mark falls through to equality
{
    my ($from, $where, $bind) = $s->compile({ selected_summary => 'FAIL(?)' });
    like $where, qr/r\.summary = \?/, 'FAIL(?) -> equality, not GLOB';
    is_deeply $bind, ['FAIL(?)'], 'metachar question: literal bind';
}

# GLOB metacharacters in summary: asterisk falls through to equality
{
    my ($from, $where, $bind) = $s->compile({ selected_summary => 'FAIL(])' });
    like $where, qr/r\.summary = \?/, 'FAIL(]) -> equality, not GLOB';
    is_deeply $bind, ['FAIL(])'], 'metachar close-bracket: literal bind';
}

# Multi-letter alpha FAIL codes still produce GLOB
{
    my ($from, $where, $bind) = $s->compile({ selected_summary => 'FAIL(Fm)' });
    like $where, qr/r\.summary GLOB \?/, 'FAIL(Fm) -> GLOB (multi-alpha ok)';
    is_deeply $bind, ['FAIL(*Fm*)'], 'multi-letter alpha bind';
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


# run() against an empty DB returns the empty shape
{
    my $out = $s->run({});
    is $out->{report_count},     0,  'empty DB: 0 reports';
    is_deeply $out->{reports},   [], 'empty DB: empty list';
    is $out->{page},             1,  'default page';
    is $out->{reports_per_page}, 25, 'default rpp';
}

done_testing;
