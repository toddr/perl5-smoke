package CoreSmoke::Validate;
use v5.42;
use warnings;
use experimental qw(signatures);

use Exporter 'import';
our @EXPORT_OK = qw(positive_int non_negative_int clamp_int);

sub positive_int ($val) {
    return unless defined $val && $val =~ /\A[0-9]+\z/ && $val > 0;
    return 0 + $val;
}

sub non_negative_int ($val) {
    return unless defined $val && $val =~ /\A[0-9]+\z/;
    return 0 + $val;
}

sub clamp_int ($val, $min, $max, $default) {
    my $n = (defined $val && $val =~ /\A-?[0-9]+\z/) ? 0 + $val : $default;
    $n = $min if $n < $min;
    $n = $max if $n > $max;
    return $n;
}

1;
