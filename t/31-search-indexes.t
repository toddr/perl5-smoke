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

my %indexes = map { $_->{name} => 1 }
    @{ $db->query("PRAGMA index_list('report')")->hashes->to_array },
    @{ $db->query("PRAGMA index_list('config')")->hashes->to_array };

my @expected = qw(
    report_smoke_version_idx
    report_summary_idx
    config_cc_idx
    config_ccversion_idx
);

for my $idx (@expected) {
    ok $indexes{$idx}, "index $idx exists";
}

done_testing;
