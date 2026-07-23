-- 1 up

CREATE TABLE smoke_config (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    md5     TEXT    NOT NULL UNIQUE,
    config  TEXT
);

CREATE TABLE report (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    sconfig_id        INTEGER REFERENCES smoke_config(id),
    duration          INTEGER,
    config_count      INTEGER,
    reporter          TEXT,
    reporter_version  TEXT,
    smoke_perl        TEXT,
    smoke_revision    TEXT,
    smoke_version     TEXT,
    smoker_version    TEXT,
    smoke_date        TEXT NOT NULL,
    perl_id           TEXT NOT NULL,
    git_id            TEXT NOT NULL,
    git_describe      TEXT NOT NULL,
    applied_patches   TEXT,
    hostname          TEXT NOT NULL,
    architecture      TEXT NOT NULL,
    osname            TEXT NOT NULL,
    osversion         TEXT NOT NULL,
    cpu_count         TEXT,
    cpu_description   TEXT,
    username          TEXT,
    test_jobs         TEXT,
    lc_all            TEXT,
    lang              TEXT,
    user_note         TEXT,
    skipped_tests     TEXT,
    harness_only      TEXT,
    harness3opts      TEXT,
    summary           TEXT NOT NULL,
    smoke_branch      TEXT DEFAULT 'blead',
    plevel            TEXT NOT NULL,
    report_hash       TEXT NOT NULL UNIQUE,
    UNIQUE(git_id, smoke_date, duration, hostname, architecture)
);

CREATE INDEX report_architecture_idx          ON report(architecture);
CREATE INDEX report_hostname_idx              ON report(hostname);
CREATE INDEX report_osname_idx                ON report(osname);
CREATE INDEX report_osversion_idx             ON report(osversion);
CREATE INDEX report_perl_id_idx               ON report(perl_id);
CREATE INDEX report_plevel_idx                ON report(plevel);
CREATE INDEX report_smoke_date_idx            ON report(smoke_date);
CREATE INDEX report_plevel_hostname_idx       ON report(hostname, plevel);
CREATE INDEX report_smokedate_hostname_idx    ON report(hostname, smoke_date);
CREATE INDEX report_smokedate_plevel_hostname ON report(hostname, plevel, smoke_date);

CREATE TABLE config (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    report_id   INTEGER NOT NULL REFERENCES report(id) ON DELETE CASCADE,
    arguments   TEXT NOT NULL,
    debugging   TEXT NOT NULL,
    started     TEXT,
    duration    INTEGER,
    cc          TEXT,
    ccversion   TEXT
);
CREATE INDEX config_report_id_idx ON config(report_id);

CREATE TABLE result (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    config_id      INTEGER NOT NULL REFERENCES config(id) ON DELETE CASCADE,
    io_env         TEXT NOT NULL,
    locale         TEXT,
    summary        TEXT NOT NULL,
    statistics     TEXT,
    stat_cpu_time  REAL,
    stat_tests     INTEGER
);
CREATE INDEX result_config_id_idx ON result(config_id);

CREATE TABLE failure (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    test    TEXT NOT NULL,
    status  TEXT NOT NULL,
    extra   TEXT,
    UNIQUE(test, status, extra)
);

CREATE TABLE failures_for_env (
    result_id   INTEGER NOT NULL REFERENCES result(id)  ON DELETE CASCADE,
    failure_id  INTEGER NOT NULL REFERENCES failure(id) ON DELETE CASCADE,
    UNIQUE(result_id, failure_id)
);

CREATE TABLE tsgateway_config (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    name   TEXT NOT NULL UNIQUE,
    value  TEXT
);

INSERT INTO tsgateway_config (name, value) VALUES ('dbversion', '4');

-- 1 down

DROP TABLE failures_for_env;
DROP TABLE failure;
DROP TABLE result;
DROP TABLE config;
DROP TABLE report;
DROP TABLE smoke_config;
DROP TABLE tsgateway_config;

-- 2 up

CREATE INDEX report_smoke_branch_idx ON report(smoke_branch);

-- 2 down

DROP INDEX report_smoke_branch_idx;

-- 3 up

CREATE INDEX report_branch_arch_perl_summary ON report(smoke_branch, architecture, perl_id, summary);

-- 3 down

DROP INDEX report_branch_arch_perl_summary;

-- 4 up

CREATE INDEX failures_for_env_failure_id_idx ON failures_for_env(failure_id);

-- 4 down

DROP INDEX failures_for_env_failure_id_idx;

-- 5 up

CREATE TABLE admin_user (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT    NOT NULL UNIQUE,
    password_hash TEXT    NOT NULL,
    created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE api_token (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    token        TEXT    NOT NULL UNIQUE,
    note         TEXT    NOT NULL DEFAULT '',
    email        TEXT    NOT NULL DEFAULT '',
    created_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    cancelled_at TEXT,
    last_used_at TEXT,
    use_count    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX api_token_email_idx ON api_token(email);

ALTER TABLE report ADD COLUMN api_token_id INTEGER REFERENCES api_token(id);
CREATE INDEX report_api_token_id_idx ON report(api_token_id);

-- 5 down

DROP INDEX IF EXISTS report_api_token_id_idx;
ALTER TABLE report DROP COLUMN api_token_id;
DROP INDEX IF EXISTS api_token_email_idx;
DROP TABLE IF EXISTS api_token;
DROP TABLE IF EXISTS admin_user;

-- 6 up

CREATE INDEX report_smoke_version_idx ON report(smoke_version);
CREATE INDEX report_summary_idx       ON report(summary);
CREATE INDEX config_cc_idx            ON config(cc);
CREATE INDEX config_ccversion_idx     ON config(ccversion);

-- 6 down

DROP INDEX IF EXISTS config_ccversion_idx;
DROP INDEX IF EXISTS config_cc_idx;
DROP INDEX IF EXISTS report_summary_idx;
DROP INDEX IF EXISTS report_smoke_version_idx;
