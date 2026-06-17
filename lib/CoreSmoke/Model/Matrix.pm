package CoreSmoke::Model::Matrix;
use v5.42;
use warnings;
use experimental qw(signatures);

sub new ($class, %args) {
    my $sqlite = $args{sqlite} // die "sqlite required";
    return bless { sqlite => $sqlite }, $class;
}

# Cross-tab: rows = test name, columns = last 5 perl_ids by plevel desc.
# Each cell = { cnt => N, alt => "linux-6.5;darwin-23.0" } where alt is a
# semicolon-joined distinct list of "<osname>-<osversion>" pairs.
#
# Options:
#   include_stdio  => truthy to count result rows with io_env = 'stdio'.
#                     Default (false): stdio is excluded. The stdio
#                     environment is the legacy non-PerlIO path and is
#                     often noisy on platforms that have moved on; the
#                     opt-in keeps the matrix focused on PerlIO/locale
#                     failures.
sub matrix ($self, %opts) {
    my $db = $self->{sqlite}->db;

    my $perl_versions = [
        map { $_->{perl_id} }
        @{ $db->query(<<~'SQL')->hashes->to_array }
            SELECT perl_id FROM report
             GROUP BY perl_id
             ORDER BY MAX(plevel) DESC LIMIT 5
            SQL
    ];

    return { perl_versions => [], rows => [] } unless @$perl_versions;

    my $marks      = join ',', ('?') x scalar @$perl_versions;
    my $stdio_pred = $opts{include_stdio} ? '' : "AND rs.io_env <> 'stdio'";
    my $sql = <<~"SQL";
        SELECT f.test,
               r.perl_id,
               COUNT(*)                                                AS cnt,
               GROUP_CONCAT(DISTINCT r.osname || '-' || r.osversion)   AS alt
          FROM failure          f
          JOIN failures_for_env ffe ON ffe.failure_id = f.id
          JOIN result           rs  ON rs.id          = ffe.result_id
          JOIN config           c   ON c.id           = rs.config_id
          JOIN report           r   ON r.id           = c.report_id
         WHERE r.perl_id IN ($marks)
           $stdio_pred
         GROUP BY f.test, r.perl_id
         ORDER BY cnt DESC, f.test
        SQL

    my $rows = $db->query($sql, @$perl_versions)->hashes->to_array;

    my %by_test;
    for my $row (@$rows) {
        $by_test{ $row->{test} } //= { test => $row->{test} };
        $by_test{ $row->{test} }{ $row->{perl_id} } = {
            cnt => $row->{cnt} + 0,
            alt => $row->{alt} // '',
        };
    }

    my @ordered = sort {
        ( _row_total($b) <=> _row_total($a) ) || ( $a->{test} cmp $b->{test} )
    } values %by_test;

    return { perl_versions => $perl_versions, rows => \@ordered };
}

sub _row_total ($row) {
    my $sum = 0;
    for my $k (keys %$row) {
        next if $k eq 'test';
        $sum += $row->{$k}{cnt} // 0;
    }
    return $sum;
}

# Reports failing one specific test. Optional pversion narrows the result.
sub submatrix ($self, $test, $pversion = undef) {
    my $db = $self->{sqlite}->db;

    my $sql = <<~'SQL';
        SELECT DISTINCT
               r.id, r.perl_id, r.git_id, r.git_describe,
               r.hostname, r.osname, r.osversion, r.plevel
          FROM report          r
          JOIN config          c   ON c.report_id  = r.id
          JOIN result          rs  ON rs.config_id = c.id
          JOIN failures_for_env ffe ON ffe.result_id = rs.id
          JOIN failure         f   ON f.id          = ffe.failure_id
         WHERE f.test = ?
        SQL

    my @bind = ($test);
    if (defined $pversion && length $pversion) {
        $sql .= " AND r.perl_id = ?";
        push @bind, $pversion;
    }
    $sql .= " ORDER BY r.plevel DESC, r.smoke_date DESC";

    return $db->query($sql, @bind)->hashes->to_array;
}

1;
