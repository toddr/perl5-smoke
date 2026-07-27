package CoreSmoke::Model::Reports;
use v5.42;
use warnings;
use experimental qw(signatures);

use CoreSmoke::Model::Search;
use CoreSmoke::Model::Matrix;

sub new ($class, %args) {
    my $sqlite       = $args{sqlite}       // die "sqlite required";
    my $report_files = $args{report_files};   # may be undef in some test paths
    return bless {
        sqlite       => $sqlite,
        report_files => $report_files,
        _search      => undef,
        _matrix      => undef,
    }, $class;
}

sub _search ($self) {
    $self->{_search} //= CoreSmoke::Model::Search->new(sqlite => $self->{sqlite});
}

sub _matrix ($self) {
    $self->{_matrix} //= CoreSmoke::Model::Matrix->new(sqlite => $self->{sqlite});
}

sub version ($self) {
    my $row = eval {
        $self->{sqlite}->db->query(
            "SELECT value FROM tsgateway_config WHERE name = 'dbversion'"
        )->hash;
    };
    my $db_version = ($row && $row->{value}) // '4';
    return {
        version        => '2.0',
        schema_version => '4',
        db_version     => $db_version,
    };
}

# /api/latest -- latest report per hostname, ordered by plevel desc.
#
# Optional filter: $params->{selected_summary} in (all|pass|fail).
# Applied to the OUTER row (the latest run per host), not to the inner
# aggregates -- so "fail" means "the host's latest run failed", not
# "the host has any failing run in history".
sub latest ($self, $params = {}) {
    my $rpp  = int($params->{reports_per_page} || 25);
    $rpp = 500 if $rpp > 500;
    my $page = int($params->{page} || 1);
    $page = 1 if $page < 1;
    my $offset = ($page - 1) * $rpp;

    my $sum = lc($params->{selected_summary} // 'all');
    my ($extra_where, @extra_bind) = ('');
    if ($sum eq 'pass') {
        $extra_where = " AND r.summary GLOB ?";
        push @extra_bind, 'PASS*';
    }
    elsif ($sum eq 'fail') {
        $extra_where = " AND r.summary GLOB ?";
        push @extra_bind, 'FAIL*';
    }

    my $db = $self->{sqlite}->db;

    my $rows = $db->query(<<~"SQL", @extra_bind, $rpp, $offset)->hashes->to_array;
        SELECT r.*, COUNT(*) OVER() AS _total_count
          FROM report r
         INNER JOIN (
               SELECT hostname, MAX(plevel) AS plevel
                 FROM report
                GROUP BY hostname
               ) g USING (hostname, plevel)
         WHERE r.smoke_date = (
               SELECT MAX(smoke_date) FROM report
                WHERE hostname = r.hostname AND plevel = r.plevel
               )$extra_where
         ORDER BY r.plevel DESC, r.smoke_date DESC
         LIMIT ? OFFSET ?
        SQL

    my $total = @$rows ? delete $rows->[0]{_total_count} : 0;
    delete $_->{_total_count} for @$rows;

    my $latest_plevel = $db->query("SELECT MAX(plevel) AS p FROM report")->hash->{p};

    return {
        reports          => $rows,
        report_count     => $total,
        latest_plevel    => $latest_plevel  // '',
        rpp              => $rpp,
        page             => $page,
    };
}

sub report_data ($self, $rid) {
    my $db = $self->{sqlite}->db;
    my $report = $db->query("SELECT * FROM report WHERE id = ?", $rid)->hash
        or return;

    my $configs = $db->query(
        "SELECT * FROM config WHERE report_id = ? ORDER BY id", $rid
    )->hashes->to_array;

    my $all_results = $db->query(<<~'SQL', $rid)->hashes->to_array;
        SELECT r.*
          FROM result r
          JOIN config c ON c.id = r.config_id
         WHERE c.report_id = ?
         ORDER BY r.config_id, r.id
        SQL

    my $all_failures = $db->query(<<~'SQL', $rid)->hashes->to_array;
        SELECT ffe.result_id, f.test, f.status, f.extra
          FROM failures_for_env ffe
          JOIN failure f  ON f.id  = ffe.failure_id
          JOIN result  r  ON r.id  = ffe.result_id
          JOIN config  c  ON c.id  = r.config_id
         WHERE c.report_id = ?
         ORDER BY f.test
        SQL

    my %failures_by_result;
    for my $f (@$all_failures) {
        my $result_id = delete $f->{result_id};
        push @{ $failures_by_result{$result_id} }, $f;
    }

    my %results_by_config;
    for my $res (@$all_results) {
        $res->{failures} = $failures_by_result{ $res->{id} } // [];
        push @{ $results_by_config{ $res->{config_id} } }, $res;
    }

    for my $cfg (@$configs) {
        $cfg->{results} = $results_by_config{ $cfg->{id} } // [];
    }
    $report->{configs} = $configs;

    if (defined $report->{sconfig_id}) {
        my $sc = $db->query(
            "SELECT md5, config FROM smoke_config WHERE id = ?", $report->{sconfig_id}
        )->hash;
        $report->{_config} = $sc;
    }

    return $report;
}

sub full_report_data ($self, $rid) {
    my $report = $self->report_data($rid) // return;

    # Token provenance
    if (defined $report->{api_token_id}) {
        my $tok = $self->{sqlite}->db->query(
            "SELECT note, email FROM api_token WHERE id = ?",
            $report->{api_token_id},
        )->hash;
        $report->{authenticated} = \1;
        $report->{token_note}    = $tok->{note}  // '';
        $report->{token_email}   = $tok->{email} // '';
    }
    else {
        $report->{authenticated} = \0;
    }

    # ---- Compilers (deduped {cc, ccversion} pairs) -----------------------
    my %seen_compiler;
    my @compilers;
    for my $cfg (@{ $report->{configs} // [] }) {
        my $key = ($cfg->{cc} // '') . "\0" . ($cfg->{ccversion} // '');
        next if $seen_compiler{$key}++;
        push @compilers, { cc => $cfg->{cc}, ccversion => $cfg->{ccversion} };
    }

    # ---- Per-config matrix row -------------------------------------------
    # Each config contributes one row: { args, debugging, results [ {io_env,
    # locale, summary} ... ] } where the summary char is what the legacy
    # smoke report prints (O / F / X / ...).  We also collect the union of
    # io_env labels seen across configs so the template can render a stable
    # column header.
    my %io_seen;
    my @matrix_rows;
    for my $cfg (@{ $report->{configs} // [] }) {
        my @results;
        for my $res (@{ $cfg->{results} // [] }) {
            my $label = $res->{io_env};
            $label .= '-' . $res->{locale}
                if defined $res->{locale} && length $res->{locale};
            $io_seen{$label}++;
            push @results, {
                io_env  => $res->{io_env},
                locale  => $res->{locale},
                label   => $label,
                summary => $res->{summary},
            };
        }
        push @matrix_rows, {
            arguments => $cfg->{arguments} // '',
            debugging => $cfg->{debugging},
            cc        => $cfg->{cc},
            ccversion => $cfg->{ccversion},
            duration  => $cfg->{duration},
            results   => \@results,
        };
    }
    my @io_labels = sort keys %io_seen;

    # ---- Test failures grouped by test ------------------------------------
    # legacy renders each failing test once with the list of configurations
    # that hit it -- not once per (config, io_env). We mirror that.
    # The DB schema allows UNIQUE(test, status, extra), so the same test
    # can have different extra text across environments. We collect all
    # distinct extras and expose them as an array.
    my %fail_seen;
    my @test_failures;
    for my $cfg (@{ $report->{configs} // [] }) {
        for my $res (@{ $cfg->{results} // [] }) {
            for my $f (@{ $res->{failures} // [] }) {
                my $key = join "\0", $f->{test} // '', $f->{status} // '';
                my $entry = $fail_seen{$key} //= do {
                    push @test_failures, {
                        test    => $f->{test},
                        status  => $f->{status},
                        extra   => $f->{extra},
                        extras  => [],
                        _extra_seen => {},
                        configs => [],
                    };
                    $test_failures[-1];
                };
                my $ex = $f->{extra} // '';
                if (length $ex && !$entry->{_extra_seen}{$ex}++) {
                    push @{ $entry->{extras} }, $ex;
                }
                push @{ $entry->{configs} }, {
                    arguments => $cfg->{arguments} // '',
                    debugging => $cfg->{debugging},
                    io_env    => $res->{io_env},
                    locale    => $res->{locale},
                };
            }
        }
    }
    delete $_->{_extra_seen} for @test_failures;

    # ---- Decoded on-disk extras -------------------------------------------
    # The matrix UI inlines compiler_msgs and manifest_msgs when present;
    # log_file is shown via a separate link because it's typically tens
    # of kB of log output.
    my $rf = $self->{report_files};
    my $hash = $report->{report_hash};
    my $on_disk = sub ($field) {
        return unless $rf && defined $hash;
        my $b = $rf->read_by_hash($hash, $field);
        return defined $b && length $b ? $b : ();
    };

    $report->{c_compilers}     = \@compilers;
    $report->{io_labels}       = \@io_labels;
    $report->{matrix_rows}     = \@matrix_rows;
    $report->{test_failures}   = \@test_failures;
    $report->{compiler_msgs_text} = $on_disk->('compiler_msgs');
    $report->{manifest_msgs_text} = $on_disk->('manifest_msgs');
    $report->{nonfatal_msgs_text} = $on_disk->('nonfatal_msgs');
    $report->{has_log_file}    = ($rf && defined $hash) ? $rf->has_file($hash, 'log_file') : 0;
    $report->{has_out_file}    = ($rf && defined $hash) ? $rf->has_file($hash, 'out_file') : 0;

    # ---- Formatted durations ----------------------------------------------
    my $total = 0;
    $total += ($_->{duration} // 0) for @{ $report->{configs} // [] };
    my $configs_n = scalar @{ $report->{configs} // [] };
    $report->{durations}        = $total;
    $report->{duration_in_hhmm} = _hhmm($total);
    $report->{average_in_hhmm}  = _hhmm($configs_n ? int($total / $configs_n) : 0);

    return $report;
}

sub _hhmm ($seconds) {
    return '0:00' unless $seconds && $seconds > 0;
    my $h = int($seconds / 3600);
    my $m = int(($seconds % 3600) / 60);
    return sprintf '%d:%02d', $h, $m;
}

sub logfile ($self, $rid) {
    return unless $self->{report_files};
    my $bytes = $self->{report_files}->read($rid, 'log_file');
    return defined $bytes ? { file => $bytes } : undef;
}

sub outfile ($self, $rid) {
    return unless $self->{report_files};
    my $bytes = $self->{report_files}->read($rid, 'out_file');
    return defined $bytes ? { file => $bytes } : undef;
}

sub searchparameters ($self) {
    my $db = $self->{sqlite}->db;
    return {
        sel_arch_os_ver => $db->query(<<~'SQL')->hashes->to_array,
            SELECT DISTINCT architecture, osname, osversion
              FROM report
             ORDER BY architecture, osname, osversion
            SQL
        sel_comp_ver => $db->query(<<~'SQL')->hashes->to_array,
            SELECT DISTINCT cc, ccversion
              FROM config
             WHERE cc IS NOT NULL
             ORDER BY cc, ccversion
            SQL
        branches => [
            map { $_->{smoke_branch} }
            @{ $db->query(<<~'SQL')->hashes->to_array }
                SELECT DISTINCT smoke_branch FROM report ORDER BY smoke_branch
                SQL
        ],
        perl_versions => [
            map { $_->{perl_id} }
            @{ $db->query(<<~'SQL')->hashes->to_array }
                SELECT DISTINCT perl_id FROM report ORDER BY plevel DESC
                SQL
        ],
    };
}

sub searchresults ($self, $params) {
    my %p = %$params;
    if (($p{selected_perl} // '') eq 'latest') {
        $p{selected_perl} = $self->latest_perl_id // 'all';
    }
    return $self->_search->run(\%p);
}

# RPM-style "latest" perl_id: highest version by numeric component
# compare. Replaces the legacy MAX(plevel) approach, which is a string
# compare and was returning bogus rows whose plevel was malformed.
sub latest_perl_id ($self) {
    my $ids = [
        map { $_->{perl_id} }
        @{ $self->{sqlite}->db->query(
            "SELECT DISTINCT perl_id FROM report"
        )->hashes->to_array }
    ];
    return _sort_perl_ids_desc($ids)->[0];
}

# For the /search UI: given the user's current $filter, return the
# distinct values still possible for each dropdown dimension when all
# OTHER filters are applied. Picking selected_arch=aarch64 narrows the
# perl_version and branch dropdowns to only what exists in aarch64
# rows; the architecture dropdown still shows every architecture so
# the user can change their mind.
#
# Returns:
#   { architectures => [...], perl_versions => [...], branches => [...] }
sub available_filter_values ($self, $filter) {
    my $search = $self->_search;
    my $db     = $self->{sqlite}->db;

    if (($filter->{selected_perl} // '') eq 'latest') {
        my %resolved = %$filter;
        $resolved{selected_perl} = $self->latest_perl_id // 'all';
        $filter = \%resolved;
    }

    my %dims = (
        architectures     => { exclude => [qw(selected_arch    andnotsel_arch)],
                               field   => 'r.architecture' },
        osnames           => { exclude => [qw(selected_osnm    andnotsel_osnm)],
                               field   => 'r.osname' },
        osversions        => { exclude => [qw(selected_osvs    andnotsel_osvs)],
                               field   => 'r.osversion' },
        perl_versions     => { exclude => [qw(selected_perl)],
                               field   => 'r.perl_id' },
        branches          => { exclude => [qw(selected_branch  andnotsel_branch)],
                               field   => 'r.smoke_branch' },
        hostnames         => { exclude => [qw(selected_host    andnotsel_host)],
                               field   => 'r.hostname' },
        compilers         => { exclude => [qw(selected_comp    andnotsel_comp)],
                               field   => 'c.cc',
                               config_join => 1 },
        compiler_versions => { exclude => [qw(selected_cver    andnotsel_cver)],
                               field   => 'c.ccversion',
                               config_join => 1 },
        smoker_versions   => { exclude => [qw(selected_smkv    andnotsel_smkv)],
                               field   => 'r.smoke_version' },
        summaries         => { exclude => [qw(selected_summary andnotsel_summary)],
                               field   => 'r.summary' },
    );

    # Batch all 10 DISTINCT queries into a single UNION ALL statement,
    # reducing 10 SQLite round-trips to 1.
    my @parts;
    my @all_bind;
    for my $dim (sort keys %dims) {
        my %f = %$filter;
        delete @f{ @{ $dims{$dim}{exclude} } };
        my ($from, $where, $bind) = $search->compile(\%f);
        if ($dims{$dim}{config_join} && $from !~ /JOIN config/) {
            $from .= " JOIN config c ON c.report_id = r.id";
        }
        push @parts, "SELECT DISTINCT '$dim' AS dim, $dims{$dim}{field} AS v $from $where";
        push @all_bind, @$bind;
    }

    my $sql  = join(" UNION ALL ", @parts);
    my $rows = $db->query($sql, @all_bind)->hashes->to_array;

    my %out;
    for my $row (@$rows) {
        next unless defined $row->{v} && length $row->{v};
        push @{ $out{$row->{dim}} }, $row->{v};
    }

    for my $dim (keys %dims) {
        $out{$dim} //= [];
        if ($dim eq 'hostnames') {
            $out{$dim} = [ sort { lc($a) cmp lc($b) } @{ $out{$dim} } ];
        }
        else {
            $out{$dim} = [ sort @{ $out{$dim} } ];
        }
    }

    $out{perl_versions} = _sort_perl_ids_desc($out{perl_versions});
    $out{summaries}     = _summary_buckets($out{summaries});

    return \%out;
}

# Bucket the raw distinct summaries from the DB into user-facing
# dropdown options:
#
#   * Anything starting with "PASS" -> single "PASS" option
#     (matches r.summary GLOB 'PASS*' downstream).
#   * Any "FAIL(...)" string contributes a "FAIL(*)" umbrella option
#     (matches every FAIL(...) downstream) AND one option PER LETTER
#     inside the parens, case-sensitive: "FAIL(XF)" yields "FAIL(*)",
#     "FAIL(X)", "FAIL(F)"; "FAIL(Mm)" yields "FAIL(M)" AND "FAIL(m)"
#     (uppercase M for missing-test, lowercase m for mistaken-test).
#   * Anything else passes through verbatim.
#
# Order: PASS first, then FAIL(*), then individual FAIL(x) lexically,
# then anything else lexically.
sub _summary_buckets ($raw) {
    my %seen;
    for my $s (@$raw) {
        next unless defined $s && length $s;
        if ($s =~ /^PASS/) {
            $seen{'PASS'} = 1;
        }
        elsif ($s =~ /^FAIL\(([^)]*)\)/) {
            $seen{'FAIL(*)'} = 1;
            $seen{"FAIL($_)"} = 1 for split //, $1;
        }
        else {
            $seen{$s} = 1;
        }
    }
    my $rank = sub ($v) {
        return 0 if $v eq 'PASS';
        return 1 if $v eq 'FAIL(*)';
        return 2 if $v =~ /^FAIL\(/;
        return 3;
    };
    return [
        sort { $rank->($a) <=> $rank->($b) || $a cmp $b } keys %seen
    ];
}

# Sort "M.m.p" perl_id strings highest-to-lowest, RPM-style: split on
# '.', compare each component numerically. SQL plevel ordering is
# non-deterministic when DISTINCT collapses many plevels per perl_id.
sub _sort_perl_ids_desc ($list) {
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

sub matrix ($self, %opts) {
    return $self->_matrix->matrix(%opts);
}

sub submatrix ($self, $test, $pversion = undef) {
    return $self->_matrix->submatrix($test, $pversion);
}

sub reports_from_id ($self, $rid, $limit = 100) {
    $limit = int($limit || 100);
    $limit = 1   if $limit < 1;
    $limit = 500 if $limit > 500;
    return [
        map { $_->{id} }
        @{ $self->{sqlite}->db->query(
            "SELECT id FROM report WHERE id >= ? ORDER BY id LIMIT ?",
            $rid, $limit
        )->hashes->to_array }
    ];
}

sub reports_from_epoch ($self, $epoch) {
    # Convert the epoch into ISO 8601 UTC TEXT for comparison.
    my @t  = gmtime($epoch);
    my $iso = sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];

    return [
        map { $_->{id} }
        @{ $self->{sqlite}->db->query(
            "SELECT id FROM report WHERE smoke_date >= ? ORDER BY id",
            $iso
        )->hashes->to_array }
    ];
}

1;
