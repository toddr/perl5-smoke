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

$h->app->auth->create_user('admin', 'testpass');

sub admin_login {
    $t->get_ok('/admin/login')->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
    $t->post_ok('/admin/login', form => {
        csrf_token => $csrf,
        username   => 'admin',
        password   => 'testpass',
    })->status_is(302);
}

# --------------- Login CSRF rejection ---------------

subtest 'login rejects invalid CSRF token' => sub {
    $t->get_ok('/admin/login')->status_is(200);

    $t->post_ok('/admin/login', form => {
        csrf_token => 'bogus-token-value',
        username   => 'admin',
        password   => 'testpass',
    })->status_is(200)
      ->content_like(qr/Invalid form submission/);
};

subtest 'login rejects missing CSRF token' => sub {
    $t->get_ok('/admin/login')->status_is(200);

    $t->post_ok('/admin/login', form => {
        username => 'admin',
        password => 'testpass',
    })->status_is(200)
      ->content_like(qr/Invalid form submission/);
};

admin_login();

# --------------- Token CRUD edge cases ---------------

subtest 'token_create rejects invalid CSRF' => sub {
    $t->get_ok('/admin/tokens/new')->status_is(200);

    $t->post_ok('/admin/tokens', form => {
        csrf_token => 'wrong-csrf',
        note       => 'should fail',
        email      => 'bad@example.com',
    })->status_is(200)
      ->content_like(qr/Invalid form submission/);

    my $tokens = $h->app->auth->list_tokens;
    is scalar(@$tokens), 0, 'no token created on CSRF failure';
};

subtest 'token_show returns 404 for nonexistent id' => sub {
    $t->get_ok('/admin/tokens/99999')
      ->status_is(404);
};

subtest 'token_cancel on nonexistent id does not error' => sub {
    $t->post_ok('/admin/tokens/99999/cancel')
      ->status_is(302)
      ->header_like('Location' => qr{/admin/tokens});
};

# --------------- User CRUD edge cases ---------------

subtest 'user_create rejects invalid CSRF' => sub {
    $t->get_ok('/admin/users/new')->status_is(200);

    $t->post_ok('/admin/users', form => {
        csrf_token => 'wrong-csrf',
        username   => 'intruder',
        password   => 'intruderpass',
    })->status_is(200)
      ->content_like(qr/Invalid form submission/);

    my $users = $h->app->auth->list_users;
    is scalar(@$users), 1, 'no user created on CSRF failure';
};

subtest 'user_create rejects empty username' => sub {
    $t->get_ok('/admin/users/new')->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

    $t->post_ok('/admin/users', form => {
        csrf_token => $csrf,
        username   => '',
        password   => 'somepass',
    })->status_is(200)
      ->content_like(qr/Username and password are required/);
};

subtest 'user_create rejects empty password' => sub {
    $t->get_ok('/admin/users/new')->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

    $t->post_ok('/admin/users', form => {
        csrf_token => $csrf,
        username   => 'newuser',
        password   => '',
    })->status_is(200)
      ->content_like(qr/Username and password are required/);
};

subtest 'user_create rejects duplicate username' => sub {
    $t->get_ok('/admin/users/new')->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

    $t->post_ok('/admin/users', form => {
        csrf_token => $csrf,
        username   => 'admin',
        password   => 'anotherpass',
    })->status_is(200)
      ->content_like(qr/error|already exists/i);
};

subtest 'user_update_password rejects empty password' => sub {
    my $users = $h->app->auth->list_users;
    my ($me) = grep { $_->{username} eq 'admin' } @$users;

    $t->post_ok("/admin/users/$me->{id}/password", form => {
        password => '',
    })->status_is(302)
      ->header_like('Location' => qr{/admin/users});

    ok $h->app->auth->verify_user('admin', 'testpass'),
       'password unchanged after empty submission';
};

subtest 'user_delete for nonexistent id redirects without error' => sub {
    $t->post_ok('/admin/users/99999/delete')
      ->status_is(302)
      ->header_like('Location' => qr{/admin/users});

    my $users = $h->app->auth->list_users;
    is scalar(@$users), 1, 'user list unchanged';
};

done_testing;
