package CoreSmoke::Model::Ingest;
use v5.42;
no source::encoding;   # Date::Parse uses eval-strings with non-ASCII month names
use warnings;
use experimental qw(signatures);

use Date::Parse qw(str2time);
use Digest::MD5 qw(md5_hex);
use Mojo::JSON  qw(encode_json);

use CoreSmoke::Model::Plevel;

# Columns we actually persist into `report`. Anything else from the input is
# silently dropped (the legacy clients send a lot of extra metadata).
my @REPORT_COLS = qw(
    sconfig_id duration config_count reporter reporter_version
    smoke_perl smoke_revision smoke_version smoker_version smoke_date
    perl_id git_id git_describe applied_patches hostname architecture
    osname osversion cpu_count cpu_description username test_jobs
    lc_all lang user_note skipped_tests harness_only harness3opts
    summary smoke_branch plevel report_hash api_token_id
);

# Same as plan 05 / decision #30 -- written to disk, not the DB.
my @ON_DISK_FIELDS = qw(log_file out_file manifest_msgs compiler_msgs nonfatal_msgs);

# Top-level array fields that are joined with newlines into a single TEXT
# column.
my @ARRAY_TO_TEXT = qw(skipped_tests applied_patches);

sub new ($class, %args) {
    my $sqlite       = $args{sqlite}       // die "sqlite required";
    my $report_files = $args{report_files} // die "report_files required";
    my $auth         = $args{auth};
    return bless { sqlite => $sqlite, report_files => $report_files, auth => $auth }, $class;
}

sub post_report ($self, $raw, %opts) {
    return { error => 'Missing report_data.' } unless ref $raw eq 'HASH';

    my ($data, $files) = $self->_normalize($raw);

    # Compute plevel + report_hash.
    $data->{plevel}      = CoreSmoke::Model::Plevel::from_git_describe(
        $data->{git_describe} // '',
        $data->{perl_id},
    );
    $data->{report_hash} = $self->{sqlite}->report_hash($data);

    # Write on-disk content first (decision #33: best-effort, files first).
    $self->{report_files}->write($data->{report_hash}, $files) if %$files;

    # Validate API token if provided.
    my $api_token_string = $opts{api_token};
    if (defined $api_token_string && $self->{auth}) {
        my $token_row = $self->{auth}->validate_token($api_token_string);
        if ($token_row) {
            $data->{api_token_id} = $token_row->{id};
            $self->{auth}->record_token_use($token_row->{id});
        }
    }

    # Smoke config dedup.
    my $sconfig_id = $self->_upsert_smoke_config($raw->{_config});
    $data->{sconfig_id} = $sconfig_id;

    my $configs_in = $raw->{configs} // [];

    my $db = $self->{sqlite}->db;
    my $tx = $db->begin;
    my $rid = eval {
        my $id = $self->_insert_report($db, $data);
        for my $cfg (@$configs_in) {
            my $cid = $self->_insert_config($db, $id, $cfg);
            for my $res (@{ $cfg->{results} // [] }) {
                my $resid = $self->_insert_result($db, $cid, $res);
                $self->_insert_failures($db, $resid, $res->{failures} // []);
            }
        }
        $id;
    };
    if (my $e = $@) {
        if ("$e" =~ /UNIQUE constraint failed/i) {
            return { error => 'Report already posted.', db_error => "$e" };
        }
        die $e;
    }
    $tx->commit;
    return { id => $rid };
}

# ----------------------------------------------------------------------
# Normalization
# ----------------------------------------------------------------------

sub _normalize ($self, $raw) {
    my %data;

    # 1. Flatten sysinfo into the top level (legacy contract).
    my $sysinfo = $raw->{sysinfo} // {};
    for my $k (keys %$sysinfo) {
        $data{ lc $k } = $sysinfo->{$k};
    }

    # 2. Top-level extras the legacy ingest pulls in.
    for my $k (qw(harness_only harness3opts summary)) {
        $data{$k} = $raw->{$k} if exists $raw->{$k};
    }

    # 3. Top-level array-to-text fields.
    for my $k (@ARRAY_TO_TEXT) {
        my $v = $raw->{$k};
        $data{$k} = ref $v eq 'ARRAY' ? join("\n", @$v) : ($v // '');
    }

    # 4. Normalize smoke_date to ISO 8601 UTC TEXT.
    if (defined $data{smoke_date} && length $data{smoke_date}) {
        $data{smoke_date} = _to_iso_utc($data{smoke_date});
    }

    # 5. smoke_branch defaults to 'blead'.
    $data{smoke_branch} //= 'blead';

    # 6. Extract on-disk fields. Arrays become newline-joined text on disk;
    #    scalar strings pass through.
    my %files;
    for my $field (@ON_DISK_FIELDS) {
        my $v = $raw->{$field};
        next unless defined $v;
        $v = join("\n", @$v) if ref $v eq 'ARRAY';
        next unless length $v;
        $files{$field} = $v;
    }

    return (\%data, \%files);
}

sub _to_iso_utc ($ts) {
    return $ts if $ts =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
    my $epoch = str2time($ts);
    return $ts unless defined $epoch;
    my @t = gmtime($epoch);
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

# ----------------------------------------------------------------------
# Smoke config dedup (md5 over canonical JSON of the _config payload).
# ----------------------------------------------------------------------

sub _upsert_smoke_config ($self, $config) {
    return unless defined $config;

    my $json = ref $config ? encode_json($config) : "$config";
    my $md5  = md5_hex($json);

    my $db = $self->{sqlite}->db;

    # Try insert; if unique-violates on md5 the row already exists.
    eval {
        $db->query(
            "INSERT INTO smoke_config (md5, config) VALUES (?, ?)",
            $md5, $json,
        );
    };
    if (my $e = $@) {
        die $e unless "$e" =~ /UNIQUE constraint failed/i;
    }

    my $row = $db->query(
        "SELECT id FROM smoke_config WHERE md5 = ?", $md5
    )->hash;
    return $row ? $row->{id} : undef;
}

# ----------------------------------------------------------------------
# Inserts
# ----------------------------------------------------------------------

sub _insert_report ($self, $db, $data) {
    my @cols = grep { exists $data->{$_} && defined $data->{$_} } @REPORT_COLS;
    # NOT NULL columns must always be present (ensure with sane defaults).
    for my $must_have (qw(smoke_date perl_id git_id git_describe hostname architecture osname osversion summary plevel report_hash)) {
        unless (grep { $_ eq $must_have } @cols) {
            die "report.$must_have is required";
        }
    }
    my $placeholders = join ',', ('?') x @cols;
    my $colnames     = join ',', @cols;
    my @vals         = @{$data}{@cols};

    $db->query(
        "INSERT INTO report ($colnames) VALUES ($placeholders)", @vals,
    );
    return $db->dbh->last_insert_id(undef, undef, 'report', undef);
}

sub _insert_config ($self, $db, $report_id, $cfg) {
    $db->query(<<~'SQL',
        INSERT INTO config (report_id, arguments, debugging, started, duration, cc, ccversion)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
        $report_id,
        $cfg->{arguments}  // '',
        $cfg->{debugging}  // 'N',
        _to_iso_utc($cfg->{started} // ''),
        $cfg->{duration},
        $cfg->{cc}        // '?',
        $cfg->{ccversion} // '?',
    );
    return $db->dbh->last_insert_id(undef, undef, 'config', undef);
}

sub _insert_result ($self, $db, $config_id, $res) {
    $db->query(<<~'SQL',
        INSERT INTO result (config_id, io_env, locale, summary, statistics, stat_cpu_time, stat_tests)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
        $config_id,
        $res->{io_env}        // '',
        $res->{locale},
        $res->{summary}       // '',
        $res->{statistics},
        $res->{stat_cpu_time},
        $res->{stat_tests},
    );
    return $db->dbh->last_insert_id(undef, undef, 'result', undef);
}

sub _insert_failures ($self, $db, $result_id, $failures) {
    for my $f (@$failures) {
        next unless ref $f eq 'HASH';
        my $extra = $f->{extra};
        $extra = join("\n", @$extra) if ref $extra eq 'ARRAY';

        $extra //= '';

        my $fid = $db->query(<<~'SQL', $f->{test}, $f->{status}, $extra)->hash->{id};
            INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)
            ON CONFLICT(test, status, extra) DO UPDATE SET test = test
            RETURNING id
            SQL

        $db->query(
            "INSERT OR IGNORE INTO failures_for_env (result_id, failure_id) VALUES (?, ?)",
            $result_id, $fid,
        );
    }
}

1;
