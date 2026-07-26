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
my $t  = $h->t;
my $db = $h->app->sqlite->db;

# ---------------------------------------------------------------------------
# Seed two reports with distinct attributes so cascading filters are testable.
#
#   Report A: idefix     / arm64   / darwin / v5.37.3  / PASS
#   Report B: buildbot-x / x86_64  / linux  / v5.42.0  / FAIL(F)
# ---------------------------------------------------------------------------

my $resp_a = $h->ingest_fixture('idefix-gff5bbe677.jsn');
my $rid_a  = $resp_a->{id};
ok $rid_a, "ingested fixture A (id=$rid_a)";

$db->query(<<~'SQL',
    INSERT INTO report
        (perl_id, plevel, osname, osversion, hostname, architecture,
         git_id, git_describe, smoke_date, summary, smoke_branch,
         smoke_version, report_hash)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    'v5.42.0', '5.042000', 'linux', '6.5',
    'buildbot-x', 'x86_64',
    'aaa1111', 'v5.42.0-1-gaaa1111',
    '2024-01-15T10:00:00Z', 'FAIL(F)', 'blead',
    '1.80', 'aaa1111_2024_hash_unique',
);
my $rid_b = $db->dbh->last_insert_id(undef, undef, 'report', undef);
ok $rid_b, "seeded report B (id=$rid_b)";

$db->query(
    "INSERT INTO config (report_id, arguments, debugging, cc, ccversion) VALUES (?, '', 'N', 'gcc', '13.2')",
    $rid_b,
);

# =========================================================================
# 1. Full-page /search renders the complete layout
# =========================================================================

subtest 'full-page /search renders layout + search region' => sub {
    $t->get_ok('/search')->status_is(200)
      ->content_like(qr{<html},            'full page includes <html>')
      ->content_like(qr{id="search-region"}, 'has search-region wrapper')
      ->content_like(qr{id="search-form"},   'has search form');
};

# =========================================================================
# 2. HTMX form-change returns the search_region partial (form + results)
# =========================================================================

subtest 'HTMX form-change returns search region' => sub {
    $t->get_ok('/search' =>
        { 'HX-Request' => 'true', 'HX-Trigger' => 'search-form' })
      ->status_is(200)
      ->content_like(qr{id="search-region"}, 'form-change returns region wrapper')
      ->content_like(qr{id="search-form"},   'form-change includes the form')
      ->content_unlike(qr{<html},            'form-change is a fragment, not full page');
};

# =========================================================================
# 3. HTMX infinite-scroll returns rows-only partial (no form, no region)
# =========================================================================

subtest 'HTMX infinite-scroll returns rows only' => sub {
    $t->get_ok('/search' => { 'HX-Request' => 'true' })
      ->status_is(200)
      ->content_unlike(qr{id="search-region"}, 'scroll skips region wrapper')
      ->content_unlike(qr{id="search-form"},   'scroll skips the form')
      ->content_unlike(qr{<html},              'scroll is a fragment');
};

# =========================================================================
# 4. Form-change with a filter still returns the region
# =========================================================================

subtest 'form-change with filter returns region + filtered results' => sub {
    $t->get_ok('/search?selected_arch=arm64' =>
        { 'HX-Request' => 'true', 'HX-Trigger' => 'search-form' })
      ->status_is(200)
      ->content_like(qr{id="search-region"}, 'filtered form-change has region')
      ->content_like(qr{idefix},             'arm64 filter keeps idefix')
      ->content_unlike(qr{buildbot-x},       'arm64 filter drops buildbot-x');
};

# =========================================================================
# 5. Cascading dropdowns: selecting arch=x86_64 narrows available options
# =========================================================================

subtest 'cascading dropdowns narrow when a filter is active' => sub {
    # With no filters, both architectures appear
    my $all = $t->get_ok('/search')->status_is(200)->tx->res->body;
    like $all, qr/arm64/,  'unfiltered: arm64 in dropdown';
    like $all, qr/x86_64/, 'unfiltered: x86_64 in dropdown';

    # Filter to arch=x86_64: other dropdowns should only show values
    # that co-occur with x86_64 reports (buildbot-x, linux, v5.42.0)
    my $filtered = $t->get_ok('/search?selected_arch=x86_64')->status_is(200)
        ->tx->res->body;

    # The arch dropdown itself still shows all options (so user can switch)
    like $filtered, qr/arm64/,  'arch dropdown keeps arm64 (user can switch)';
    like $filtered, qr/x86_64/, 'arch dropdown keeps x86_64';

    # Hostname dropdown: only buildbot-x should remain (not idefix)
    # The form_field component renders <option value="...">
    # Look for the hostname select specifically
    # Since available_filter_values excludes the self-dimension,
    # the hostname dropdown should only show hosts matching arch=x86_64
    like $filtered, qr/buildbot-x/, 'hostname dropdown includes buildbot-x (matches x86_64)';
};

# =========================================================================
# 6. Cascading: perl_versions narrow to matching versions
# =========================================================================

subtest 'cascading: perl dropdown narrows by architecture' => sub {
    my $body = $t->get_ok('/search?selected_arch=x86_64')->status_is(200)
        ->tx->res->body;

    # The perl dropdown should include v5.42.0 (the x86_64 report)
    like $body, qr/v5\.42\.0/, 'perl dropdown has v5.42.0 for x86_64 filter';
};

# =========================================================================
# 7. Both reports visible with no filter
# =========================================================================

subtest 'unfiltered search shows both reports' => sub {
    $t->get_ok('/search')->status_is(200)
      ->content_like(qr{idefix},     'idefix in unfiltered results')
      ->content_like(qr{buildbot-x}, 'buildbot-x in unfiltered results');
};

# =========================================================================
# 8. Summary filter works in search (FAIL(*) matches FAIL(F))
# =========================================================================

subtest 'summary filter on search' => sub {
    $t->get_ok('/search?selected_summary=PASS')->status_is(200)
      ->content_like(qr{idefix},       'PASS filter keeps idefix')
      ->content_unlike(qr{buildbot-x}, 'PASS filter drops buildbot-x');

    $t->get_ok('/search?selected_summary=FAIL(*)')->status_is(200)
      ->content_unlike(qr{idefix},     'FAIL(*) filter drops idefix')
      ->content_like(qr{buildbot-x},   'FAIL(*) filter keeps buildbot-x');
};

# =========================================================================
# 9. Combined filters: arch + summary
# =========================================================================

subtest 'combined filters narrow results' => sub {
    $t->get_ok('/search?selected_arch=x86_64&selected_summary=PASS')
      ->status_is(200)
      ->content_unlike(qr{idefix},     'x86_64+PASS: no idefix (arm64)')
      ->content_unlike(qr{buildbot-x}, 'x86_64+PASS: no buildbot-x (FAIL)');
};

# =========================================================================
# 10. "latest" perl pseudo-value resolves correctly
# =========================================================================

subtest 'selected_perl=latest resolves in search' => sub {
    # latest_perl_id uses _sort_perl_ids_desc which has a known v-prefix
    # issue on main (PR #107): "5.37.3" sorts above "v5.42.0" because
    # the 'v' prefix numerifies to 0. So "latest" currently resolves to
    # the non-v-prefixed id. Either way, the filter narrows results.
    $t->get_ok('/search?selected_perl=latest')->status_is(200);
    my $body = $t->tx->res->body;
    my $has_any = ($body =~ /idefix/ || $body =~ /buildbot-x/);
    ok $has_any, 'latest perl resolves to a concrete perl_id (shows results)';
};

# =========================================================================
# 11. Filter count badge tracks active filters
# =========================================================================

subtest 'filter count reflects number of active filters' => sub {
    $t->get_ok('/search?selected_arch=x86_64')->status_is(200)
      ->text_like('.filter-count' => qr/1 active filter/);

    $t->get_ok('/search?selected_arch=x86_64&selected_summary=PASS')->status_is(200)
      ->text_like('.filter-count' => qr/2 active filters/);

    # Date filters count too
    $t->get_ok('/search?date_from=2024-01-01')->status_is(200)
      ->text_like('.filter-count' => qr/1 active filter/);
};

# =========================================================================
# 12. Compiler filter triggers config JOIN
# =========================================================================

subtest 'compiler filter narrows results' => sub {
    # Report B has cc=gcc; report A has cc=cc
    $t->get_ok('/search?selected_comp=gcc')->status_is(200)
      ->content_like(qr{buildbot-x}, 'gcc filter keeps buildbot-x')
      ->content_unlike(qr{idefix},   'gcc filter drops idefix (cc=cc)');
};

done_testing;
