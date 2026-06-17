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

# Basic dispatch
$t->post_ok('/api', json => { jsonrpc => '2.0', id => 1, method => 'ping' })
  ->status_is(200)
  ->json_is('/jsonrpc' => '2.0')
  ->json_is('/id'      => 1)
  ->json_is('/result'  => 'pong');

$t->post_ok('/api', json => { jsonrpc => '2.0', id => 2, method => 'version' })
  ->status_is(200)
  ->json_is('/result/software_version' => '2.0');

# REST <-> JSONRPC parity for empty-DB endpoints
my $rest_latest = $t->get_ok('/api/latest')->status_is(200)->tx->res->json;
my $rpc_latest  = $t->post_ok('/api',
    json => { jsonrpc => '2.0', id => 3, method => 'latest' })
    ->status_is(200)->tx->res->json->{result};
is_deeply $rpc_latest, $rest_latest, 'latest parity';

my $rest_sp = $t->get_ok('/api/searchparameters')->tx->res->json;
my $rpc_sp  = $t->post_ok('/api',
    json => { jsonrpc => '2.0', id => 4, method => 'searchparameters' })
    ->tx->res->json->{result};
is_deeply $rpc_sp, $rest_sp, 'searchparameters parity';

my $rest_matrix = $t->get_ok('/api/matrix')->tx->res->json;
my $rpc_matrix  = $t->post_ok('/api',
    json => { jsonrpc => '2.0', id => 5, method => 'matrix' })
    ->tx->res->json->{result};
is_deeply $rpc_matrix, $rest_matrix, 'matrix parity';

# Unknown method -> -32601
$t->post_ok('/api', json => { jsonrpc => '2.0', id => 6, method => 'no_such_method' })
  ->status_is(200)
  ->json_is('/error/code' => -32601);

# Batch request
my $batch = $t->post_ok('/api', json => [
    { jsonrpc => '2.0', id => 'a', method => 'ping' },
    { jsonrpc => '2.0', id => 'b', method => 'version' },
])->status_is(200)->tx->res->json;
is ref $batch, 'ARRAY', 'batch returns array';
is scalar(@$batch), 2, 'batch has 2 responses';
is $batch->[0]{id}, 'a', 'first id preserved';
is $batch->[0]{result}, 'pong', 'first result is pong';
is $batch->[1]{id}, 'b', 'second id preserved';
is $batch->[1]{result}{software_version}, '2.0', 'second result has version';

# Application-level errors stay inside `result`, not in the JSONRPC error envelope
my $not_found = $t->post_ok('/api',
    json => { jsonrpc => '2.0', id => 7, method => 'full_report_data', params => { rid => 9999 } })
    ->status_is(200)->tx->res->json;
is $not_found->{result}{error}, 'Report not found.',
   'application errors land in result, not transport error';

# list_methods registry
my $lm = $t->post_ok('/api',
    json => { jsonrpc => '2.0', id => 8, method => 'list_methods' })
    ->tx->res->json->{result};
ok( (grep { $_ eq 'ping' }   @$lm), 'list_methods includes ping');
ok( (grep { $_ eq 'latest' } @$lm), 'list_methods includes latest');

my $api_only = $t->post_ok('/api',
    json => { jsonrpc => '2.0', id => 9, method => 'list_methods', params => { plugin => 'api' } })
    ->tx->res->json->{result};
ok !(grep { $_ eq 'ping' } @$api_only), 'api filter excludes ping';

# Oversized batch rejected
subtest 'batch size cap' => sub {
    my @oversized = map { { jsonrpc => '2.0', id => $_, method => 'ping' } } 1..101;
    $t->post_ok('/api', json => \@oversized)
      ->status_is(200)
      ->json_is('/error/code' => -32600)
      ->json_like('/error/message' => qr/Batch too large/);

    my @ok_batch = map { { jsonrpc => '2.0', id => $_, method => 'ping' } } 1..100;
    my $res = $t->post_ok('/api', json => \@ok_batch)
      ->status_is(200)->tx->res->json;
    is ref $res, 'ARRAY', 'batch of 100 accepted';
    is scalar @$res, 100, 'all 100 responses returned';
};

# Internal errors must NOT leak implementation details (CVE-worthy info disclosure)
subtest 'internal error hides exception details' => sub {
    # Temporarily register a method that dies with a recognizable internal message
    no warnings 'once';
    local $CoreSmoke::JsonRpc::Methods::METHODS{'_test_die'} = {
        plugin => 'system',
        call   => sub ($c, $p) { die "secret: DB path is /opt/smoke/data.db\n" },
    };

    my $res = $t->post_ok('/api',
        json => { jsonrpc => '2.0', id => 99, method => '_test_die' })
        ->status_is(200)
        ->json_is('/error/code' => -32603)
        ->tx->res->json;

    my $msg = $res->{error}{message};
    unlike $msg, qr/secret/,   'error message does not leak exception text';
    unlike $msg, qr/DB path/,  'error message does not leak internal paths';
    like   $msg, qr/Internal/, 'error message is generic';
};

done_testing;
