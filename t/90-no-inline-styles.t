use v5.42;
use warnings;
use Test::More;
use FindBin;
use File::Find ();

my $tmpl_dir = "$FindBin::Bin/../templates";
-d $tmpl_dir or plan skip_all => "templates dir not found";

my @violations;

File::Find::find(sub {
    return unless /\.html\.ep$/;
    my $path = $File::Find::name;
    open my $fh, '<', $_ or return;
    my $lineno = 0;
    while (my $line = <$fh>) {
        $lineno++;
        next unless $line =~ /style="/;
        next if $line =~ /style="--ratio:/;
        push @violations, "$path:$lineno";
    }
    close $fh;
}, $tmpl_dir);

ok !@violations, 'no inline style="..." in templates (except heatmap --ratio)'
    or diag "Violations:\n" . join("\n", @violations);

done_testing;
