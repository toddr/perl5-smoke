use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use Mojo::DOM;

my $h = TestApp->new;
my $t = $h->t;

# Ingest a PASS fixture so we have at least one report row
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
ok $resp->{id}, 'ingested fixture';

# The report's perl_id is "5.37.7" and its plevel (from
# Plevel::from_git_describe on "v5.37.7-55-gff5bbe677") is
# "5.037007zzz055". The perl column must carry
# data-sort-value=<plevel> so client-side sort orders version
# components numerically rather than lexicographically.

# --- /latest page ---
$t->get_ok('/latest')->status_is(200);

my $dom = Mojo::DOM->new($t->tx->res->body);
my @perl_cells = $dom->find('td[data-sort-key="perl"]')->each;
ok @perl_cells, '/latest has at least one perl sort cell';

for my $cell (@perl_cells) {
    my $sv = $cell->attr('data-sort-value');
    ok defined $sv, 'perl cell carries data-sort-value';
    like $sv, qr/^\d+\.\d{3}\d{3}/, 'sort value is zero-padded plevel, not raw perl_id';
    unlike $sv, qr/^5\.37\.7$/, 'sort value is NOT the raw perl_id string';
}

# Date column should also carry an ISO sort value (pre-existing)
my @date_cells = $dom->find('td[data-sort-key="date"]')->each;
ok @date_cells, '/latest has date sort cells';
for my $cell (@date_cells) {
    my $sv = $cell->attr('data-sort-value');
    ok defined $sv, 'date cell carries data-sort-value';
    like $sv, qr/^\d{4}-\d{2}-\d{2}T/, 'date sort value is ISO 8601';
}

# --- /search page ---
$t->get_ok('/search')->status_is(200);
$dom = Mojo::DOM->new($t->tx->res->body);
@perl_cells = $dom->find('td[data-sort-key="perl"]')->each;

SKIP: {
    skip '/search has no results without filter params', 2
        unless @perl_cells;
    for my $cell (@perl_cells) {
        my $sv = $cell->attr('data-sort-value');
        ok defined $sv, '/search perl cell carries data-sort-value';
        like $sv, qr/^\d+\.\d{3}\d{3}/, '/search sort value is zero-padded plevel';
    }
}

done_testing;
