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

my $tok    = $h->app->auth->create_token(note => 'dup-test', email => 'dup@example.com');
my $token  = $tok->{token};
my $tok_id = $tok->{id};

my $fixture = $h->fixture('idefix-gff5bbe677.jsn');

my $counter = 0;
sub unique_fixture {
    my %copy = %$fixture;
    my %sys  = %{ $copy{sysinfo} // {} };
    $sys{hostname} = "duptest-" . ++$counter;
    $copy{sysinfo} = \%sys;
    return \%copy;
}

subtest 'duplicate response omits db_error' => sub {
    my $data = unique_fixture();

    $t->post_ok('/api/report', json => { report_data => $data })
        ->status_is(200);

    $t->post_ok('/api/report', json => { report_data => $data })
        ->status_is(409)
        ->json_is('/error' => 'Report already posted.')
        ->json_hasnt('/db_error', 'no internal error details leaked');
};

subtest 'duplicate with token does not inflate use_count' => sub {
    my $data = unique_fixture();

    $t->post_ok('/api/report',
        { Authorization => "Bearer $token" },
        json => { report_data => $data },
    )->status_is(200);

    my $after_first = $h->app->auth->get_token($tok_id);
    my $count_after_first = $after_first->{use_count};

    $t->post_ok('/api/report',
        { Authorization => "Bearer $token" },
        json => { report_data => $data },
    )->status_is(409);

    my $after_dup = $h->app->auth->get_token($tok_id);
    is $after_dup->{use_count}, $count_after_first,
        'use_count unchanged after duplicate rejection';
};

subtest 'successful ingest still records token use' => sub {
    my $before = $h->app->auth->get_token($tok_id);
    my $count_before = $before->{use_count};

    my $data = unique_fixture();
    $t->post_ok('/api/report',
        { Authorization => "Bearer $token" },
        json => { report_data => $data },
    )->status_is(200);

    my $after = $h->app->auth->get_token($tok_id);
    is $after->{use_count}, $count_before + 1,
        'use_count incremented on successful ingest';
};

done_testing;
