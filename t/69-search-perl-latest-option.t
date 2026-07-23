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

$h->ingest_fixture('idefix-gff5bbe677.jsn');

subtest 'latest option appears exactly once in perl dropdown' => sub {
    $t->get_ok('/search?selected_perl=latest')
      ->status_is(200);

    my $body = $t->tx->res->body;
    my @matches = ($body =~ m{<option\s[^>]*value="latest"[^>]*>}g);
    is scalar @matches, 1,
        'perl version dropdown has exactly one "latest" option';
};

subtest 'latest option present when no perl filter' => sub {
    $t->get_ok('/search')
      ->status_is(200);

    my $body = $t->tx->res->body;
    my @matches = ($body =~ m{<option\s[^>]*value="latest"[^>]*>}g);
    is scalar @matches, 1,
        'perl version dropdown has "latest" option when unfiltered';
};

done_testing;
