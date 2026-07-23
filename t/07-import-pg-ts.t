use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use POSIX qw(tzset);

# The pg_ts_to_iso() function lives in script/import-from-pgdump.
# We extract it here by requiring the script in a controlled way.
# Instead, define the function inline -- it must stay in sync with the
# script, but this avoids loading the full importer and its heavy deps.

use Time::Piece;

# ---------- pg_ts_to_iso (copied from script/import-from-pgdump) ----------
# The point of this test is to verify the gmtime->strptime fix: the
# function must produce correct UTC output regardless of $ENV{TZ}.
sub pg_ts_to_iso ($ts) {
    return unless defined $ts && length $ts;

    if ($ts =~ /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}(?:\.\d+)?)([+-])(\d{1,2})(?::?(\d{2}))?$/) {
        my ($date, $time, $sign, $h, $m) = ($1, $2, $3, $4, $5 // 0);
        $time =~ s/\.\d+$//;
        my $offset_secs = ($h * 3600 + $m * 60) * ($sign eq '+' ? 1 : -1);
        my $tp = gmtime->strptime("$date $time", '%Y-%m-%d %H:%M:%S');
        $tp -= $offset_secs;
        return $tp->strftime('%Y-%m-%dT%H:%M:%SZ');
    }

    if ($ts =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/) {
        return $ts;
    }

    return $ts;
}

# ---------- Tests -----------------------------------------------------------

my @cases = (
    # [ input, expected, description ]
    ['2024-05-08 10:23:11+02',     '2024-05-08T08:23:11Z', 'positive offset +02'],
    ['2024-05-08 10:23:11+2',      '2024-05-08T08:23:11Z', 'single-digit offset +2'],
    ['2024-05-08 10:23:11-05',     '2024-05-08T15:23:11Z', 'negative offset -05'],
    ['2024-05-08 10:23:11+00',     '2024-05-08T10:23:11Z', 'zero offset'],
    ['2024-05-08 10:23:11.123+02', '2024-05-08T08:23:11Z', 'fractional seconds dropped'],
    ['2024-12-31 23:30:00+02',     '2024-12-31T21:30:00Z', 'near midnight, no date rollover'],
    ['2024-01-01 01:00:00+02',     '2023-12-31T23:00:00Z', 'offset rolls back to previous day/year'],
    ['2024-05-08 10:23:11+05:30',  '2024-05-08T04:53:11Z', 'offset with minutes (+05:30)'],
    ['2024-05-08T10:23:11Z',       '2024-05-08T10:23:11Z', 'already ISO -- pass through'],
);

# Run every case in the default TZ, then again in two non-UTC zones.
# The results must be identical -- the bug this tests for was
# Time::Piece->strptime (localtime-based) producing host-TZ-dependent
# output instead of gmtime->strptime.
my @tzones = ($ENV{TZ} // 'unset', 'America/New_York', 'Asia/Kolkata');

for my $tz (@tzones) {
    local $ENV{TZ} = $tz eq 'unset' ? undef : $tz;
    tzset() if $tz ne 'unset';

    for my $case (@cases) {
        my ($input, $expected, $desc) = @$case;
        my $got = pg_ts_to_iso($input);
        is($got, $expected, "$desc (TZ=$tz)");
    }
}

# Restore TZ
delete $ENV{TZ};
tzset();

# Edge cases
is(pg_ts_to_iso(undef), undef, 'undef input');
is(pg_ts_to_iso(''),    undef, 'empty string');
is(pg_ts_to_iso('garbage'), 'garbage', 'unrecognised format passes through');

done_testing;
