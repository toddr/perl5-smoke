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
    return _reply($c, $req->{id}, $payload);
}

sub _batch ($c, $reqs) {
    my @out;
    for my $req (@$reqs) {
        my ($payload) = _single_payload($c, $req);
        push @out, {
            jsonrpc => '2.0',
            id      => (ref $req eq 'HASH' ? $req->{id} : undef),
            %$payload,
        };
    }
    return $c->render(json => \@out);
}

sub _single_payload ($c, $req) {
    return _err(-32600, 'Invalid Request.') unless ref $req eq 'HASH';

    my $method = $req->{method} // '';
    my $params = $req->{params} // {};

    my $entry = CoreSmoke::JsonRpc::Methods::method($method);
    return _err(-32601, "Method '$method' not found.") unless $entry;

    my $result = eval { $entry->{call}->($c, $params) };
    if (my $e = $@) {
        if (ref $e eq 'HASH' && $e->{code}) {
            return _err($e->{code}, $e->{message});
        }
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
