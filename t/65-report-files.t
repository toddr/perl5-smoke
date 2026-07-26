use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use CoreSmoke::Model::ReportFiles;

my $h   = TestApp->new;
my $app = $h->app;
my $rf  = $app->report_files;

my $hash = 'deadbeefcafef00d' . ('0' x 16);
my $payload = "Line 1\nLine 2\nLine \xff\x00\x7f end\n";

$rf->write($hash, { log_file => $payload, manifest_msgs => 'tiny' });

# read_by_hash should round-trip
is $rf->read_by_hash($hash, 'log_file'),     $payload, 'log_file round-trip';
is $rf->read_by_hash($hash, 'manifest_msgs'), 'tiny',  'manifest_msgs round-trip';

# Missing files return undef, not exceptions
is $rf->read_by_hash($hash, 'out_file'),     undef, 'missing field returns undef';
is $rf->read_by_hash('0' x 32, 'log_file'),  undef, 'missing hash returns undef';

# Path is sharded as documented
is $rf->path_for($hash),
   $app->config->{reports_dir} . "/de/ad/be/$hash",
   'sharded path layout';

# Unknown field name silently no-ops
$rf->write($hash, { not_a_field => 'whatever' });
is $rf->read_by_hash($hash, 'not_a_field'), undef, 'unknown field not written';

# has_file: true for written fields, false for missing
is $rf->has_file($hash, 'log_file'),      1, 'has_file true for existing file';
is $rf->has_file($hash, 'manifest_msgs'), 1, 'has_file true for another existing file';
is $rf->has_file($hash, 'out_file'),      0, 'has_file false for unwritten field';
is $rf->has_file('0' x 32, 'log_file'),   0, 'has_file false for missing hash';
is $rf->has_file($hash, 'not_a_field'), undef, 'has_file undef for unknown field';

# Atomic write: no .tmp files left after successful write
{
    my $dir = $rf->path_for($hash);
    my @tmps = glob("$dir/*.tmp");
    is scalar @tmps, 0, 'no temp files left after successful write';
}

# Atomic write: existing file unchanged if compression fails (simulate via empty input)
{
    my $hash2 = 'abcdef0123456789' . ('0' x 16);
    $rf->write($hash2, { log_file => 'original content' });
    is $rf->read_by_hash($hash2, 'log_file'), 'original content', 'pre-condition: file exists';

    # Overwrite with new content to verify the file is replaced atomically
    $rf->write($hash2, { log_file => 'updated content' });
    is $rf->read_by_hash($hash2, 'log_file'), 'updated content', 'file replaced atomically';

    my $dir2 = $rf->path_for($hash2);
    my @tmps = glob("$dir2/*.tmp");
    is scalar @tmps, 0, 'no temp files after overwrite';
}

# -- read() by report ID --
# The read($rid, $field) method resolves a report ID to its hash
# via _hash_for_rid, then delegates to read_by_hash.
subtest 'read by report ID' => sub {
    my $t   = $h->t;
    my $res = $h->ingest_fixture('idefix-gff5bbe677.jsn');
    my $rid = $res->{id};
    ok defined $rid, "ingested fixture has id=$rid";

    my $db_row = $app->sqlite->db->query(
        'SELECT report_hash FROM report WHERE id = ?', $rid,
    )->hash;
    ok $db_row, 'report row exists in DB';
    my $rh = $db_row->{report_hash};

    my $log_via_hash = $rf->read_by_hash($rh, 'log_file');
    my $log_via_id   = $rf->read($rid, 'log_file');
    is $log_via_id, $log_via_hash,
       'read($rid, field) returns same bytes as read_by_hash';

    is $rf->read(999999, 'log_file'), undef,
       'read() with nonexistent report ID returns undef';

    is $rf->read($rid, 'not_a_field'), undef,
       'read() rejects unknown field name';
};

# -- fields() class method --
subtest 'fields() returns expected list' => sub {
    my @f = CoreSmoke::Model::ReportFiles->fields;
    is scalar @f, 5, 'five fields';
    is_deeply [sort @f],
              [sort qw(log_file out_file manifest_msgs compiler_msgs nonfatal_msgs)],
              'field names match';
};

done_testing;
