use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use IO::Compress::Gzip qw(gzip $GzipError);

my $h = TestApp->new;
my $t = $h->t;

# Craft a gzip stream that has a valid header but corrupted body.
# Strategy: compress a large payload, then truncate mid-stream so the
# decompressor starts successfully but hits an error partway through.
my $big = 'A' x 100_000;
my $valid_gz;
gzip(\$big => \$valid_gz) or die "gzip: $GzipError";

# Truncate to ~40% of the compressed size. The gzip header (10 bytes
# minimum) is intact, so IO::Uncompress::Gunzip->new() succeeds, but
# a subsequent read() will fail mid-stream when the deflate block is
# incomplete.
my $truncated = substr($valid_gz, 0, int(length($valid_gz) * 0.4));

subtest 'truncated gzip body returns 400' => sub {
    $t->post_ok('/api/report' =>
        {
            'Content-Type'     => 'application/json',
            'Content-Encoding' => 'gzip',
        } =>
        $truncated
    )->status_is(400)
      ->json_is('/error' => 'Bad gzip body');
};

# A gzip stream with valid header but all-garbage compressed data.
# The 10-byte gzip header is preserved intact so the decompressor opens
# successfully, but the first read of the deflate stream fails.
subtest 'valid gzip header + garbage body returns 400' => sub {
    my $fake = substr($valid_gz, 0, 10) . ("\xDE\xAD" x 100);

    $t->post_ok('/api/report' =>
        {
            'Content-Type'     => 'application/json',
            'Content-Encoding' => 'gzip',
        } =>
        $fake
    )->status_is(400)
      ->json_is('/error' => 'Bad gzip body');
};

# Verify a valid gzip stream still works after the error tests
subtest 'valid gzip still accepted after error tests' => sub {
    my $small_json = '{"not":"a real report"}';
    my $gz_ok;
    gzip(\$small_json => \$gz_ok) or die "gzip: $GzipError";

    $t->post_ok('/api/report' =>
        {
            'Content-Type'     => 'application/json',
            'Content-Encoding' => 'gzip',
        } =>
        $gz_ok
    )->status_isnt(400, 'valid gzip is not rejected as bad');
};

done_testing;
