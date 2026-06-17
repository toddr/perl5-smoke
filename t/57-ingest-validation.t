use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use lib "$FindBin::Bin/lib";

use TestApp;
use Mojo::JSON qw(decode_json);
use Mojo::File qw();
use File::Find qw(find);

my $h = TestApp->new;
my $t = $h->t;

# Load a valid fixture as baseline, then strip required fields.
my $valid = $h->fixture('idefix-gff5bbe677.jsn');

# --- Missing report_data entirely (controller rejects at 422) ---
$t->post_ok('/api/report', json => {})
  ->status_is(422)
  ->json_like('/error' => qr/Missing report_data/);

# --- report_data is not a hash (model rejects at 400) ---
$t->post_ok('/api/report', json => { report_data => "not a hash" })
  ->status_is(400)
  ->json_like('/error' => qr/Missing report_data/);

# --- Missing required sysinfo fields ---
my @required = qw(hostname architecture osname osversion);
for my $field (@required) {
    my $bad = _fixture_without_sysinfo_field($valid, $field);
    $t->post_ok('/api/report', json => { report_data => $bad })
      ->status_is(400)
      ->json_like('/error' => qr/Missing required field.*$field/,
          "missing sysinfo.$field returns 400");
}

# --- Missing top-level required fields (git_id via sysinfo, summary at top) ---
{
    my $bad = _fixture_without_sysinfo_field($valid, 'git_id');
    $t->post_ok('/api/report', json => { report_data => $bad })
      ->status_is(400)
      ->json_like('/error' => qr/Missing required field.*git_id/);
}
{
    my $no_summary = { %$valid };
    delete $no_summary->{summary};
    $t->post_ok('/api/report', json => { report_data => $no_summary })
      ->status_is(400)
      ->json_like('/error' => qr/Missing required field.*summary/);
}

# --- No orphan files written when validation fails ---
{
    my $reports_dir = $ENV{SMOKE_REPORTS_DIR};
    my $bad = _fixture_without_sysinfo_field($valid, 'hostname');
    # Add file content that would be written on success.
    $bad->{log_file} = "some log content that should not be written";

    $t->post_ok('/api/report', json => { report_data => $bad })
      ->status_is(400);

    my @files;
    if (-d $reports_dir) {
        find(sub { push @files, $_ if -f }, $reports_dir);
    }
    is scalar(@files), 0, 'no orphan files written on validation failure';
}

# --- Valid report still works (regression check) ---
$t->post_ok('/api/report', json => { report_data => $valid })
  ->status_is(200)
  ->json_has('/id');

# --- Duplicate is still 409 ---
$t->post_ok('/api/report', json => { report_data => $valid })
  ->status_is(409)
  ->json_like('/error' => qr/already posted/);

done_testing;

sub _fixture_without_sysinfo_field ($fixture, $field) {
    my $copy = { %$fixture };
    $copy->{sysinfo} = { %{ $copy->{sysinfo} } };
    delete $copy->{sysinfo}{$field};
    return $copy;
}
