package CoreSmoke::Controller::Api;
use v5.42;
use warnings;
use experimental qw(signatures);
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(encode_json);
use CoreSmoke::Model::Search qw(search_params);
use CoreSmoke::Validate qw(positive_int non_negative_int clamp_int);

sub version ($c) {
    return $c->render(json => $c->app->reports->version);
}

sub latest ($c) {
    return $c->render(json => $c->app->reports->latest({
        page             => clamp_int($c->param('page'), 1, 1_000_000, 1),
        reports_per_page => clamp_int($c->param('reports_per_page'), 1, 500, 25),
    }));
}

sub _require_rid ($c) {
    my $rid = positive_int($c->stash('rid'));
    return $rid if $rid;
    $c->render(status => 400, json => { error => 'rid must be a positive integer.' });
    return;
}

sub full_report_data ($c) {
    my $rid = _require_rid($c) // return;
    my $data = $c->app->reports->full_report_data($rid)
        // return $c->render(status => 404, json => { error => 'Report not found.' });
    return $c->render(json => $data);
}

sub report_data ($c) {
    my $rid = _require_rid($c) // return;
    my $data = $c->app->reports->report_data($rid)
        // return $c->render(status => 404, json => { error => 'Report not found.' });
    return $c->render(json => $data);
}

sub logfile ($c) {
    my $rid = _require_rid($c) // return;
    my $data = $c->app->reports->logfile($rid)
        // return $c->render(status => 404, json => { error => 'Log file not found.' });
    return $c->render(json => $data);
}

sub outfile ($c) {
    my $rid = _require_rid($c) // return;
    my $data = $c->app->reports->outfile($rid)
        // return $c->render(status => 404, json => { error => 'Out file not found.' });
    return $c->render(json => $data);
}

sub matrix ($c) {
    return $c->render(json => $c->app->reports->matrix);
}

sub submatrix ($c) {
    my $test = $c->param('test')
        // return $c->render(status => 422, json => { error => 'Missing test param.' });
    return $c->render(json => $c->app->reports->submatrix($test, $c->param('pversion')));
}

sub searchparameters ($c) {
    return $c->render(json => $c->app->reports->searchparameters);
}

sub searchresults ($c) {
    my %params;
    for my $key (search_params()) {
        my $v = $c->param($key);
        $params{$key} = $v if defined $v;
    }
    return $c->render(json => $c->app->reports->searchresults(\%params));
}

sub reports_from_id ($c) {
    my $rid = _require_rid($c) // return;
    my $limit = clamp_int($c->param('limit'), 1, 500, 100);
    return $c->render(json => $c->app->reports->reports_from_id($rid, $limit));
}

sub reports_from_epoch ($c) {
    my $epoch = non_negative_int($c->stash('epoch'));
    return $c->render(status => 400, json => { error => 'epoch must be a non-negative integer.' })
        unless defined $epoch;
    return $c->render(json => $c->app->reports->reports_from_epoch($epoch));
}

# OpenAPI spec served from etc/openapi.yaml. The yaml file is the source of
# truth; we render it as json or yaml or plain text on demand.

sub _spec_path ($c) {
    return $c->app->home->child('etc', 'openapi.yaml');
}

sub openapi_yaml ($c) {
    return $c->render(text => path(_spec_path($c))->slurp,
                      format => 'yaml',
                      'Content-Type' => 'application/yaml');
}

sub openapi_json ($c) {
    require YAML::PP;
    my $spec = YAML::PP::Load(path(_spec_path($c))->slurp);
    return $c->render(json => $spec);
}

sub openapi_text ($c) {
    return $c->render(text => path(_spec_path($c))->slurp,
                      format => 'txt');
}

1;
