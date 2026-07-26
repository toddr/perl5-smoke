package CoreSmoke::Util::PgDump;
use v5.42;
use warnings;
use experimental qw(signatures);

use Time::Piece;
use Exporter 'import';

our @EXPORT_OK = qw(decode_copy_field pg_ts_to_iso);

# pg_dump COPY field decoding
# Backslash escapes per Postgres COPY text format:
#   \N -> NULL (only when the entire field is "\N")
#   \\ -> \      \t -> tab      \n -> newline    \r -> CR
#   \b -> backspace   \f -> form feed   \v -> vertical tab
sub decode_copy_field ($f) {
    ## no critic (Subroutines::ProhibitExplicitReturnUndef)
    return undef if $f eq '\\N';
    ## use critic
    return $f unless index($f, '\\') >= 0;
    $f =~ s{\\(.)}{
          $1 eq 'n' ? "\n"
        : $1 eq 't' ? "\t"
        : $1 eq 'r' ? "\r"
        : $1 eq 'b' ? "\b"
        : $1 eq 'f' ? "\f"
        : $1 eq 'v' ? "\013"
        : $1 eq '\\' ? "\\"
        : $1
    }ge;
    return $f;
}

# Postgres timestamp -> ISO 8601 UTC (e.g. "2024-05-08T10:23:11Z")
sub pg_ts_to_iso ($ts) {
    return unless defined $ts && length $ts;

    if ($ts =~ /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}(?:\.\d+)?)([+-])(\d{1,2})(?::?(\d{2}))?$/) {
        my ($date, $time, $sign, $h, $m) = ($1, $2, $3, $4, $5 // 0);
        $time =~ s/\.\d+$//;
        my $offset_secs = ($h * 3600 + $m * 60) * ($sign eq '+' ? 1 : -1);
        my $tp = Time::Piece->strptime("$date $time", '%Y-%m-%d %H:%M:%S');
        $tp -= $offset_secs;
        return $tp->strftime('%Y-%m-%dT%H:%M:%SZ');
    }

    if ($ts =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/) {
        return $ts;
    }

    warn "[ts] unrecognised timestamp format: '$ts' (passing through)\n";
    return $ts;
}

1;
