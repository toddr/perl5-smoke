use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use Mojo::JSON qw(encode_json);

my $h = TestApp->new;
my $t = $h->t;

# Ingest a fixture so we have data for parity checks.
my $resp = $h->ingest_fixture('idefix-gff5bbe677.jsn');
my $rid  = $resp->{id};
ok $rid, "fixture ingested (id=$rid)";

# ---- JSONRPC protocol error paths ----------------------------------------

subtest 'parse error (-32700): non-JSON body' => sub {
    $t->post_ok('/api' => { 'Content-Type' => 'application/json' } => 'this is not json')
      ->status_is(200)
      ->json_is('/jsonrpc' => '2.0')
      ->json_is('/id'      => undef)
      ->json_is('/error/code' => -32700)
      ->json_like('/error/message' => qr/[Pp]arse/);
};

subtest 'invalid request (-32600): JSON string value' => sub {
    $t->post_ok('/api' => { 'Content-Type' => 'application/json' } => '"just a string"')
      ->status_is(200)
      ->json_is('/error/code' => -32600)
      ->json_like('/error/message' => qr/[Ii]nvalid/);
};

subtest 'invalid request (-32600): JSON number' => sub {
    $t->post_ok('/api' => { 'Content-Type' => 'application/json' } => '42')
      ->status_is(200)
      ->json_is('/error/code' => -32600);
};

subtest 'invalid request (-32600): JSON null' => sub {
    $t->post_ok('/api' => { 'Content-Type' => 'application/json' } => 'null')
      ->status_is(200)
      ->json_is('/error/code' => -32700);
};

subtest 'batch with invalid entry' => sub {
    my $batch = $t->post_ok('/api', json => [
        { jsonrpc => '2.0', id => 'ok', method => 'ping' },
        42,
        { jsonrpc => '2.0', id => 'ok2', method => 'version' },
    ])->status_is(200)->tx->res->json;

    is ref $batch, 'ARRAY', 'batch response is array';
    is scalar(@$batch), 3, 'one response per entry';

    is $batch->[0]{id}, 'ok', 'first entry processed normally';
    is $batch->[0]{result}, 'pong', 'first entry result correct';

    is $batch->[1]{error}{code}, -32600, 'invalid entry gets -32600';

    is $batch->[2]{id}, 'ok2', 'third entry processed normally';
    ok $batch->[2]{result}{software_version}, 'third entry has result';
};

subtest 'empty batch' => sub {
    $t->post_ok('/api', json => [])
      ->status_is(200);
};

# ---- POST /system JSONRPC route -----------------------------------------

subtest '/system JSONRPC dispatch' => sub {
    $t->post_ok('/system', json => { jsonrpc => '2.0', id => 1, method => 'ping' })
      ->status_is(200)
      ->json_is('/result' => 'pong');

    $t->post_ok('/system', json => { jsonrpc => '2.0', id => 2, method => 'status' })
      ->status_is(200)
      ->json_has('/result/app_version')
      ->json_has('/result/hostname')
      ->json_has('/result/running_pid');

    $t->post_ok('/system', json => { jsonrpc => '2.0', id => 3, method => 'version' })
      ->status_is(200)
      ->json_has('/result/software_version');

    $t->post_ok('/system',
        json => { jsonrpc => '2.0', id => 4, method => 'list_methods', params => { plugin => 'system' } })
      ->status_is(200)
      ->json_has('/result');
};

# ---- JSONRPC method parity for untested methods --------------------------

subtest 'JSONRPC report_data parity' => sub {
    my $rest = $t->get_ok("/api/report_data/$rid")
        ->status_is(200)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 10, method => 'report_data', params => { rid => $rid } })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'report_data REST/JSONRPC parity';
};

subtest 'JSONRPC full_report_data parity' => sub {
    my $rest = $t->get_ok("/api/full_report_data/$rid")
        ->status_is(200)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 11, method => 'full_report_data', params => { rid => $rid } })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'full_report_data REST/JSONRPC parity';
};

subtest 'JSONRPC logfile not-found parity' => sub {
    my $rest = $t->get_ok("/api/logfile/$rid")
        ->status_is(404)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 12, method => 'logfile', params => { rid => $rid } })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'logfile not-found REST/JSONRPC parity';
};

subtest 'JSONRPC outfile not-found parity' => sub {
    my $rest = $t->get_ok("/api/outfile/$rid")
        ->status_is(404)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 13, method => 'outfile', params => { rid => $rid } })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'outfile not-found REST/JSONRPC parity';
};

subtest 'JSONRPC reports_from_id parity' => sub {
    my $rest = $t->get_ok("/api/reports_from_id/$rid")
        ->status_is(200)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 14, method => 'reports_from_id', params => { rid => $rid, limit => 100 } })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'reports_from_id REST/JSONRPC parity';
};

subtest 'JSONRPC reports_from_date parity' => sub {
    my $rest = $t->get_ok("/api/reports_from_date/0")
        ->status_is(200)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 15, method => 'reports_from_date', params => { epoch => 0 } })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'reports_from_date REST/JSONRPC parity';
};

subtest 'JSONRPC api.version parity' => sub {
    my $rest = $t->get_ok('/api/version')
        ->status_is(200)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 16, method => 'api.version' })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'api.version REST/JSONRPC parity';
};

subtest 'JSONRPC submatrix parity' => sub {
    my $rest = $t->get_ok('/api/submatrix?test=op/magic.t')
        ->status_is(200)->tx->res->json;
    my $rpc = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 17, method => 'submatrix', params => { test => 'op/magic.t' } })
        ->status_is(200)->tx->res->json->{result};
    is_deeply $rpc, $rest, 'submatrix REST/JSONRPC parity';
};

done_testing;
