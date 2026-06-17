use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;

my $h   = TestApp->new;
my $app = $h->app;

subtest 'no warning for non-placeholder secrets' => sub {
    my @log;
    $app->log->on(message => sub ($log, $level, @msg) {
        push @log, [$level, @msg] if $level eq 'warn';
    });

    $app->_warn_default_secrets({
        secrets           => ['properly-randomized-value'],
        admin_secret_salt => 'unique-pepper-abc123',
    });

    is scalar @log, 0, 'no warnings emitted';
    $app->log->unsubscribe('message');
};

subtest 'warns on default session secret' => sub {
    my @log;
    $app->log->on(message => sub ($log, $level, @msg) {
        push @log, [$level, @msg] if $level eq 'warn';
    });

    $app->_warn_default_secrets({
        secrets           => ['change-me-in-production'],
        admin_secret_salt => 'unique-pepper-abc123',
    });

    is scalar @log, 1, 'one warning emitted';
    like $log[0][1], qr/SMOKE_SESSION_SECRET/, 'warning mentions session secret';
    $app->log->unsubscribe('message');
};

subtest 'warns on default admin salt' => sub {
    my @log;
    $app->log->on(message => sub ($log, $level, @msg) {
        push @log, [$level, @msg] if $level eq 'warn';
    });

    $app->_warn_default_secrets({
        secrets           => ['properly-randomized-value'],
        admin_secret_salt => 'change-me-in-production',
    });

    is scalar @log, 1, 'one warning emitted';
    like $log[0][1], qr/SMOKE_ADMIN_SALT/, 'warning mentions admin salt';
    $app->log->unsubscribe('message');
};

subtest 'warns on both defaults' => sub {
    my @log;
    $app->log->on(message => sub ($log, $level, @msg) {
        push @log, [$level, @msg] if $level eq 'warn';
    });

    $app->_warn_default_secrets({
        secrets           => ['change-me-in-production'],
        admin_secret_salt => 'change-me-in-production',
    });

    is scalar @log, 2, 'two warnings emitted';
    $app->log->unsubscribe('message');
};

subtest 'warns when secrets array is empty' => sub {
    my @log;
    $app->log->on(message => sub ($log, $level, @msg) {
        push @log, [$level, @msg] if $level eq 'warn';
    });

    $app->_warn_default_secrets({
        secrets           => [],
        admin_secret_salt => 'unique-pepper',
    });

    is scalar @log, 1, 'one warning for empty secrets';
    like $log[0][1], qr/SMOKE_SESSION_SECRET/, 'warning mentions session secret';
    $app->log->unsubscribe('message');
};

subtest 'warns on dev-mode placeholder too' => sub {
    my @log;
    $app->log->on(message => sub ($log, $level, @msg) {
        push @log, [$level, @msg] if $level eq 'warn';
    });

    $app->_warn_default_secrets({
        secrets           => ['dev-secret-not-for-production'],
        admin_secret_salt => 'dev-pepper-not-for-production',
    });

    is scalar @log, 2, 'dev placeholders also trigger warnings';
    $app->log->unsubscribe('message');
};

done_testing;
