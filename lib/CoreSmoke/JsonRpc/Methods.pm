package CoreSmoke::JsonRpc::Methods;
use v5.42;
use warnings;
use experimental qw(signatures);

# Single source of truth for method dispatch. Both REST controllers and the
# JSONRPC dispatcher route through these closures so the two protocols cannot
# drift apart.
#
# Each entry: { plugin => 'system'|'api', call => sub ($c, $params) }.
# `$c` is the Mojolicious::Controller (so the call has access to helpers).

use Sys::Hostname qw(hostname);

our %METHODS;       # forward-declared; populated below
my $STARTED = time;

sub _system_status ($c, $params) {
    return {
        app_version  => $c->app->config->{app_version} // '2.0',
        app_name     => $c->app->config->{app_name}    // 'Perl 5 Core Smoke DB',
        active_since => $STARTED,
        hostname     => hostname,
        running_pid  => $$,
        # Legacy keys carried for client compatibility; values point at our stack.
        dancer2      => Mojolicious->VERSION,
        rpc_plugin   => 'CoreSmoke::Controller::JsonRpc',
    };
}

sub _system_version ($c, $params) {
    return { software_version => $c->app->config->{app_version} // '2.0' };
}

sub _list_methods ($c, $params) {
    my $filter = $params->{plugin};
    my @names = sort grep {
        !defined($filter) || $METHODS{$_}{plugin} eq $filter
    } keys %METHODS;
    return \@names;
}

%METHODS = (
    # /system plugin
    ping         => { plugin => 'system', call => sub ($c, $p) { 'pong' } },
    status       => { plugin => 'system', call => \&_system_status },
    version      => { plugin => 'system', call => \&_system_version },
    list_methods => { plugin => 'system', call => \&_list_methods },

    # /api plugin
    latest => {
        plugin => 'api',
        call   => sub ($c, $p) {
            $c->app->reports->latest({
                page             => $p->{page},
                reports_per_page => $p->{reports_per_page},
            });
        },
    },
    full_report_data => {
        plugin => 'api',
        call   => sub ($c, $p) {
            $c->app->reports->full_report_data($p->{rid})
                // { error => 'Report not found.' };
        },
    },
    report_data => {
        plugin => 'api',
        call   => sub ($c, $p) {
            $c->app->reports->report_data($p->{rid})
                // { error => 'Report not found.' };
        },
    },
    logfile => {
        plugin => 'api',
        call   => sub ($c, $p) {
            $c->app->reports->logfile($p->{rid})
                // { error => 'Log file not found.' };
        },
    },
    outfile => {
        plugin => 'api',
        call   => sub ($c, $p) {
            $c->app->reports->outfile($p->{rid})
                // { error => 'Out file not found.' };
        },
    },
    matrix    => { plugin => 'api', call => sub ($c, $p) { $c->app->reports->matrix } },
    submatrix => {
        plugin => 'api',
        call   => sub ($c, $p) { $c->app->reports->submatrix($p->{test}, $p->{pversion}) },
    },
    searchparameters => {
        plugin => 'api',
        call   => sub ($c, $p) { $c->app->reports->searchparameters },
    },
    searchresults => {
        plugin => 'api',
        call   => sub ($c, $p) { $c->app->reports->searchresults($p) },
    },
    post_report => {
        plugin => 'api',
        call   => sub ($c, $p) {
            my $token_string = do {
                my $auth = $c->req->headers->authorization // '';
                $auth =~ /^Bearer\s+(\S+)$/i ? $1 : undef;
            };
            $c->app->ingest->post_report(
                $p->{report_data},
                api_token => $token_string,
            );
        },
    },
    reports_from_id => {
        plugin => 'api',
        call   => sub ($c, $p) {
            $c->app->reports->reports_from_id($p->{rid}, $p->{limit} // 100);
        },
    },
    reports_from_date => {
        plugin => 'api',
        call   => sub ($c, $p) {
            $c->app->reports->reports_from_epoch($p->{epoch}, $p->{limit} // 100);
        },
    },
    'api.version' => {
        plugin => 'api',
        call   => sub ($c, $p) { $c->app->reports->version },
    },
);

sub all       { return \%METHODS }
sub method    ($name) { return $METHODS{$name} }
sub names_for ($plugin) {
    return [ sort grep { $METHODS{$_}{plugin} eq $plugin } keys %METHODS ];
}

1;
