use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

use CoreSmoke::Model::Plevel;

my $corpus = "$FindBin::Bin/data/plevel-corpus.tsv";
open my $fh, '<', $corpus or die "open $corpus: $!";
while (my $line = <$fh>) {
    chomp $line;
    next if $line =~ /^\s*(?:#|$)/;
    my ($describe, $expected) = split /\t/, $line, 2;
    next unless defined $expected;
    is(
        CoreSmoke::Model::Plevel::from_git_describe($describe),
        $expected,
        "plevel($describe) = $expected",
    );
}
close $fh;

# -- perl_id fallback path --
# When git_describe is a bare SHA (no v5.X.Y prefix), the function
# falls back to deriving plevel from perl_id if supplied.

subtest 'bare SHA with perl_id fallback' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe('abc1234def', '5.41.9'),
        '5.041009zzz000',
        'bare SHA + perl_id 5.41.9 -> fallback plevel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('deadbeef', '5.40.0'),
        '5.040000zzz000',
        'bare SHA + perl_id 5.40.0 -> fallback plevel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('cafe0123', '5.42.1'),
        '5.042001zzz000',
        'bare SHA + perl_id 5.42.1 -> fallback plevel',
    );
};

subtest 'perl_id with two components' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe('abc1234', '5.41'),
        '5.041000zzz000',
        'two-component perl_id (minor only) -> patch defaults to 0',
    );
};

subtest 'bare SHA without perl_id -> sentinel' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe('deadbeef1234'),
        '0.000000zzz000',
        'bare SHA without perl_id -> low-sorting sentinel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('deadbeef', undef),
        '0.000000zzz000',
        'bare SHA + explicit undef -> sentinel',
    );
};

subtest 'empty and undef git_describe' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe(''),
        '0.000000zzz000',
        'empty string -> sentinel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe(undef),
        '0.000000zzz000',
        'undef -> sentinel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe(undef, '5.38.4'),
        '5.038004zzz000',
        'undef git_describe + valid perl_id -> fallback',
    );
};

subtest 'malformed perl_id -> sentinel' => sub {
    is(
        CoreSmoke::Model::Plevel::from_git_describe('deadbeef', 'not-a-version'),
        '0.000000zzz000',
        'bare SHA + malformed perl_id -> sentinel',
    );
    is(
        CoreSmoke::Model::Plevel::from_git_describe('deadbeef', ''),
        '0.000000zzz000',
        'bare SHA + empty perl_id -> sentinel',
    );
};

done_testing;
