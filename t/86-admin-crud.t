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

subtest 'token list (empty)' => sub {
    $t->get_ok('/admin/tokens')
      ->status_is(200)
      ->content_like(qr/No tokens yet/);
};

subtest 'create token' => sub {
    $t->get_ok('/admin/tokens/new')->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

    $t->post_ok('/admin/tokens', form => {
        csrf_token => $csrf,
        note       => 'CI smoker',
        email      => 'ci@example.com',
    })->status_is(200)
      ->content_like(qr/Token Created/)
      ->content_like(qr/Copy this token now/);

    my $token_text = $t->tx->res->dom->at('#token-value')->text;
    like $token_text, qr/^[a-f0-9]{64}$/, 'token is 64 hex chars';
};

subtest 'token list (one token)' => sub {
    $t->get_ok('/admin/tokens')
      ->status_is(200)
      ->content_like(qr/CI smoker/)
      ->content_like(qr/Active/);
};

subtest 'token show' => sub {
    my $tokens = $h->app->auth->list_tokens;
    my $id = $tokens->[0]{id};

    $t->get_ok("/admin/tokens/$id")
      ->status_is(200)
      ->content_like(qr/CI smoker/)
      ->content_like(qr/ci\@example\.com/);
};

subtest 'cancel token without CSRF rejected' => sub {
    my $tokens = $h->app->auth->list_tokens;
    my $id = $tokens->[0]{id};

    $t->post_ok("/admin/tokens/$id/cancel")
      ->status_is(302);

    $t->get_ok('/admin/tokens')
      ->status_is(200)
      ->content_like(qr/Invalid form submission/);

    ok $h->app->auth->validate_token($tokens->[0]{token}),
       'token still valid after CSRF-blocked cancel';
};

subtest 'cancel token with CSRF succeeds' => sub {
    my $tokens = $h->app->auth->list_tokens;
    my $id = $tokens->[0]{id};

    $t->get_ok("/admin/tokens/$id")->status_is(200);
    my $csrf = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

    $t->post_ok("/admin/tokens/$id/cancel", form => {
        csrf_token => $csrf,
    })->status_is(302);

    $t->get_ok('/admin/tokens')
      ->status_is(200)
      ->content_like(qr/Cancelled/);

    ok !$h->app->auth->validate_token($tokens->[0]{token}),
       'cancelled token rejected by validate_token';
};

done_testing;
