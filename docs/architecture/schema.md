# Database schema

SQLite database, managed by Mojo::SQLite migrations
(`lib/CoreSmoke/Schema/migrations.sql`).

## Tables

### `report`

One row per smoke run.  Primary entity.

| Column            | Type    | Notes                                  |
|-------------------|---------|----------------------------------------|
| `id`              | INTEGER | PK, autoincrement                      |
| `sconfig_id`     | INTEGER | FK -> smoke_config.id                  |
| `duration`        | INTEGER | Total seconds                          |
| `config_count`    | INTEGER | Number of configurations tested        |
| `reporter`        | TEXT    | Client software name                   |
| `reporter_version`| TEXT    | Client software version                |
| `smoke_perl`      | TEXT    | Perl used to run Test::Smoke itself    |
| `smoke_revision`  | TEXT    | Git revision of the smoker             |
| `smoke_version`   | TEXT    | Test::Smoke version                    |
| `smoker_version`  | TEXT    | Smoker package version                 |
| `smoke_date`      | TEXT    | ISO 8601 UTC (NOT NULL)                |
| `perl_id`         | TEXT    | Version string e.g. "5.41.9" (NOT NULL)|
| `git_id`          | TEXT    | Git SHA of tested commit (NOT NULL)    |
| `git_describe`    | TEXT    | `git describe` output (NOT NULL)       |
| `applied_patches` | TEXT    | Newline-joined patch names             |
| `hostname`        | TEXT    | Reporting host (NOT NULL)              |
| `architecture`    | TEXT    | CPU arch e.g. "x86_64" (NOT NULL)      |
| `osname`          | TEXT    | OS name e.g. "linux" (NOT NULL)        |
| `osversion`       | TEXT    | OS version (NOT NULL)                  |
| `cpu_count`       | TEXT    | Number of CPUs                         |
| `cpu_description` | TEXT    | CPU model string                       |
| `username`        | TEXT    | Unix user running the smoker           |
| `test_jobs`       | TEXT    | Parallel test jobs                     |
| `lc_all`          | TEXT    | LC_ALL at smoke time                   |
| `lang`            | TEXT    | LANG at smoke time                     |
| `user_note`       | TEXT    | Free-text operator note                |
| `skipped_tests`   | TEXT    | Newline-joined skipped test names      |
| `harness_only`    | TEXT    | Harness-only flag                      |
| `harness3opts`    | TEXT    | TAP::Harness options                   |
| `summary`         | TEXT    | "PASS" or "FAIL(X)" etc. (NOT NULL)    |
| `smoke_branch`    | TEXT    | Git branch, defaults to "blead"        |
| `plevel`          | TEXT    | Sortable version string (NOT NULL)     |
| `report_hash`     | TEXT    | MD5 dedup key (NOT NULL, UNIQUE)       |
| `api_token_id`    | INTEGER | FK -> api_token.id (nullable)          |

**Constraints:**
- `UNIQUE(git_id, smoke_date, duration, hostname, architecture)`
- `report_hash` UNIQUE (pre-computed from the same 5 fields)

**Indexes:** hostname, architecture, osname, osversion, perl_id,
plevel, smoke_date, smoke_branch, and several compound indexes for
the `/latest` and `/search` queries.

### `config`

One row per compile configuration within a report.

| Column      | Type    | Notes                                |
|-------------|---------|--------------------------------------|
| `id`        | INTEGER | PK                                   |
| `report_id` | INTEGER | FK -> report.id (CASCADE)           |
| `arguments` | TEXT    | Configure flags (NOT NULL)           |
| `debugging` | TEXT    | Debugging mode "D"/"N" (NOT NULL)    |
| `started`   | TEXT    | ISO 8601 start time                  |
| `duration`  | INTEGER | Seconds for this config              |
| `cc`        | TEXT    | Compiler name                        |
| `ccversion` | TEXT    | Compiler version                     |

### `result`

One row per (config, io_env, locale) test result.

| Column          | Type    | Notes                             |
|-----------------|---------|-----------------------------------|
| `id`            | INTEGER | PK                                |
| `config_id`     | INTEGER | FK -> config.id (CASCADE)        |
| `io_env`        | TEXT    | I/O layer e.g. "perlio" (NOT NULL)|
| `locale`        | TEXT    | Locale tested (nullable)          |
| `summary`       | TEXT    | Single-char result (NOT NULL)     |
| `statistics`    | TEXT    | TAP stats text                    |
| `stat_cpu_time` | REAL    | CPU seconds                       |
| `stat_tests`    | INTEGER | Number of tests run               |

### `failure`

Deduplicated test failure records.

| Column   | Type    | Notes                                |
|----------|---------|--------------------------------------|
| `id`     | INTEGER | PK                                   |
| `test`   | TEXT    | Test file path (NOT NULL)            |
| `status` | TEXT    | Failure status code (NOT NULL)       |
| `extra`  | TEXT    | Extra diagnostic info                |

**Constraint:** `UNIQUE(test, status, extra)`

### `failures_for_env`

Junction table linking results to failures (many-to-many).

| Column       | Type    | Notes                            |
|--------------|---------|----------------------------------|
| `result_id`  | INTEGER | FK -> result.id (CASCADE)       |
| `failure_id` | INTEGER | FK -> failure.id (CASCADE)      |

**Constraint:** `UNIQUE(result_id, failure_id)`

### `smoke_config`

Deduplicated Perl build configuration blobs.

| Column   | Type    | Notes                               |
|----------|---------|-------------------------------------|
| `id`     | INTEGER | PK                                  |
| `md5`    | TEXT    | MD5 of the canonical JSON (UNIQUE)  |
| `config` | TEXT    | JSON blob of the config             |

### `tsgateway_config`

Key-value store for internal metadata.

| Column  | Type    | Notes                    |
|---------|---------|--------------------------|
| `id`    | INTEGER | PK                       |
| `name`  | TEXT    | Config key (UNIQUE)      |
| `value` | TEXT    | Config value             |

Currently holds `dbversion = '4'`.

### `admin_user`

Admin panel users (Argon2id password hashes).

| Column          | Type    | Notes                          |
|-----------------|---------|--------------------------------|
| `id`            | INTEGER | PK                             |
| `username`      | TEXT    | Login name (UNIQUE, NOT NULL)  |
| `password_hash` | TEXT    | Argon2id hash (NOT NULL)       |
| `created_at`    | TEXT    | ISO 8601                       |
| `updated_at`    | TEXT    | ISO 8601                       |

### `api_token`

Bearer tokens for authenticated report submission.

| Column         | Type    | Notes                             |
|----------------|---------|-----------------------------------|
| `id`           | INTEGER | PK                                |
| `token`        | TEXT    | 64-hex-char secret (UNIQUE)       |
| `note`         | TEXT    | Human-readable label              |
| `email`        | TEXT    | Contact email                     |
| `created_at`   | TEXT    | ISO 8601                          |
| `cancelled_at` | TEXT    | Set when revoked (nullable)       |
| `last_used_at` | TEXT    | Last successful auth (nullable)   |
| `use_count`    | INTEGER | Running counter                   |

## Entity relationships

```
smoke_config 1----* report 1----* config 1----* result
                     |                            |
                     *                            *
                api_token                  failures_for_env *----1 failure
```

## On-disk files

Large text fields (log_file, out_file, manifest_msgs, compiler_msgs,
nonfatal_msgs) are stored as xz-compressed files on disk rather than
in the database.  Path structure:

```
data/reports/<AA>/<BB>/<CC>/<full-report_hash>/<field>.xz
```

Where AA/BB/CC are the first 6 hex chars of `report_hash` split into
2-char directories for filesystem sharding.

`Model::ReportFiles` handles read/write with atomic temp-file +
rename.  The `has_file()` method checks existence without
decompressing.

## Pragmas

Set on every connection via `Model::DB`:

- `PRAGMA foreign_keys = ON` -- enforces FK constraints.
- `PRAGMA journal_mode = WAL` -- concurrent reads during writes.

## Migrations

Migrations are numbered `-- N up` / `-- N down` blocks in a single
SQL file.  The migration tracker name is `'coresmoke'` (shared between
the app, `script/migrate`, and `script/import-from-pgdump`).

Current migrations:
1. Base schema (all core tables + indexes).
2. `report_smoke_branch_idx` index.
3. Compound index for branch/arch/perl/summary.
4. `failures_for_env_failure_id_idx` index.
5. Admin user + API token tables; `report.api_token_id` column.
