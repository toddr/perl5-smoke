package CoreSmoke::Controller::Admin;
use v5.42;
use warnings;
use experimental qw(signatures);
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub check_session ($c) {
    return 1 if $c->session('admin_user');
    $c->redirect_to('/admin/login');
    return;
}

sub login_page ($c) {
    $c->render(template => 'admin/login');
}

sub login ($c) {
    my $v = $c->validation;
    $v->csrf_protect;
    if ($v->has_error('csrf_token')) {
        return $c->render(template => 'admin/login', error => 'Invalid form submission.');
    }

    my $username = $c->param('username') // '';
    my $password = $c->param('password') // '';

    if ($c->app->auth->verify_user($username, $password)) {
        $c->session(admin_user => $username);
        return $c->redirect_to('/admin/dashboard');
    }

    $c->render(template => 'admin/login', error => 'Invalid username or password.');
}

sub logout ($c) {
    $c->session(expires => 1);
    $c->redirect_to('/admin/login');
}

sub dashboard ($c) {
    my $db = $c->app->sqlite->db;

    my $user_count  = $db->query("SELECT COUNT(*) AS cnt FROM admin_user")->hash->{cnt};
    my $token_count = $db->query("SELECT COUNT(*) AS cnt FROM api_token WHERE cancelled_at IS NULL")->hash->{cnt};

    my $top_tokens = $db->query(q{
        SELECT id, note, email, use_count, last_used_at
        FROM api_token
        WHERE cancelled_at IS NULL AND use_count > 0
        ORDER BY use_count DESC
        LIMIT 5
    })->hashes->to_array;

    $c->render(template => 'admin/dashboard',
        user_count  => $user_count,
        token_count => $token_count,
        top_tokens  => $top_tokens,
    );
}

# --- Token CRUD ---

sub token_list ($c) {
    my $tokens = $c->app->auth->list_tokens;
    $c->render(template => 'admin/token_list', tokens => $tokens);
}

sub token_new ($c) {
    $c->render(template => 'admin/token_new');
}

sub token_create ($c) {
    my $v = $c->validation;
    $v->csrf_protect;
    if ($v->has_error('csrf_token')) {
        return $c->render(template => 'admin/token_new', error => 'Invalid form submission.');
    }

    my $note  = $c->param('note')  // '';
    my $email = $c->param('email') // '';
    my $tok   = $c->app->auth->create_token(note => $note, email => $email);
    $c->render(template => 'admin/token_created', token => $tok);
}

sub token_show ($c) {
    my $id  = $c->stash('id');
    my $tok = $c->app->auth->get_token($id)
        // return $c->render(status => 404, template => 'web/404');
    $c->render(template => 'admin/token_show', token => $tok);
}

sub token_cancel ($c) {
    my $v = $c->validation;
    $v->csrf_protect;
    if ($v->has_error('csrf_token')) {
        $c->flash(error => 'Invalid form submission.');
        return $c->redirect_to('/admin/tokens');
    }
    my $id = $c->stash('id');
    $c->app->auth->cancel_token($id);
    $c->redirect_to('/admin/tokens');
}

# --- User CRUD ---

sub user_list ($c) {
    my $users = $c->app->auth->list_users;
    $c->render(template => 'admin/user_list', users => $users, current_user => $c->session('admin_user'));
}

sub user_new ($c) {
    $c->render(template => 'admin/user_new');
}

sub user_create ($c) {
    my $v = $c->validation;
    $v->csrf_protect;
    if ($v->has_error('csrf_token')) {
        return $c->render(template => 'admin/user_new', error => 'Invalid form submission.');
    }

    my $username = $c->param('username') // '';
    my $password = $c->param('password') // '';

    unless (length $username && length $password) {
        return $c->render(template => 'admin/user_new', error => 'Username and password are required.');
    }

    my $res = $c->app->auth->create_user($username, $password);
    if ($res->{error}) {
        return $c->render(template => 'admin/user_new', error => $res->{error});
    }
    $c->redirect_to('/admin/users');
}

sub user_update_password ($c) {
    my $v = $c->validation;
    $v->csrf_protect;
    if ($v->has_error('csrf_token')) {
        $c->flash(error => 'Invalid form submission.');
        return $c->redirect_to('/admin/users');
    }
    my $id       = $c->stash('id');
    my $password = $c->param('password') // '';

    unless (length $password) {
        $c->flash(error => 'Password cannot be empty.');
        return $c->redirect_to('/admin/users');
    }

    my $user = $c->app->sqlite->db->query(
        "SELECT username FROM admin_user WHERE id = ?", $id,
    )->hash;
    if ($user) {
        $c->app->auth->update_password($user->{username}, $password);
    }
    $c->redirect_to('/admin/users');
}

sub user_delete ($c) {
    my $v = $c->validation;
    $v->csrf_protect;
    if ($v->has_error('csrf_token')) {
        $c->flash(error => 'Invalid form submission.');
        return $c->redirect_to('/admin/users');
    }
    my $id = $c->stash('id');

    my $user = $c->app->sqlite->db->query(
        "SELECT username FROM admin_user WHERE id = ?", $id,
    )->hash;

    if ($user) {
        if ($user->{username} eq $c->session('admin_user')) {
            $c->flash(error => 'Cannot delete your own account.');
            return $c->redirect_to('/admin/users');
        }
        my $res = $c->app->auth->delete_user($user->{username});
        $c->flash(error => $res->{error}) if $res->{error};
    }
    $c->redirect_to('/admin/users');
}

1;
