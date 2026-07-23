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
my $t = $h->t;
my $db = $h->app->sqlite->db;

# Verify that Mojo::SQLite's db() returns different handles when one is
# in a transaction -- this is the root cause of the bug we're guarding
# against.
{
    my $s  = $h->app->sqlite;
    my $a  = $s->db;
    my $tx = $a->begin;
    my $b  = $s->db;
    isnt "$a->{dbh}", "$b->{dbh}",
        'Mojo::SQLite returns distinct handles when one holds a transaction';
    undef $tx;
}

# Ingest a valid report first to prime smoke_config and get baseline counts.
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, "baseline report ingested ($resp->{id})";

my $report_count_before = $db->query("SELECT COUNT(*) AS c FROM report")->hash->{c};
my $config_count_before = $db->query("SELECT COUNT(*) AS c FROM config")->hash->{c};

# Build a payload that will fail mid-way through config insertion:
# the first config is valid, the second has a NULL report_id injected
# by sabotaging the insert. We'll trigger failure by temporarily
# dropping the config table's report_id column constraint... actually,
# simpler: craft a config with a bad value that violates a NOT NULL
# constraint at the result level.
#
# Strategy: post a report whose second config's result has a missing
# config_id FK (by corrupting the insert chain). The cleanest way to
# test atomicity: monkey-patch _insert_result to die on the second call.

my $fixture = $h->fixture('idefix-gff5bbe677.jsn');

# Duplicate the config block so there are two configs, and the second
# will trigger the patched failure.
my $cfg_copy = { %{$fixture->{configs}[0]} };
$cfg_copy->{results} = [{ %{$fixture->{configs}[0]{results}[0]} }];
push @{$fixture->{configs}}, $cfg_copy;

# Make the fixture unique so it doesn't collide with the baseline report.
$fixture->{sysinfo}{hostname} = 'atomicity-test-host';
$fixture->{sysinfo}{smoke_date} = '2099-01-01T00:00:00Z';

# Patch _insert_result to die on the second result insert.
my $call_count = 0;
my $orig = \&CoreSmoke::Model::Ingest::_insert_result;
{
    no warnings 'redefine';
    *CoreSmoke::Model::Ingest::_insert_result = sub {
        $call_count++;
        die "INJECTED FAILURE for atomicity test" if $call_count > 1;
        return $orig->(@_);
    };
}

# The post should propagate the die as a 500.
my $tx_resp = $t->post_ok('/api/report', json => { report_data => $fixture });

# Restore original before assertions (important for later tests in the
# same prove run).
{
    no warnings 'redefine';
    *CoreSmoke::Model::Ingest::_insert_result = $orig;
}

# The request should have failed (500 from the die).
$tx_resp->status_is(500);

# The critical assertion: no new rows in report or config.
my $report_count_after = $db->query("SELECT COUNT(*) AS c FROM report")->hash->{c};
my $config_count_after = $db->query("SELECT COUNT(*) AS c FROM config")->hash->{c};

is $report_count_after, $report_count_before,
    'no report row leaked after mid-ingest failure (transaction rolled back)';
is $config_count_after, $config_count_before,
    'no config row leaked after mid-ingest failure (transaction rolled back)';

done_testing;
