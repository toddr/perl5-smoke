use v5.42;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";

use CoreSmoke::Validate qw(positive_int non_negative_int clamp_int);

# -- positive_int ----------------------------------------------------------

is positive_int(1),     1,     'positive_int: 1';
is positive_int(42),    42,    'positive_int: 42';
is positive_int('100'), 100,   'positive_int: string "100"';
is positive_int(0),     undef, 'positive_int: 0 rejected';
is positive_int(-1),    undef, 'positive_int: negative rejected';
is positive_int('abc'), undef, 'positive_int: letters rejected';
is positive_int('3.14'),undef, 'positive_int: float rejected';
is positive_int(''),    undef, 'positive_int: empty string rejected';
is positive_int(undef), undef, 'positive_int: undef rejected';
is positive_int('0x10'),undef, 'positive_int: hex rejected';
is positive_int(' 5'),  undef, 'positive_int: leading space rejected';
is positive_int('5 '),  undef, 'positive_int: trailing space rejected';

# -- non_negative_int ------------------------------------------------------

is non_negative_int(0),     0,     'non_negative_int: 0 accepted';
is non_negative_int(1),     1,     'non_negative_int: 1';
is non_negative_int('999'), 999,   'non_negative_int: string "999"';
is non_negative_int(-1),    undef, 'non_negative_int: negative rejected';
is non_negative_int('abc'), undef, 'non_negative_int: letters rejected';
is non_negative_int(''),    undef, 'non_negative_int: empty string rejected';
is non_negative_int(undef), undef, 'non_negative_int: undef rejected';

# -- clamp_int -------------------------------------------------------------

is clamp_int(5,   1, 10, 3), 5,   'clamp_int: in range';
is clamp_int(0,   1, 10, 3), 1,   'clamp_int: zero clamped to min';
is clamp_int('',  1, 10, 3), 3,   'clamp_int: empty gets default';
is clamp_int(undef,1,10, 3), 3,   'clamp_int: undef gets default';
is clamp_int(-5,  1, 10, 3), 1,   'clamp_int: below min clamped';
is clamp_int(99,  1, 10, 3), 10,  'clamp_int: above max clamped';
is clamp_int(1,   1, 10, 3), 1,   'clamp_int: at min';
is clamp_int(10,  1, 10, 3), 10,  'clamp_int: at max';
is clamp_int('abc',1,10, 3), 3,  'clamp_int: non-numeric gets default';
is clamp_int('3.5',1,10, 3), 3,  'clamp_int: float string gets default';

done_testing;
