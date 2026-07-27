package CoreSmoke::Model::Plevel;
use v5.42;
use warnings;
use experimental qw(signatures);

use Exporter 'import';
our @EXPORT_OK = qw(sort_perl_ids_desc);

# Faithful port of public.git_describe_as_plevel() from the legacy Postgres
# schema. Output must be byte-identical to the PG function for valid
# git_describe inputs (see t/data/plevel-corpus.tsv).
#
# Real-world dumps occasionally contain rows whose `git_describe` column is
# a bare commit SHA (no v5.X.Y prefix). Those produce nonsense plevels that
# sort above every well-formed value (since their first character is a hex
# digit, not '5'), pinning malformed rows to the top of /latest. When that
# happens AND a `perl_id` is supplied, fall back to deriving the plevel
# from `perl_id` (e.g. 5.41.9 -> 5.041009zzz000). Without a perl_id, return
# a sentinel that sorts LOW so the malformed row drops to the bottom.

sub from_git_describe ($describe, $perl_id = undef) {
    my $clean = $describe // '';
    $clean =~ s/^v//;
    $clean =~ s/-g.+$//;

    # Reject obviously bogus input (bare SHA, empty, malformed) and fall
    # back to a perl_id-derived plevel if we have one.
    unless ($clean =~ /^\d+\.\d/) {
        return _from_perl_id($perl_id) // '0.000000zzz000';
    }

    my @parts = split /[.\-]/, $clean;
    push @parts, '0' if @parts == 3;

    my $plevel = ($parts[0] // '') . '.'
               . _lpad($parts[1] // '', 3, '0')
               . _lpad($parts[2] // '', 3, '0');

    if (defined $parts[3] && $parts[3] =~ /RC/) {
        $plevel .= $parts[3];
    } else {
        $plevel .= 'zzz';
    }

    $plevel .= _lpad($parts[-1] // '', 3, '0');
    return $plevel;
}

# 5.41.9 -> 5.041009zzz000. Returns undef if perl_id is malformed.
sub _from_perl_id ($perl_id) {
    return unless defined $perl_id;
    return unless $perl_id =~ /^(\d+)\.(\d+)(?:\.(\d+))?$/;
    return sprintf '%d.%03d%03dzzz000', $1, $2, $3 // 0;
}

# PG lpad(str, len, fill): left-pad with `fill` if shorter than `len`,
# truncate from the right if longer.
sub _lpad ($str, $len, $fill) {
    return substr($str, 0, $len) if length($str) > $len;
    return $fill x ($len - length($str)) . $str;
}

sub sort_perl_ids_desc ($list) {
    return [
        sort {
            my @a = split /\./, $a;
            my @b = split /\./, $b;
            my $n = $#a > $#b ? $#a : $#b;
            my $cmp = 0;
            for my $i (0 .. $n) {
                $cmp = ($b[$i] // 0) <=> ($a[$i] // 0);
                last if $cmp;
            }
            $cmp;
        } @$list
    ];
}

1;
