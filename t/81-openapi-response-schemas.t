use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use YAML::PP qw();

my $h = TestApp->new;
my $t = $h->t;

my $spec = YAML::PP::LoadFile("$FindBin::Bin/../etc/openapi.yaml");
my $schemas = $spec->{components}{schemas} // {};

# Ingest a fixture so endpoints have data to return.
my $ingest_result = $h->ingest_fixture('idefix-gff5bbe677.jsn');
my $rid = $ingest_result->{id};

# --- Helper: resolve $ref to a schema ---
sub resolve_ref ($ref) {
    my ($path) = $ref =~ m{^#/(.+)$};
    my $node = $spec;
    $node = $node->{$_} for split '/', $path;
    return $node;
}

# --- Helper: check required fields are present in a hash ---
sub check_required ($data, $schema, $label) {
    return unless ref $schema eq 'HASH';

    # Resolve allOf by merging required arrays
    my @required;
    if ($schema->{allOf}) {
        for my $part (@{ $schema->{allOf} }) {
            my $resolved = ($part->{'$ref'}) ? resolve_ref($part->{'$ref'}) : $part;
            push @required, @{ $resolved->{required} // [] };
        }
    }
    else {
        @required = @{ $schema->{required} // [] };
    }

    for my $field (@required) {
        ok exists $data->{$field}, "$label has required field '$field'";
    }
}

# --- System endpoints ---
subtest '/system/status response schema' => sub {
    my $json = $t->get_ok('/system/status')->status_is(200)->tx->res->json;
    my $path_schema = $spec->{paths}{'/system/status'}{get}{responses}{'200'}{content}{'application/json'}{schema};
    check_required($json, $path_schema, '/system/status');
};

subtest '/system/methods response schema' => sub {
    my $json = $t->get_ok('/system/methods')->status_is(200)->tx->res->json;
    my $path_schema = $spec->{paths}{'/system/methods'}{get}{responses}{'200'}{content}{'application/json'}{schema};
    check_required($json, $path_schema, '/system/methods');
    ok ref $json->{methods} eq 'ARRAY', 'methods is an array';
};

subtest '/system/methods/{plugin} response schema' => sub {
    my $json = $t->get_ok('/system/methods/api')->status_is(200)->tx->res->json;
    my $path_schema = $spec->{paths}{'/system/methods/{plugin}'}{get}{responses}{'200'}{content}{'application/json'}{schema};
    check_required($json, $path_schema, '/system/methods/{plugin}');
    ok ref $json->{methods} eq 'ARRAY', 'methods is an array';
    is $json->{plugin}, 'api', 'plugin echoed back';
};

# --- API version ---
subtest '/api/version response schema' => sub {
    my $json = $t->get_ok('/api/version')->status_is(200)->tx->res->json;
    my $path_schema = $spec->{paths}{'/api/version'}{get}{responses}{'200'}{content}{'application/json'}{schema};
    check_required($json, $path_schema, '/api/version');
};

# --- Latest ---
subtest '/api/latest response schema' => sub {
    my $json = $t->get_ok('/api/latest')->status_is(200)->tx->res->json;
    my $path_schema = $spec->{paths}{'/api/latest'}{get}{responses}{'200'}{content}{'application/json'}{schema};
    check_required($json, $path_schema, '/api/latest');
    ok ref $json->{reports} eq 'ARRAY', 'reports is an array';

    if (@{ $json->{reports} }) {
        my $report = $json->{reports}[0];
        my $report_schema = resolve_ref('#/components/schemas/Report');
        check_required($report, $report_schema, '/api/latest report item');
    }
};

# --- Full report data ---
subtest '/api/full_report_data/{rid} response schema' => sub {
    my $json = $t->get_ok("/api/full_report_data/$rid")->status_is(200)->tx->res->json;
    my $full_schema = resolve_ref('#/components/schemas/FullReport');
    check_required($json, $full_schema, '/api/full_report_data');
    ok ref $json->{configs} eq 'ARRAY', 'configs is an array';
    ok ref $json->{c_compilers} eq 'ARRAY', 'c_compilers present';
    ok ref $json->{io_labels} eq 'ARRAY', 'io_labels present';
    ok ref $json->{matrix_rows} eq 'ARRAY', 'matrix_rows present';
    ok ref $json->{test_failures} eq 'ARRAY', 'test_failures present';
    ok exists $json->{has_log_file}, 'has_log_file present';
    ok exists $json->{has_out_file}, 'has_out_file present';
    ok exists $json->{duration_in_hhmm}, 'duration_in_hhmm present';
    ok exists $json->{average_in_hhmm}, 'average_in_hhmm present';
    ok exists $json->{authenticated}, 'authenticated present';
};

# --- Report data ---
subtest '/api/report_data/{rid} response schema' => sub {
    my $json = $t->get_ok("/api/report_data/$rid")->status_is(200)->tx->res->json;
    my $tree_schema = resolve_ref('#/components/schemas/ReportTree');
    check_required($json, $tree_schema, '/api/report_data');
    ok ref $json->{configs} eq 'ARRAY', 'configs is an array';

    if (@{ $json->{configs} }) {
        my $cfg = $json->{configs}[0];
        ok exists $cfg->{arguments}, 'config has arguments';
        ok exists $cfg->{debugging}, 'config has debugging';
        ok ref $cfg->{results} eq 'ARRAY', 'config has results array';
    }
};

# --- Logfile / outfile 404 ---
subtest '/api/logfile 404 response schema' => sub {
    my $json = $t->get_ok("/api/logfile/999999")->status_is(404)->tx->res->json;
    ok exists $json->{error}, '404 has error field';
};

subtest '/api/outfile 404 response schema' => sub {
    my $json = $t->get_ok("/api/outfile/999999")->status_is(404)->tx->res->json;
    ok exists $json->{error}, '404 has error field';
};

# --- Matrix ---
subtest '/api/matrix response schema' => sub {
    my $json = $t->get_ok('/api/matrix')->status_is(200)->tx->res->json;
    my $path_schema = $spec->{paths}{'/api/matrix'}{get}{responses}{'200'}{content}{'application/json'}{schema};
    check_required($json, $path_schema, '/api/matrix');
    ok ref $json->{perl_versions} eq 'ARRAY', 'perl_versions is an array';
    ok ref $json->{rows} eq 'ARRAY', 'rows is an array';
};

# --- Submatrix ---
subtest '/api/submatrix missing test param' => sub {
    my $json = $t->get_ok('/api/submatrix')->status_is(422)->tx->res->json;
    ok exists $json->{error}, '422 has error field';
};

subtest '/api/submatrix with test param' => sub {
    my $json = $t->get_ok('/api/submatrix?test=t/nonexistent.t')->status_is(200)->tx->res->json;
    ok ref $json eq 'ARRAY', 'submatrix returns array';
};

# --- Search ---
subtest '/api/searchparameters response schema' => sub {
    my $json = $t->get_ok('/api/searchparameters')->status_is(200)->tx->res->json;
    my $path_schema = $spec->{paths}{'/api/searchparameters'}{get}{responses}{'200'}{content}{'application/json'}{schema};
    check_required($json, $path_schema, '/api/searchparameters');
    ok ref $json->{sel_arch_os_ver} eq 'ARRAY', 'sel_arch_os_ver is array';
    ok ref $json->{sel_comp_ver} eq 'ARRAY', 'sel_comp_ver is array';
    ok ref $json->{branches} eq 'ARRAY', 'branches is array';
    ok ref $json->{perl_versions} eq 'ARRAY', 'perl_versions is array';
};

subtest '/api/searchresults response schema' => sub {
    my $json = $t->get_ok('/api/searchresults')->status_is(200)->tx->res->json;
    my $sr_schema = resolve_ref('#/components/schemas/SearchResults');
    check_required($json, $sr_schema, '/api/searchresults');
    ok ref $json->{reports} eq 'ARRAY', 'reports is array';
};

# --- Reports from id ---
subtest '/api/reports_from_id response schema' => sub {
    my $json = $t->get_ok("/api/reports_from_id/$rid")->status_is(200)->tx->res->json;
    ok ref $json eq 'ARRAY', 'returns array of ids';
    ok @$json > 0, 'has at least one id';
    like $json->[0], qr/^\d+$/, 'ids are integers';
};

# --- Reports from date ---
subtest '/api/reports_from_date response schema' => sub {
    my $json = $t->get_ok('/api/reports_from_date/0')->status_is(200)->tx->res->json;
    ok ref $json eq 'ARRAY', 'returns array of ids';
};

# --- Ingest success response ---
subtest 'ingest success response schema' => sub {
    ok exists $ingest_result->{id}, 'ingest success has id field';
    like $ingest_result->{id}, qr/^\d+$/, 'id is an integer';
};

# --- JSONRPC ---
subtest 'JSONRPC response schema' => sub {
    my $json = $t->post_ok('/api', json => {
        jsonrpc => '2.0', method => 'version', id => 1,
    })->status_is(200)->tx->res->json;

    ok exists $json->{jsonrpc}, 'has jsonrpc field';
    is $json->{jsonrpc}, '2.0', 'jsonrpc is 2.0';
    ok exists $json->{id}, 'has id field';
    ok exists $json->{result}, 'has result field';
};

subtest 'JSONRPC error response schema' => sub {
    my $json = $t->post_ok('/api', json => {
        jsonrpc => '2.0', method => 'nonexistent', id => 2,
    })->status_is(200)->tx->res->json;

    ok exists $json->{jsonrpc}, 'has jsonrpc field';
    ok exists $json->{error}, 'has error field';
    ok exists $json->{error}{code}, 'error has code';
    ok exists $json->{error}{message}, 'error has message';
};

# --- Verify every 200 response in the spec has a content schema ---
subtest 'all 200 responses have content schemas' => sub {
    for my $path (sort keys %{ $spec->{paths} }) {
        for my $method (sort keys %{ $spec->{paths}{$path} }) {
            my $resp = $spec->{paths}{$path}{$method}{responses}{'200'} // next;
            ok exists $resp->{content},
                "$method $path 200 response has content schema";
        }
    }
};

done_testing;
