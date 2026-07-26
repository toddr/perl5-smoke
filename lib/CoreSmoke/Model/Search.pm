package CoreSmoke::Model::Search;
use v5.42;
use warnings;
use experimental qw(signatures);

use Exporter 'import';
our @EXPORT_OK = qw(search_params);

my @SEARCH_PARAMS = qw(
    selected_arch selected_osnm selected_osvs selected_host
    selected_comp selected_cver selected_perl selected_branch
    selected_smkv selected_summary
    date_from date_to
    andnotsel_arch andnotsel_osnm andnotsel_osvs andnotsel_host
    andnotsel_comp andnotsel_cver andnotsel_smkv andnotsel_summary
    andnotsel_branch
    page reports_per_page
);

sub search_params { @SEARCH_PARAMS }

# Compile the legacy /api/searchresults filter parameters into a
# parameterised SQL WHERE clause. Names are preserved verbatim so
# existing clients keep working.
#
# Filter inputs (each optional):
#   selected_arch / andnotsel_arch       -> r.architecture
#   selected_osnm / andnotsel_osnm       -> r.osname
#   selected_osvs / andnotsel_osvs       -> r.osversion
#   selected_host / andnotsel_host       -> r.hostname
#   selected_comp / andnotsel_comp       -> c.cc          (joins config)
#   selected_cver / andnotsel_cver       -> c.ccversion   (joins config)
#   selected_perl                        -> "all" | "latest" | "<perl_id>"
#   selected_branch                      -> r.smoke_branch
#   selected_smkv                        -> r.smoke_version
#   selected_summary                     -> r.summary     ("PASS" | "FAIL(F)" | ...)
#   date_from                            -> r.smoke_date >= (inclusive, YYYY-MM-DD)
#   date_to                              -> r.smoke_date <  next day  (inclusive, YYYY-MM-DD)
#   page                                 -> 1-based, default 1
#   reports_per_page                     -> default 25

sub new ($class, %args) {
    my $sqlite = $args{sqlite} // die "sqlite required";
    return bless { sqlite => $sqlite }, $class;
}

my %REPORT_FIELD = (
    arch   => 'r.architecture',
    osnm   => 'r.osname',
    osvs   => 'r.osversion',
    host   => 'r.hostname',
    branch => 'r.smoke_branch',
    smkv   => 'r.smoke_version',
    # `summary` is intentionally NOT in this map -- it's matched via
    # GLOB patterns ("PASS*" or "FAIL(*X*)") rather than equality, so
    # it gets its own branch in compile() below.
);
my %CONFIG_FIELD = (
    comp => 'c.cc',
    cver => 'c.ccversion',
);

sub compile ($self, $params) {
    my @where;
    my @bind;

    my $emit = sub ($col, $key) {
        my $v = $params->{"selected_$key"};
        return unless defined $v && length $v && $v ne 'all';
        my $not = $params->{"andnotsel_$key"} ? '<>' : '=';
        push @where, "$col $not ?";
        push @bind, $v;
    };

    $emit->($REPORT_FIELD{$_}, $_) for qw(arch osnm osvs host branch smkv);

    # Date range: date_from/date_to filter on r.smoke_date (ISO 8601 TEXT).
    # date_from is inclusive (>=), date_to is inclusive of the whole day
    # (< next day via SQLite date() arithmetic).
    my $date_from = $params->{date_from};
    if (defined $date_from && length $date_from) {
        push @where, "r.smoke_date >= ?";
        push @bind, $date_from;
    }
    my $date_to = $params->{date_to};
    if (defined $date_to && length $date_to) {
        push @where, "r.smoke_date < date(?, '+1 day')";
        push @bind, $date_to;
    }

    # Summary: bucketed match.
    #   selected_summary = "PASS"     -> r.summary GLOB 'PASS*'
    #   selected_summary = "FAIL(*)"  -> r.summary GLOB 'FAIL(*'   (any FAIL)
    #   selected_summary = "FAIL(F)"  -> r.summary GLOB 'FAIL(*F*)'
    #   selected_summary = "FAIL(m)"  -> r.summary GLOB 'FAIL(*m*)'
    # GLOB is case-sensitive in SQLite, so M and m are distinct as the
    # user spec'd.
    my $sum = $params->{selected_summary};
    if (defined $sum && length $sum && $sum ne 'all') {
        my $neg = $params->{andnotsel_summary} ? 'NOT ' : '';
        if ($sum eq 'PASS') {
            push @where, "r.summary ${neg}GLOB ?";
            push @bind, 'PASS*';
        }
        elsif ($sum eq 'FAIL(*)') {
            push @where, "r.summary ${neg}GLOB ?";
            push @bind, 'FAIL(*';
        }
        elsif ($sum =~ /^FAIL\((.+)\)$/) {
            push @where, "r.summary ${neg}GLOB ?";
            push @bind, "FAIL(*$1*)";
        }
        else {
            # Unknown bucket: fall back to equality so a stale URL doesn't
            # silently match everything.
            my $op = $params->{andnotsel_summary} ? '<>' : '=';
            push @where, "r.summary $op ?";
            push @bind, $sum;
        }
    }

    my $needs_config_join = 0;
    for my $key (qw(comp cver)) {
        my $v = $params->{"selected_$key"};
        $needs_config_join = 1 if defined $v && length $v && $v ne 'all';
    }
    if ($needs_config_join) {
        $emit->($CONFIG_FIELD{$_}, $_) for qw(comp cver);
    }

    # `latest` is resolved into a concrete perl_id by callers in
    # CoreSmoke::Model::Reports (searchresults / available_filter_values)
    # using RPM-style version sort, before reaching this compiler.
    my $perl = $params->{selected_perl} // 'all';
    if ($perl ne 'all' && $perl ne 'latest' && length $perl) {
        push @where, "r.perl_id = ?";
        push @bind, $perl;
    }

    my $sql_from  = "FROM report r"
                  . ($needs_config_join ? " JOIN config c ON c.report_id = r.id" : "");
    my $sql_where = @where ? "WHERE " . join(' AND ', @where) : '';

    return ($sql_from, $sql_where, \@bind);
}

sub run ($self, $params) {
    my ($from, $where, $bind) = $self->compile($params);
    my $rpp    = int($params->{reports_per_page} || 25);
    $rpp = 1   if $rpp < 1;
    $rpp = 500 if $rpp > 500;
    my $page   = int($params->{page} || 1);
    $page = 1 if $page < 1;
    my $offset = ($page - 1) * $rpp;

    my $db = $self->{sqlite}->db;

    my $count = $db->query(
        "SELECT COUNT(DISTINCT r.id) AS n $from $where",
        @$bind,
    )->hash->{n} // 0;

    my $rows = $db->query(
        "SELECT DISTINCT r.* $from $where "
      . "ORDER BY r.plevel DESC, r.smoke_date DESC LIMIT ? OFFSET ?",
        @$bind, $rpp, $offset,
    )->hashes->to_array;

    return {
        reports          => $rows,
        report_count     => $count,
        page             => $page,
        reports_per_page => $rpp,
    };
}

1;
