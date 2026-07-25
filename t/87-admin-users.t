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

# Bootstrap admin and log in
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

admin_login();

subtest 'user list shows initial admin' => sub {
    $t->get_ok('/admin/users')
      ->status_is(200)
      ->content_like(qr/admin/);
};

subtest 'create second user via form' => sub {
    $t->get_ok('/admin/users/new')->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

    $t->post_ok('/admin/users', form => {
        csrf_token => $csrf,
        username   => 'operator',
        password   => 'oppass',
    })->status_is(302);

    $t->get_ok('/admin/users')
      ->status_is(200)
      ->content_like(qr/operator/);
};

subtest 'list shows both users' => sub {
    my $users = $h->app->auth->list_users;
    is scalar(@$users), 2, 'two users in list';
};

sub get_csrf {
    $t->get_ok('/admin/users')->status_is(200);
    return $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');
}

subtest 'update password without CSRF rejected' => sub {
    my $users = $h->app->auth->list_users;
    my ($op) = grep { $_->{username} eq 'operator' } @$users;

    $t->post_ok("/admin/users/$op->{id}/password", form => {
        password => 'hackedpass',
    })->status_is(302);

    $t->get_ok('/admin/users')
      ->content_like(qr/Invalid form submission/);

    ok $h->app->auth->verify_user('operator', 'oppass'), 'password unchanged after CSRF block';
};

subtest 'update password with CSRF succeeds' => sub {
    my $users = $h->app->auth->list_users;
    my ($op) = grep { $_->{username} eq 'operator' } @$users;
    my $csrf = get_csrf();

    $t->post_ok("/admin/users/$op->{id}/password", form => {
        csrf_token => $csrf,
        password   => 'newoppass',
    })->status_is(302);

    ok $h->app->auth->verify_user('operator', 'newoppass'), 'new password works';
    ok !$h->app->auth->verify_user('operator', 'oppass'), 'old password rejected';
};

subtest 'delete without CSRF rejected' => sub {
    my $users = $h->app->auth->list_users;
    my ($op) = grep { $_->{username} eq 'operator' } @$users;

    $t->post_ok("/admin/users/$op->{id}/delete")
      ->status_is(302);

    $t->get_ok('/admin/users')
      ->content_like(qr/Invalid form submission/);

    my $after = $h->app->auth->list_users;
    is scalar(@$after), 2, 'user not deleted without CSRF';
};

subtest 'self-deletion blocked' => sub {
    my $users = $h->app->auth->list_users;
    my ($me) = grep { $_->{username} eq 'admin' } @$users;
    my $csrf = get_csrf();

    $t->post_ok("/admin/users/$me->{id}/delete", form => {
        csrf_token => $csrf,
    })->status_is(302);

    my $after = $h->app->auth->list_users;
    ok((grep { $_->{username} eq 'admin' } @$after), 'admin user still exists');
};

subtest 'delete second user with CSRF' => sub {
    my $users = $h->app->auth->list_users;
    my ($op) = grep { $_->{username} eq 'operator' } @$users;
    my $csrf = get_csrf();

    $t->post_ok("/admin/users/$op->{id}/delete", form => {
        csrf_token => $csrf,
    })->status_is(302);

    my $after = $h->app->auth->list_users;
    is scalar(@$after), 1, 'back to one user';
    ok !$h->app->auth->verify_user('operator', 'newoppass'), 'deleted user cannot log in';
};

done_testing;
