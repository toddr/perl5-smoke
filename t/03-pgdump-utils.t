use v5.42;
use warnings;
use experimental qw(signatures);
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

use CoreSmoke::Util::PgDump qw(decode_copy_field pg_ts_to_iso);

# -- decode_copy_field --

subtest 'decode_copy_field -NULL' => sub {
    is decode_copy_field('\\N'), undef, '\\N decodes to undef';
};

subtest 'decode_copy_field -NULL in list context preserves slot' => sub {
    my @vals = map { decode_copy_field($_) } ('a', '\\N', 'c');
    is scalar @vals, 3, 'list has 3 elements (undef not collapsed)';
    is $vals[0], 'a',   'first element';
    is $vals[1], undef, 'second element is undef';
    is $vals[2], 'c',   'third element';
};

subtest 'decode_copy_field -plain text passthrough' => sub {
    is decode_copy_field('hello'),   'hello',   'no backslash';
    is decode_copy_field(''),        '',         'empty string';
    is decode_copy_field('12345'),   '12345',   'digits only';
};

subtest 'decode_copy_field -backslash escapes' => sub {
    is decode_copy_field('a\\nb'),   "a\nb",    '\\n -> newline';
    is decode_copy_field('a\\tb'),   "a\tb",    '\\t -> tab';
    is decode_copy_field('a\\rb'),   "a\rb",    '\\r -> CR';
    is decode_copy_field('a\\bb'),   "a\bb",    '\\b -> backspace';
    is decode_copy_field('a\\fb'),   "a\fb",    '\\f -> form feed';
    is decode_copy_field('a\\vb'),   "a\013b",  '\\v -> vertical tab';
    is decode_copy_field('a\\\\b'),  'a\\b',    '\\\\ -> single backslash';
};

subtest 'decode_copy_field -multiple escapes in one field' => sub {
    is decode_copy_field('line1\\nline2\\ttab'),
       "line1\nline2\ttab",
       'mixed escapes';
};

subtest 'decode_copy_field -unknown escape passes through' => sub {
    is decode_copy_field('\\z'), 'z', 'unknown escape drops the backslash';
};

# -- pg_ts_to_iso --

subtest 'pg_ts_to_iso -positive offset' => sub {
    is pg_ts_to_iso('2024-05-08 12:30:00+02'),
       '2024-05-08T10:30:00Z',
       '+02 -> subtract 2 hours';
};

subtest 'pg_ts_to_iso -negative offset' => sub {
    is pg_ts_to_iso('2024-05-08 08:00:00-05'),
       '2024-05-08T13:00:00Z',
       '-05 -> add 5 hours';
};

subtest 'pg_ts_to_iso -offset with minutes' => sub {
    is pg_ts_to_iso('2024-05-08 12:30:00+05:30'),
       '2024-05-08T07:00:00Z',
       '+05:30 (India) -> subtract 5h30m';
};

subtest 'pg_ts_to_iso -single-digit offset' => sub {
    is pg_ts_to_iso('2024-05-08 10:00:00+1'),
       '2024-05-08T09:00:00Z',
       '+1 -> subtract 1 hour';
};

subtest 'pg_ts_to_iso -fractional seconds dropped' => sub {
    is pg_ts_to_iso('2024-05-08 10:23:11.456+02'),
       '2024-05-08T08:23:11Z',
       'fractional seconds stripped';
};

subtest 'pg_ts_to_iso -already ISO passthrough' => sub {
    is pg_ts_to_iso('2024-05-08T10:23:11Z'),
       '2024-05-08T10:23:11Z',
       'ISO 8601 returned unchanged';
};

subtest 'pg_ts_to_iso -undef and empty' => sub {
    is pg_ts_to_iso(undef), undef, 'undef input';
    is pg_ts_to_iso(''),    undef, 'empty string input';
};

subtest 'pg_ts_to_iso -unrecognised format' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $result = pg_ts_to_iso('not a timestamp');
    is $result, 'not a timestamp', 'unrecognised format passed through';
    like $warnings[0], qr/unrecognised timestamp/, 'warning emitted';
};

subtest 'pg_ts_to_iso -day boundary crossing' => sub {
    is pg_ts_to_iso('2024-05-09 01:00:00+03'),
       '2024-05-08T22:00:00Z',
       'crosses midnight backward';
};

done_testing;
