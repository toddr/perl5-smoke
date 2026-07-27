package CoreSmoke::Controller::JsonRpc;
use v5.42;
use warnings;
use experimental qw(signatures);
use Mojo::Base 'Mojolicious::Controller', -signatures;

use CoreSmoke::JsonRpc::Methods;

sub dispatch ($c) {
    my $req = $c->req->json;
    return _reply($c, undef, _err(-32700, 'Parse error.'))
        unless defined $req;

    return _batch($c, $req)  if ref $req eq 'ARRAY';
    return _single($c, $req) if ref $req eq 'HASH';
    return _reply($c, undef, _err(-32600, 'Invalid Request.'));
}

sub _single ($c, $req) {
    my ($payload) = _single_payload($c, $req);

    # JSON-RPC 2.0 sec 4.1: notifications (no "id" member) MUST NOT
    # receive a reply. Execute the method for side effects, then return
    # 204 No Content.
    if (ref $req eq 'HASH' && !exists $req->{id}) {
        return $c->rendered(204);
    }

    return _reply($c, $req->{id}, $payload);
}

sub _batch ($c, $reqs) {
    my @out;
    for my $req (@$reqs) {
        my ($payload) = _single_payload($c, $req);

        # JSON-RPC 2.0 sec 6: notifications in a batch MUST NOT produce
        # a Response object.
        next if ref $req eq 'HASH' && !exists $req->{id};

        push @out, {
            jsonrpc => '2.0',
            id      => (ref $req eq 'HASH' ? $req->{id} : undef),
            %$payload,
        };
    }

    # Spec: "If there are no Response objects [...] the server MUST NOT
    # return an empty Array and should return nothing at all."
    return $c->rendered(204) unless @out;

    return $c->render(json => \@out);
}

sub _single_payload ($c, $req) {
    return _err(-32600, 'Invalid Request.') unless ref $req eq 'HASH';

    my $method = $req->{method} // '';
    my $params = $req->{params} // {};

    # JSON-RPC 2.0 sec 4: params MUST be a Structured value (Object or
    # Array). Scalars are invalid.
    if (exists $req->{params} && ref $params ne 'HASH' && ref $params ne 'ARRAY') {
        return _err(-32602, 'Invalid params: must be object or array.');
    }

    my $entry = CoreSmoke::JsonRpc::Methods::method($method);
    return _err(-32601, "Method '$method' not found.") unless $entry;

    my $result = eval { $entry->{call}->($c, $params) };
    if (my $e = $@) {
        $c->app->log->error("JSONRPC $method failed: $e");
        return _err(-32603, "Internal error");
    }
    return { result => $result };
}

sub _reply ($c, $id, $payload) {
    return $c->render(json => {
        jsonrpc => '2.0',
        id      => $id,
        %$payload,
    });
}

sub _err ($code, $message, $data = undef) {
    my %err = (code => $code, message => $message);
    $err{data} = $data if defined $data;
    return { error => \%err };
}

1;
