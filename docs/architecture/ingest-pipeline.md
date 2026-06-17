# Ingest pipeline

How a Test::Smoke report enters the system, gets validated,
normalized, and stored.

## Wire formats

Two formats are accepted, distinguished by `Content-Type`:

### Modern (application/json)

```json
POST /api/report
Content-Type: application/json
Authorization: Bearer <token>

{
  "report_data": { ... }
}
```

Sent by Test::Smoke >= 1.81_01.

### Legacy (application/x-www-form-urlencoded)

```
POST /api/report
Content-Type: application/x-www-form-urlencoded

json=<percent-encoded JSON of report data>
```

Sent by Test::Smoke 1.70--1.80.  Still accounts for the majority of
inbound traffic.  The `json` param is percent-encoded via
`URI::Escape` (or `CGI::Util::escape` on clients before Oct 2022).

Both formats reach the same `Ingest#post_report` controller action
regardless of URL path.

## Authentication

Optional. If a `Bearer <token>` header is present, the token is
validated against `api_token` (must exist and not be cancelled).
Authenticated reports get `api_token_id` set; unauthenticated ones
get NULL.

Token validation happens AFTER normalization but BEFORE the database
insert, so a bad token doesn't prevent the report from being stored
-- it just lands as unauthenticated.

## Pipeline stages

```
Controller (Ingest.pm)
  |  _extract_report_data() -- parse JSON, return hashref or 4xx
  v
Model::Ingest::post_report($raw, api_token => ...)
  |
  |-- 1. _normalize($raw) -> (%data, %files)
  |-- 2. Compute plevel (from git_describe + perl_id)
  |-- 3. Compute report_hash (MD5 of 5 dedup fields)
  |-- 4. Write on-disk files (best-effort, before DB)
  |-- 5. Validate & record API token
  |-- 6. Upsert smoke_config (dedup on MD5)
  |-- 7. BEGIN transaction
  |       |-- _insert_report (validates required fields)
  |       |-- for each config:
  |       |     |-- _insert_config
  |       |     |-- for each result:
  |       |           |-- _insert_result
  |       |           |-- _insert_failures (dedup via UPSERT)
  |-- 8. COMMIT
  v
Return { id => $rid } on success, { error => ... } on failure
```

## Normalization (_normalize)

Transforms the raw client payload into a flat hash suitable for the
`report` table:

1. **Flatten sysinfo**: `$raw->{sysinfo}` keys are lowercased and
   merged into the data hash.  This is the legacy contract where
   system metadata rides inside a nested object.

2. **Top-level overrides**: `harness_only`, `harness3opts`, `summary`
   from the top level override any sysinfo-derived values.

3. **Array-to-text**: `skipped_tests` and `applied_patches` are
   joined with newlines if they arrive as arrays.

4. **Date normalization**: `smoke_date` is converted to ISO 8601 UTC
   via `Date::Parse::str2time` + `gmtime`.  Already-ISO timestamps
   pass through unchanged.

5. **Branch default**: `smoke_branch` defaults to `'blead'`.

6. **On-disk extraction**: `log_file`, `out_file`, `manifest_msgs`,
   `compiler_msgs`, `nonfatal_msgs` are pulled from `$raw` into a
   separate `%files` hash.  Arrays are newline-joined.

## Plevel computation

`Model::Plevel::from_git_describe()` converts a git describe string
(e.g. `v5.41.9-21-gabcdef`) into a sortable string
(`5.041009zzz021`).  Format:

```
<major>.<minor:3><patch:3><RC|zzz><commits:3>
```

- RC releases get the literal `RC<N>` suffix instead of `zzz`.
- Bare commit SHAs (no v5.X.Y prefix) fall back to `perl_id`-derived
  plevel or a low-sorting sentinel.

## Report hash (dedup key)

```perl
md5_hex(join "\0", git_id, smoke_date, duration, hostname, architecture)
```

Matches the UNIQUE constraint on the `report` table.  Computed before
the DB insert so the UNIQUE violation produces a clean 409 rather than
an opaque constraint error.

## On-disk file storage

Fields too large for comfortable DB storage are xz-compressed and
written to the filesystem BEFORE the database insert (decision #33:
best-effort, files first).  Path:

```
<reports_root>/<AA>/<BB>/<CC>/<report_hash>/<field>.xz
```

Writes use atomic temp-file + rename (same filesystem, POSIX-atomic).
Compression preset 6.  Individual file failures log a warning and
continue -- they don't abort the ingest.

## Failure dedup

The `failure` table deduplicates on `(test, status, extra)`.  The
insert uses:

```sql
INSERT INTO failure (test, status, extra) VALUES (?, ?, ?)
ON CONFLICT(test, status, extra) DO UPDATE SET test = test
RETURNING id
```

The no-op `DO UPDATE` trick forces SQLite to return the existing row's
id via `RETURNING`.  The `failures_for_env` junction table links each
result to its failure ids with `INSERT OR IGNORE`.

## Smoke config dedup

The `_config` blob (the `./Configure` options used to build Perl) is
stored once and referenced by id.  Dedup key: MD5 of the canonical
JSON encoding.  Upsert via try-INSERT + catch-UNIQUE + SELECT.

## Error responses

| Condition               | HTTP | Response body                    |
|-------------------------|------|----------------------------------|
| Missing/unparseable JSON| 400  | `{ error: "Bad JSON..." }`       |
| Missing report_data key | 422  | `{ error: "Missing report_data."}`|
| Duplicate report        | 409  | `{ error: "Report already posted.", db_error: ... }` |
| Success                 | 200  | `{ id: <integer> }`              |

## Supported client versions

Test::Smoke >= 1.70.  Anything older is unsupported.  The oldest
version observed reporting in the last 10 years is 1.70_02.
