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

my $h = TestApp->new;
my $t = $h->t;

# Empty DB sanity
$t->get_ok('/api/latest')->status_is(200)
  ->json_is('/report_count' => 0);

# Modern ingest path
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, "got new report id ($resp->{id})";

# /api/latest now sees one report
$t->get_ok('/api/latest')->status_is(200)
  ->json_is('/report_count' => 1);

my $rid = $resp->{id};

# Verify the row landed with computed plevel + report_hash
my $row = $h->app->sqlite->db->query(
    "SELECT plevel, report_hash, summary, hostname FROM report WHERE id = ?", $rid
)->hash;
is $row->{summary},  'PASS',   'summary stored';
is $row->{hostname}, 'idefix', 'hostname flattened from sysinfo';
like $row->{plevel}, qr/^5\.0/, 'plevel computed';
like $row->{report_hash}, qr/^[a-f0-9]{32}$/, 'report_hash is md5_hex';

# manifest_msgs from the fixture should have landed on disk as xz.
my $manifest = $h->app->report_files->read($rid, 'manifest_msgs');
like $manifest, qr/MANIFEST did not declare/, 'manifest_msgs round-trips through disk';

# log_file in the fixture is empty so there should be no file on disk.
is $h->app->report_files->read($rid, 'log_file'), undef,
   'empty log_file -> no on-disk file';

# Duplicate detection: re-post the exact same fixture
$t->post_ok('/api/report', json => { report_data => $h->fixture('idefix-gff5bbe677.jsn') })
  ->status_is(409)
  ->json_is('/error' => 'Report already posted.');

# Configs / results / failures linked correctly
my $configs = $h->app->sqlite->db->query(
    "SELECT * FROM config WHERE report_id = ? ORDER BY id", $rid
)->hashes->to_array;
ok scalar(@$configs) >= 1, 'configs inserted';
is $configs->[0]{cc}, 'cc', 'cc populated';

my $results = $h->app->sqlite->db->query(
    "SELECT * FROM result WHERE config_id = ? ORDER BY id", $configs->[0]{id}
)->hashes->to_array;
ok scalar(@$results) >= 1, 'results inserted';

# /api/full_report_data shape and on-disk fields
my $full = $t->get_ok("/api/full_report_data/$rid")->status_is(200)
  ->json_has('/configs')
  ->json_has('/c_compilers')
  ->json_has('/test_failures')
  ->json_has('/durations')
  ->tx->res->json;

like $full->{manifest_msgs_text}, qr/MANIFEST did not declare/,
     'full_report_data includes manifest_msgs_text from disk';

# /api/logfile / /api/outfile -- the fixture has empty log/out, so 404
$t->get_ok("/api/logfile/$rid")->status_is(404);
$t->get_ok("/api/outfile/$rid")->status_is(404);
# Legacy /api/outfle typo alias -- must behave identically.
$t->get_ok("/api/outfle/$rid")->status_is(404);

# config.started stores NULL when the field is missing, not empty string
{
    my $payload = {
        sysinfo    => { hostname => 'nulltest', architecture => 'x86_64',
                        osname => 'linux', osversion => '6.1',
                        perl_id => '5.40.0', git_id => 'null001',
                        git_describe => 'v5.40.0-1-gnull001',
                        smoke_date => '2024-01-15T12:00:00Z',
                        smoke_branch => 'blead' },
        summary    => 'PASS',
        configs    => [{
            arguments => '-Dusedevel',
            cc        => 'gcc',
            ccversion => '13.2',
            results   => [{ io_env => 'perlio', summary => 'PASS',
                            statistics => '1 test ok', failures => [] }],
        }],
    };
    my $res = $t->post_ok('/api/report', json => { report_data => $payload })
      ->status_is(200)->tx->res->json;
    ok $res->{id}, 'ingested report without started field';

    my $cfg = $h->app->sqlite->db->query(
        "SELECT started FROM config WHERE report_id = ?", $res->{id}
    )->hash;
    ok !defined $cfg->{started}, 'config.started is NULL, not empty string';
}

done_testing;
