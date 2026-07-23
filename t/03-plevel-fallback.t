use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

use CoreSmoke::Model::Plevel;

# t/02-plevel.t covers the corpus with single-arg calls. This file
# covers the perl_id fallback (second arg) and sort ordering.

subtest 'bare SHA falls back to perl_id-derived plevel' => sub {
    # A bare commit SHA has no v5.X.Y prefix -- the regex check fails
    # and from_git_describe falls back to _from_perl_id.
    is(
        CoreSmoke::Model::Plevel::from_git_describe('abc123def456', '5.41.9'),
        '5.041009zzz000',
        'bare SHA + perl_id 5.41.9 => perl_id-derived plevel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('deadbeef1234', '5.42.0'),
        '5.042000zzz000',
        'bare SHA + perl_id 5.42.0 => perl_id-derived plevel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('0000000', '5.40.2'),
        '5.040002zzz000',
        'short SHA + perl_id => perl_id-derived plevel',
    );
};

subtest 'bare SHA without perl_id returns low sentinel' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe('abc123def456'),
        '0.000000zzz000',
        'bare SHA, no perl_id => sentinel that sorts low',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('abc123def456', undef),
        '0.000000zzz000',
        'bare SHA, explicit undef perl_id => sentinel',
    );
};

subtest 'undef and empty git_describe' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe(undef, '5.41.9'),
        '5.041009zzz000',
        'undef describe + perl_id => perl_id fallback',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('', '5.41.9'),
        '5.041009zzz000',
        'empty describe + perl_id => perl_id fallback',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe(undef),
        '0.000000zzz000',
        'undef describe, no perl_id => low sentinel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe(''),
        '0.000000zzz000',
        'empty describe, no perl_id => low sentinel',
    );
};

subtest 'perl_id-only versions (two components)' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe('not-a-version', '5.42'),
        '5.042000zzz000',
        'two-component perl_id (5.42) gets patch=0',
    );
};

subtest 'malformed perl_id returns sentinel' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe('bare-sha', 'garbage'),
        '0.000000zzz000',
        'non-numeric perl_id falls through to sentinel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('bare-sha', ''),
        '0.000000zzz000',
        'empty perl_id falls through to sentinel',
    );
};

subtest 'sort ordering: plevels sort correctly as strings' => sub {
    # The whole point of plevel is that string comparison produces the
    # correct version ordering.
    my @inputs = (
        [ 'v5.38.0',            undef ],
        [ 'v5.38.4',            undef ],
        [ 'v5.40.0-RC1',        undef ],
        [ 'v5.40.0-RC2',        undef ],
        [ 'v5.40.0',            undef ],
        [ 'v5.40.2',            undef ],
        [ 'v5.41.0',            undef ],
        [ 'v5.41.9',            undef ],
        [ 'v5.41.10',           undef ],
        [ 'v5.41.10-5-gabc123', undef ],
        [ 'v5.42.0-RC1',        undef ],
        [ 'v5.42.0-RC2',        undef ],
        [ 'v5.42.0',            undef ],
    );

    my @plevels = map {
        CoreSmoke::Model::Plevel::from_git_describe($_->[0], $_->[1])
    } @inputs;

    my @sorted = sort @plevels;
    is_deeply(\@sorted, \@plevels,
        'plevels in version order sort correctly as strings');

    # Sentinel sorts below everything.
    my $sentinel = CoreSmoke::Model::Plevel::from_git_describe('deadbeef');
    ok($sentinel lt $plevels[0],
        'sentinel sorts below the lowest real plevel');

    # RC sorts below final release.
    my $rc2  = CoreSmoke::Model::Plevel::from_git_describe('v5.42.0-RC2');
    my $rel  = CoreSmoke::Model::Plevel::from_git_describe('v5.42.0');
    ok($rc2 lt $rel, 'RC2 sorts below final release');
};

subtest 'perl_id fallback sorts correctly relative to normal plevels' => sub {
    my $from_describe = CoreSmoke::Model::Plevel::from_git_describe('v5.41.9');
    my $from_fallback = CoreSmoke::Model::Plevel::from_git_describe('bare-sha', '5.41.9');
    is($from_describe, $from_fallback,
        'fallback plevel matches describe-derived plevel for same version');
};

done_testing;
