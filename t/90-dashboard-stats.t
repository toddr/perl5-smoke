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
$h->app->auth->create_user('operator', 'oppass');

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

subtest 'dashboard reflects correct user count' => sub {
    $t->get_ok('/admin/dashboard')
      ->status_is(200)
      ->content_like(qr/2\b.*\busers?\b/si, 'shows 2 users');
};

subtest 'dashboard reflects correct active token count' => sub {
    my $tok1 = $h->app->auth->create_token(note => 'ci-bot',  email => 'ci@test.org');
    my $tok2 = $h->app->auth->create_token(note => 'nightly', email => 'night@test.org');
    my $tok3 = $h->app->auth->create_token(note => 'stale',   email => 'gone@test.org');

    # Cancel one token so it doesn't count as active
    $h->app->auth->cancel_token($tok3->{id});

    $t->get_ok('/admin/dashboard')
      ->status_is(200);

    # The dashboard card shows "Active API Tokens" as heading and the
    # count in a .stat-value element. Check that the stat-value inside
    # the token card reads "2" (3 created minus 1 cancelled).
    my $dom = $t->tx->res->dom;
    my @cards = $dom->find('.card')->each;
    my ($token_card) = grep { ($_->at('h3') // '') =~ /API Tokens/ } @cards;
    ok $token_card, 'found Active API Tokens card';
    my $count = $token_card ? $token_card->at('.stat-value')->text : '';
    $count =~ s/\s+//g;
    is $count, '2', 'token count is 2 (cancelled excluded)';
};

subtest 'dashboard top tokens sorted by use_count DESC' => sub {
    my $db = $h->app->sqlite->db;

    # Bump use_count on the tokens so they appear in the top list
    my $tokens = $h->app->auth->list_tokens;
    my @active = grep { !$_->{cancelled_at} } @$tokens;

    # Give different use counts: ci-bot=10, nightly=3
    for my $tok (@active) {
        my $count = $tok->{note} eq 'ci-bot' ? 10 : 3;
        $db->query(
            "UPDATE api_token SET use_count = ?, last_used_at = strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id = ?",
            $count, $tok->{id},
        );
    }

    $t->get_ok('/admin/dashboard')
      ->status_is(200);

    my $dom = $t->tx->res->dom;

    # The top-tokens table should list ci-bot before nightly
    my $body = $t->tx->res->body;
    my $ci_pos = index($body, 'ci-bot');
    my $night_pos = index($body, 'nightly');
    ok $ci_pos >= 0 && $night_pos >= 0, 'both active tokens appear on dashboard';
    ok $ci_pos < $night_pos, 'ci-bot (use_count=10) listed before nightly (use_count=3)';

    # Cancelled token should NOT appear in the top list
    unlike $body, qr/\bstale\b/, 'cancelled token excluded from top list';
};

done_testing;
