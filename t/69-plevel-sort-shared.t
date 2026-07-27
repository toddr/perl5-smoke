use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use CoreSmoke::Model::Plevel qw(sort_perl_ids_desc);
use TestApp;
use CoreSmoke::Model::Matrix;

# =========================================================================
# Part 1: unit test sort_perl_ids_desc via Plevel.pm export
# =========================================================================

is_deeply sort_perl_ids_desc([qw(5.9.0 5.42.0 5.10.1 5.40.0)]),
    [qw(5.42.0 5.40.0 5.10.1 5.9.0)],
    'numeric sort: 42 > 40 > 10 > 9';

is_deeply sort_perl_ids_desc([qw(5.41.9 5.41.10)]),
    [qw(5.41.10 5.41.9)],
    'patch level: 10 > 9 (not lexical)';

is_deeply sort_perl_ids_desc([]),
    [],
    'empty input returns empty';

is_deeply sort_perl_ids_desc([qw(5.42.0)]),
    [qw(5.42.0)],
    'single element';

# =========================================================================
# Part 2: matrix picks correct top-5 with tricky version numbers
# =========================================================================

my $h  = TestApp->new;
my $db = $h->app->sqlite->db;
my $m  = CoreSmoke::Model::Matrix->new(sqlite => $h->app->sqlite);

my @versions = (
    { perl_id => '5.42.0', plevel => '5.042000zzz000' },
    { perl_id => '5.40.0', plevel => '5.040000zzz000' },
    { perl_id => '5.38.0', plevel => '5.038000zzz000' },
    { perl_id => '5.36.0', plevel => '5.036000zzz000' },
    { perl_id => '5.34.0', plevel => '5.034000zzz000' },
    { perl_id => '5.10.1', plevel => '5.010001zzz000' },
    { perl_id => '5.9.0',  plevel => '5.009000zzz000' },
);

for my $v (@versions) {
    $db->query(<<~'SQL',
        INSERT INTO report
            (perl_id, plevel, osname, osversion, hostname, architecture,
             git_id, git_describe, smoke_date, summary, report_hash)
        VALUES (?, ?, 'linux', '6.5', 'host-a', 'x86_64',
                'aaa', 'v5.42.0-1-gaaa', datetime('now'), 'FAIL', ?)
        SQL
        $v->{perl_id}, $v->{plevel}, "hash_$v->{perl_id}",
    );
}

my $mat = $m->matrix;

is scalar @{ $mat->{perl_versions} }, 5,
    'matrix selects exactly 5 perl versions';

is_deeply $mat->{perl_versions},
    [qw(5.42.0 5.40.0 5.38.0 5.36.0 5.34.0)],
    'matrix top-5 are the highest by numeric sort, not string sort';

# =========================================================================
# Part 3: searchparameters returns perl_versions in correct order
# =========================================================================

my $reports = $h->app->reports;
my $sp      = $reports->searchparameters;

is_deeply $sp->{perl_versions},
    [qw(5.42.0 5.40.0 5.38.0 5.36.0 5.34.0 5.10.1 5.9.0)],
    'searchparameters perl_versions sorted numerically descending';

done_testing;
