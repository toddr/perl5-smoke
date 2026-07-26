use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/..";

for my $script (qw(smoke migrate fix-plevels import-from-pgdump import-report-files-tarball)) {
    my $path = "$root/script/$script";
    ok -f $path, "script/$script exists";
    my $out = `"$^X" -c "$path" 2>&1`;
    is $?, 0, "script/$script compiles cleanly"
        or diag $out;
}

done_testing;
