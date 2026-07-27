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

# ---------------------------------------------------------------------------
# Notifications (JSON-RPC 2.0 sec 4.1)
# A notification is a request without an "id" member. The server MUST NOT
# reply to a notification.
# ---------------------------------------------------------------------------

subtest 'single notification returns 204 No Content' => sub {
    $t->post_ok('/api', json => { jsonrpc => '2.0', method => 'ping' })
      ->status_is(204)
      ->content_is('', 'no response body for notification');
};

subtest 'notification with id => undef is NOT a notification' => sub {
    $t->post_ok('/api', json => { jsonrpc => '2.0', id => undef, method => 'ping' })
      ->status_is(200)
      ->json_is('/result' => 'pong')
      ->json_is('/id'     => undef, 'id: null preserved in response');
};

# ---------------------------------------------------------------------------
# Batch with notifications (JSON-RPC 2.0 sec 6)
# Notifications in a batch MUST NOT produce Response objects.
# ---------------------------------------------------------------------------

subtest 'batch filters out notification responses' => sub {
    my $batch = $t->post_ok('/api', json => [
        { jsonrpc => '2.0', id => 'a', method => 'ping' },
        { jsonrpc => '2.0',           method => 'version' },
        { jsonrpc => '2.0', id => 'c', method => 'ping' },
    ])->status_is(200)->tx->res->json;

    is ref $batch, 'ARRAY', 'batch returns array';
    is scalar(@$batch), 2, 'only 2 responses (notification filtered)';
    is $batch->[0]{id}, 'a', 'first response id';
    is $batch->[1]{id}, 'c', 'second response id (notification skipped)';
};

subtest 'all-notification batch returns 204' => sub {
    $t->post_ok('/api', json => [
        { jsonrpc => '2.0', method => 'ping' },
        { jsonrpc => '2.0', method => 'version' },
    ])->status_is(204)
      ->content_is('', 'no body for all-notification batch');
};

# ---------------------------------------------------------------------------
# Invalid params (JSON-RPC 2.0 sec 4)
# params MUST be a Structured value (Object or Array) when present.
# ---------------------------------------------------------------------------

subtest 'params as string returns -32602' => sub {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 1, method => 'ping', params => 'bad',
    })->status_is(200)
      ->json_is('/error/code' => -32602)
      ->json_like('/error/message' => qr/object or array/i);
};

subtest 'params as number returns -32602' => sub {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 2, method => 'ping', params => 42,
    })->status_is(200)
      ->json_is('/error/code' => -32602);
};

subtest 'params as array is accepted' => sub {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 3, method => 'ping', params => [],
    })->status_is(200)
      ->json_is('/result' => 'pong');
};

subtest 'params omitted is accepted' => sub {
    $t->post_ok('/api', json => {
        jsonrpc => '2.0', id => 4, method => 'ping',
    })->status_is(200)
      ->json_is('/result' => 'pong');
};

# ---------------------------------------------------------------------------
# Malformed input (JSON-RPC 2.0 error codes)
# ---------------------------------------------------------------------------

subtest 'non-JSON body returns parse error -32700' => sub {
    $t->post_ok('/api',
        { 'Content-Type' => 'application/json' },
        'this is not json')
      ->status_is(200)
      ->json_is('/error/code' => -32700);
};

subtest 'scalar JSON (not object or array) returns invalid request' => sub {
    $t->post_ok('/api',
        { 'Content-Type' => 'application/json' },
        '"just a string"')
      ->status_is(200)
      ->json_is('/error/code' => -32600);
};

done_testing;
