package CoreSmoke::Controller::Ingest;
use v5.42;
use warnings;
use experimental qw(signatures);
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON qw(decode_json);

# Single ingest handler reachable from three routes:
#   POST /api/report             (modern Test::Smoke >= 1.81_01 default URL)
#   POST /api/old_format_reports (explicit legacy alias)
#   POST /report                 (Fastly-redirect target / legacy default URL)
#
# Test::Smoke clients pick the wire format from the URL: a path containing
# `/api/` posts `application/json` body `{"report_data": <report>}`, anything
# else posts `application/x-www-form-urlencoded` with `json=<percent-encoded
# JSON>`. A smoker with mismatched config (upgraded client + old URL, or
# vice versa) ends up sending the "wrong" format to a path, so each route
# accepts both and dispatches on the request's Content-Type.
sub post_report ($c) {
    my ($data, $err, $status) = _extract_report_data($c);
    return $c->render(status => $status, json => { error => $err }) if $err;

    my $token_string = _extract_bearer_token($c);
    my $result = $c->app->ingest->post_report($data, api_token => $token_string);
    return $c->render(status => 409, json => $result) if $result->{error};
    return $c->render(json => $result);
}

sub _extract_report_data ($c) {
    my $ct = $c->req->headers->content_type // '';

    if ($ct =~ m{^application/x-www-form-urlencoded}i) {
        my $raw = $c->req->param('json')
            // return (undef, 'Missing json param.', 422);
        my $data = eval { decode_json($raw) };
        if ($@) {
            (my $detail = "$@") =~ s/ at \S+ line \d+\.?\s*$//;
            return (undef, "Bad JSON in 'json' param: $detail", 400);
        }
        return ($data, undef, undef);
    }

    my $body = $c->req->body;
    return (undef, 'Missing report data (expected form `json=` or JSON `report_data`).', 422)
        unless defined $body && length $body;

    my $payload = eval { decode_json($body) };
    return (undef, 'Invalid JSON.', 400) if $@;
    my $data = $payload->{report_data}
        // return (undef, 'Missing report_data.', 422);
    return ($data, undef, undef);
}

sub _extract_bearer_token ($c) {
    my $auth = $c->req->headers->authorization // return;
    return $1 if $auth =~ /^Bearer\s+(\S+)$/i;
    return;
}

1;
