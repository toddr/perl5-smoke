package CoreSmoke::App;
use v5.42;
use experimental qw(signatures);
use Mojo::Base 'Mojolicious', -signatures;

use CoreSmoke::Model::DB;
use CoreSmoke::Model::Auth;
use CoreSmoke::Model::Reports;
use CoreSmoke::Model::Ingest;
use CoreSmoke::Model::ReportFiles;

sub startup ($self) {
    $self->plugin('Config' => { file => $self->_config_file });

    $self->routes->namespaces(['CoreSmoke::Controller']);

    my $cfg = $self->config;
    $self->log->level($cfg->{log_level} // 'info');

    $self->secrets($cfg->{secrets}) if $cfg->{secrets};

    my $home = $self->home;
    my $db_path     = _resolve_path($home, $ENV{SMOKE_DB_PATH}     // $cfg->{db_path}     // 'data/smoke.db');
    my $reports_dir = _resolve_path($home, $ENV{SMOKE_REPORTS_DIR} // $cfg->{reports_dir} // 'data/reports');

    # Hypnotoad reads pid_file via Mojo::File::path() which resolves
    # relative paths against cwd, not MOJO_HOME. Rewrite it here so
    # the configured 'data/hypnotoad.pid' lands in the repo regardless
    # of where `make start` was invoked from.
    if (my $pid_file = $cfg->{hypnotoad}{pid_file}) {
        $cfg->{hypnotoad}{pid_file} = _resolve_path($home, $pid_file);
    }

    $self->max_request_size(16 * 1024 * 1024);

    my $sqlite = CoreSmoke::Model::DB->new(
        path           => $db_path,
        migrations_sql => $home->child('lib/CoreSmoke/Schema/migrations.sql'),
    );

    # `auto_migrate` defaults to 1 so the production container
    # (which mounts an empty /data on first boot) and the test suite
    # (which deletes t/test.db between runs) keep working without
    # change. Development mode sets `auto_migrate => 0` so a normal
    # `make start` refuses to silently fabricate an empty DB --
    # operators have to consciously run `make migrate` or one of the
    # `make dev-db` targets.
    if ($cfg->{auto_migrate} // 1) {
        $sqlite->migrate;
    }
    elsif (!-e $db_path) {
        die "DB does not exist at $db_path.\n"
          . "Run `make migrate` to create an empty schema, or `make dev-db SRC=<dump>` to populate from a pg_dump.\n";
    }

    my $report_files = CoreSmoke::Model::ReportFiles->new(
        root   => $reports_dir,
        sqlite => $sqlite,
    );
    my $reports = CoreSmoke::Model::Reports->new(
        sqlite       => $sqlite,
        report_files => $report_files,
    );
    my $auth = CoreSmoke::Model::Auth->new(
        sqlite => $sqlite,
        pepper => $cfg->{admin_secret_salt} // '',
    );
    my $ingest = CoreSmoke::Model::Ingest->new(
        sqlite       => $sqlite,
        report_files => $report_files,
        auth         => $auth,
    );

    $self->helper(sqlite       => sub ($c) { $sqlite });
    $self->helper(report_files => sub ($c) { $report_files });
    $self->helper(reports      => sub ($c) { $reports });
    $self->helper(ingest       => sub ($c) { $ingest });
    $self->helper(auth         => sub ($c) { $auth });

    $self->helper(bearer_token => sub ($c) {
        my $auth_header = $c->req->headers->authorization // return;
        return $1 if $auth_header =~ /^Bearer\s+(\S+)$/i;
        return;
    });

    # Mojolicious doesn't expose Mojo::Util::url_escape as a default
    # helper, but our templates use it for query-string assembly.
    require Mojo::Util;
    require Mojo::ByteStream;
    $self->helper(url_escape => sub ($c, $s) { Mojo::Util::url_escape($s // '') });

    # Tiny helper for option/checkbox state. `print 'selected'` inside
    # an EP `% ... %` code block writes to the controller's stdout, not
    # to the template output, so use `<%= selected_if(...) %>` instead.
    $self->helper(selected_if => sub ($c, $cond) { $cond ? 'selected' : '' });

    # Design system component helpers. See docs/conventions/design-system.md.
    # All UI templates should reach for these (or partials in
    # templates/components/) before inventing markup.

    $self->helper(badge => sub ($c, $text, $variant = '') {
        my $class = 'badge' . ($variant ? " badge-$variant" : '');
        return Mojo::ByteStream->new(sprintf
            '<span class="%s">%s</span>',
            Mojo::Util::xml_escape($class),
            Mojo::Util::xml_escape($text // ''));
    });

    # Map a smoke summary string (PASS, FAIL(M), UNKNOWN, ...) to a badge.
    $self->helper(status_pill => sub ($c, $summary) {
        my $key = lc($summary // '');
        $key =~ s/\(.*//;
        my %variant_for = (
            pass        => 'success',
            fail        => 'danger',
            unknown     => 'warning',
            configerror => 'warning',
        );
        return $c->badge($summary // 'UNKNOWN', $variant_for{$key} // '');
    });

    $self->helper(nav_link => sub ($c, $label, $href) {
        my $path   = $c->req->url->path->to_string;
        my $active = $href eq '/latest'
            ? ($path eq '/' || $path =~ m{^/latest})
            : ($path eq $href || $path =~ m{^\Q$href\E/});
        my $class = 'nav-link' . ($active ? ' active' : '');
        return Mojo::ByteStream->new(sprintf
            '<a class="%s" href="%s">%s</a>',
            $class,
            Mojo::Util::xml_escape($href),
            Mojo::Util::xml_escape($label));
    });

    $self->helper(btn_link => sub ($c, $label, $href, $variant = 'secondary', $size = '') {
        my $class = "btn btn-$variant" . ($size ? " btn-$size" : '');
        return Mojo::ByteStream->new(sprintf
            '<a class="%s" href="%s">%s</a>',
            Mojo::Util::xml_escape($class),
            Mojo::Util::xml_escape($href),
            Mojo::Util::xml_escape($label));
    });

    # Cache-buster: append ?v=<mtime> to a public asset URL so a fresh
    # CSS/JS edit invalidates the browser cache without manual version
    # bumps. Computed once per worker per asset (mtime cached in a
    # closure to avoid stat-ing on every page render).
    my %asset_mtime;
    $self->helper(asset_url => sub ($c, $path) {
        return $path unless $path =~ m{^/};
        unless (exists $asset_mtime{$path}) {
            my $disk = $home->child('public', $path =~ s{^/}{}r);
            $asset_mtime{$path} = -e $disk ? (stat _)[9] : 0;
        }
        my $v = $asset_mtime{$path};
        return $v ? "$path?v=$v" : $path;
    });

    # Insert thousands separators in big integers (e.g. 805449 -> 805,449)
    # Useful for stat-values in hero blocks.
    $self->helper(commify => sub ($c, $n) {
        return '0' unless defined $n && length $n;
        my $s = "$n";
        1 while $s =~ s/^([-+]?\d+)(\d{3})/$1,$2/;
        return $s;
    });

    require POSIX;
    $self->helper(heatmap_ratio => sub ($c, $count) {
        return 0 unless $count && $count > 0;
        my $ratio = POSIX::floor(10 + 20 * POSIX::log10($count));
        $ratio = 80 if $ratio > 80;
        $ratio = 10 if $ratio < 10;
        return $ratio;
    });

    $self->helper(duration_hms => sub ($c, $seconds) {
        return '0s' unless $seconds && $seconds > 0;
        my $h = int($seconds / 3600);
        my $m = int(($seconds % 3600) / 60);
        my $s = $seconds % 60;
        return "${h}h ${m}m ${s}s" if $h;
        return "${m}m ${s}s"       if $m;
        return "${s}s";
    });

    # Translate a Test::Smoke matrix cell letter into a readable
    # explanation. Used as the cell tooltip on /report/:rid so the
    # legend paragraph isn't needed.
    my %SUMMARY_DESC = (
        'O' => 'OK',
        'F' => 'harness failure',
        'X' => 'TEST failure (not under harness)',
        'c' => 'Configure failure',
        'm' => 'make failure',
        'M' => 'make failure after miniperl',
        't' => 'test-prep failure',
        '?' => 'still running or result not available',
        '-' => 'unknown or N/A',
    );
    $self->helper(summary_desc => sub ($c, $letter) {
        $letter //= '';
        return 'N/A' unless length $letter;
        return $SUMMARY_DESC{$letter} // $letter;
    });

    require Crypt::URandom;
    require MIME::Base64;

    $self->hook(before_dispatch => sub ($c) {
        my $nonce = MIME::Base64::encode_base64(Crypt::URandom::urandom(16), '');
        $c->stash('csp_nonce' => $nonce);

        my $enc = $c->req->headers->header('Content-Encoding') // '';
        return unless $enc eq 'gzip';
        require IO::Uncompress::Gunzip;
        require Mojo::Asset::File;
        my $body  = $c->req->body;
        my $limit = $c->app->config->{max_decompressed_size} // 10_000_000;
        my $z = IO::Uncompress::Gunzip->new(\$body)
            or return $c->render(status => 400, json => { error => 'Bad gzip body' });
        my $asset = Mojo::Asset::File->new;
        my $total = 0;
        my $buf;
        while (1) {
            my $n = $z->read($buf, 65536);
            last if !$n;
            if ($n < 0) {
                $z->close;
                return $c->render(status => 400, json => { error => 'Bad gzip body' });
            }
            $total += $n;
            if ($limit && $total > $limit) {
                $z->close;
                return $c->render(status => 413,
                    json => { error => 'Decompressed body too large' });
            }
            $asset->add_chunk($buf);
        }
        $z->close;
        $c->req->content->asset($asset);
        $c->req->headers->remove('Content-Encoding');
    });

    $self->hook(after_dispatch => sub ($c) {
        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('X-Frame-Options'        => 'DENY');

        if (my $nonce = $c->stash('csp_nonce')) {
            $c->res->headers->header('Content-Security-Policy' =>
                "default-src 'self'; "
              . "script-src 'self' 'nonce-$nonce'; "
              . "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
              . "font-src 'self' https://fonts.gstatic.com; "
              . "img-src 'self' data:; "
              . "connect-src 'self'; "
              . "frame-ancestors 'none'");
        }

        my $method = $c->req->method;
        return unless $method eq 'GET' || $method eq 'OPTIONS';
        my $origin = $c->app->config->{cors_allow_origin} // '*';
        $c->res->headers->access_control_allow_origin($origin);
        $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, OPTIONS');
    });

    my $r = $self->routes;

    # Health checks
    $r->get('/healthz')->to('System#healthz');
    $r->get('/readyz') ->to('System#readyz');

    # /system REST
    $r->get('/system/ping')   ->to('System#ping');
    $r->get('/system/version')->to('System#version');
    $r->get('/system/status') ->to('System#status');
    $r->get('/system/methods')->to('System#list_methods');
    $r->get('/system/methods/:plugin')->to('System#list_methods');

    # /api REST
    $r->get('/api/version')                ->to('Api#version');
    $r->get('/api/latest')                 ->to('Api#latest');
    $r->get('/api/full_report_data/:rid')  ->to('Api#full_report_data');
    $r->get('/api/report_data/:rid')       ->to('Api#report_data');
    $r->get('/api/logfile/:rid')           ->to('Api#logfile');
    $r->get('/api/outfile/:rid')           ->to('Api#outfile');
    $r->get('/api/outfle/:rid')            ->to('Api#outfile'); # legacy typo alias
    $r->get('/api/matrix')                 ->to('Api#matrix');
    $r->get('/api/submatrix')              ->to('Api#submatrix');
    $r->get('/api/searchparameters')       ->to('Api#searchparameters');
    $r->any([qw(GET POST)] => '/api/searchresults')->to('Api#searchresults');
    $r->get('/api/reports_from_id/:rid')   ->to('Api#reports_from_id');
    $r->get('/api/reports_from_date/:epoch')->to('Api#reports_from_epoch');

    # OpenAPI
    $r->get('/api/openapi/web.json')->to('Api#openapi_json');
    $r->get('/api/openapi/web.yaml')->to('Api#openapi_yaml');
    $r->get('/api/openapi/web')     ->to('Api#openapi_text');

    # Ingest -- one handler, three URLs. Each accepts both wire formats
    # (form-encoded `json=...` and JSON body `{report_data:...}`) so a
    # client whose config URL doesn't match its wire format still works.
    $r->post('/api/report')             ->to('Ingest#post_report');
    $r->post('/api/old_format_reports') ->to('Ingest#post_report');
    $r->post('/report')                 ->to('Ingest#post_report');

    # JSONRPC
    $r->post('/api')   ->to('JsonRpc#dispatch');
    $r->post('/system')->to('JsonRpc#dispatch');

    # Web (server-rendered HTML)
    $r->get('/')      ->to('Web#latest');
    $r->get('/latest')->to('Web#latest');
    $r->get('/search')->to('Web#search');
    $r->get('/matrix')->to('Web#matrix');
    $r->get('/submatrix')->to('Web#submatrix');
    $r->get('/about') ->to('Web#about');
    $r->get('/report/:rid')          ->to('Web#full_report');
    $r->get('/file/log_file/:rid')   ->to('Web#log_file');
    $r->get('/file/out_file/:rid')   ->to('Web#out_file');

    # Admin: public routes (login/logout)
    $r->get('/admin/login') ->to('Admin#login_page');
    $r->post('/admin/login')->to('Admin#login');
    $r->post('/admin/logout')->to('Admin#logout');

    # Admin: protected routes (session required)
    my $admin = $r->under('/admin')->to('Admin#check_session');
    $admin->get('/dashboard')           ->to('Admin#dashboard');
    $admin->get('/tokens')              ->to('Admin#token_list');
    $admin->get('/tokens/new')          ->to('Admin#token_new');
    $admin->post('/tokens')             ->to('Admin#token_create');
    $admin->get('/tokens/:id')          ->to('Admin#token_show');
    $admin->post('/tokens/:id/cancel')  ->to('Admin#token_cancel');
    $admin->get('/users')               ->to('Admin#user_list');
    $admin->get('/users/new')           ->to('Admin#user_new');
    $admin->post('/users')              ->to('Admin#user_create');
    $admin->post('/users/:id/password') ->to('Admin#user_update_password');
    $admin->post('/users/:id/delete')   ->to('Admin#user_delete');

    # 404 fallback
    $r->any('/*whatever' => { whatever => '' })->to('Web#not_found');
}

sub _config_file ($self) {
    return $ENV{MOJO_CONFIG} if $ENV{MOJO_CONFIG};
    my $mode = $self->mode;
    my $home = $self->home;
    my $mode_file = $home->child("etc/coresmoke.$mode.conf");
    return "$mode_file" if -e $mode_file;
    return $home->child('etc/coresmoke.conf')->to_string;
}

# Resolve a path against MOJO_HOME if it's relative. Absolute paths
# (e.g. `/data/smoke.db` set by the container's ENV) pass through
# unchanged. This lets the same config work both inside the Docker
# image and on a plain repo checkout where the cwd may not be the
# repo root (hypnotoad in particular doesn't preserve a useful cwd).
sub _resolve_path ($home, $path) {
    require File::Spec;
    return File::Spec->file_name_is_absolute($path)
        ? $path
        : $home->child($path)->to_string;
}

1;
