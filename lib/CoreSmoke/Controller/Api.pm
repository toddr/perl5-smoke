package CoreSmoke::Controller::Api;
use v5.42;
use warnings;
use experimental qw(signatures);
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::File qw(path);
use Mojo::JSON qw(encode_json);
use CoreSmoke::Model::Search qw(search_params);

sub version ($c) {
    return $c->render(json => $c->app->reports->version);
}

sub latest ($c) {
    return $c->render(json => $c->app->reports->latest({
        page             => $c->param('page'),
        reports_per_page => $c->param('reports_per_page'),
        selected_summary => $c->param('selected_summary'),
    }));
}

sub full_report_data ($c) {
    my $data = $c->app->reports->full_report_data($c->stash('rid'))
        // return $c->render(status => 404, json => { error => 'Report not found.' });
    return $c->render(json => $data);
}

sub report_data ($c) {
    my $data = $c->app->reports->report_data($c->stash('rid'))
        // return $c->render(status => 404, json => { error => 'Report not found.' });
    return $c->render(json => $data);
}

sub logfile ($c) {
    my $data = $c->app->reports->logfile($c->stash('rid'))
        // return $c->render(status => 404, json => { error => 'Log file not found.' });
    return $c->render(json => $data);
}

sub outfile ($c) {
    my $data = $c->app->reports->outfile($c->stash('rid'))
        // return $c->render(status => 404, json => { error => 'Out file not found.' });
    return $c->render(json => $data);
}

sub matrix ($c) {
    my $include_stdio = $c->param('include_stdio') ? 1 : 0;
    return $c->render(json => $c->app->reports->matrix(include_stdio => $include_stdio));
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
    return $c->render(json => $c->app->reports->reports_from_id(
        $c->stash('rid'), $c->param('limit') // 100,
    ));
}

sub reports_from_epoch ($c) {
    return $c->render(json => $c->app->reports->reports_from_epoch($c->stash('epoch')));
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
