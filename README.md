# Perl 5 Core Smoke DB (2.0)

[![ci](https://github.com/metacpan/perl5-test-smoke/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/metacpan/perl5-test-smoke/actions/workflows/ci.yml)
[![build base image](https://github.com/metacpan/perl5-test-smoke/actions/workflows/base.yml/badge.svg?branch=main)](https://github.com/metacpan/perl5-test-smoke/actions/workflows/base.yml)

A modern Perl/Mojolicious rewrite of the legacy three-repo
`Perl5-CoreSmokeDB{,-API,-Web}` stack, collapsed into a single app.

- **Perl 5.42** with modern idioms (`use v5.42`, signatures, postfix
  deref, the new `class` feature where natural)
- **Mojolicious** for both the JSON API *and* the server-rendered
  website (replaces Dancer2 + Vue 3 SPA)
- **SQLite** as the single backing store (`smoke.db`), mounted into
  the container as a host volume
- **xz on disk** for the large per-report blobs that used to be
  PostgreSQL `bytea` columns -- they live under
  `data/reports/<sharded-hash>/<field>.xz` instead
- **HTMX** for filter forms, matrix drill-down, and infinite scroll
  on the listing pages -- no Node toolchain
- **Single multi-stage Dockerfile**, multi-arch (amd64 + arm64),
  published to `ghcr.io`

The legacy repos are mounted as git submodules under `legacy/` for
reference and stay there indefinitely (decision #21). The 2.0 codebase
in this repo is the source of truth from now on.

## Quick start (development)

The `Makefile` handles dependency installation, dev server, test suite,
and everything else. Run `make` with no arguments to see all targets.

```sh
make build              # install brew packages (macOS), cpan deps, vendored JS
make dev                # morbo with auto-reload on http://localhost:3000
make test               # prove -lr t/ (877 tests, sequential)
make critic             # perlcritic --severity 5 lib/ script/

make migrate            # create empty schema in data/development.db
make dev-db SRC=dump.psql  # populate dev DB from a legacy pg_dump
make create-admin USER=admin PASS=secret   # bootstrap an admin user
```

Raw commands (without `make`) still work:

```sh
cpm install -L local/
PERL5LIB=local/lib/perl5:lib script/smoke morbo
PERL5LIB=local/lib/perl5:lib prove -lr t/
```

### macOS install gotchas

Two CPAN modules need C libraries that aren't on a fresh macOS by
default. Install them with Homebrew first, otherwise `cpm install`
will fail to build:

```sh
brew install sqlite3 xz
```

Then re-run `cpm` with the Homebrew include / lib paths exposed so
the XS builds can find the headers and shared libs:

```sh
CPATH=/opt/homebrew/include LIBRARY_PATH=/opt/homebrew/lib \
    cpm install -L local/
```

- `DBD::SQLite` needs `sqlite3` to link against the system SQLite.
- `IO::Compress::Xz` needs `xz` for `liblzma`.

## Quick start (Docker)

```sh
docker compose up
# In another shell:
curl http://localhost:3000/system/ping              # -> pong
curl http://localhost:3000/api/version              # -> {"version":"2.0",...}
```

The host directory `./data/` is mounted into the container at `/data`,
holding `smoke.db`, the WAL/SHM sidecars, and the `reports/` tree.

### Two-image build (base + prod)

The heavy CPAN + apt install lives in a **base image**
(`ghcr.io/<owner>/coresmoke-base:latest`, built from `Dockerfile.base`)
that's rebuilt only when `cpanfile`, `cpanfile.snapshot`, or
`Dockerfile.base` change. The **prod image** (`Dockerfile`) just
`FROM`s the base and copies the source on top, so a per-commit build
finishes in seconds.

CI handles this with two workflows:

- `.github/workflows/base.yml` — builds and pushes the multi-arch base
  image. Triggers: pushes to main that touch `cpanfile` /
  `cpanfile.snapshot` / `Dockerfile.base`, weekly cron (for upstream
  `perl:5.42-slim` CVE pickups), and manual `workflow_dispatch`.
- `.github/workflows/ci.yml` — runs `prove` + `perlcritic`, then
  builds + pushes the multi-arch prod image. Pulls the latest base
  image rather than rebuilding it.

To build locally without ghcr access, build the base first:

```sh
docker build -f Dockerfile.base -t coresmoke-base:local .
docker build --build-arg BASE_IMAGE=coresmoke-base:local -t coresmoke:dev .
```

## Repository layout

```
perl5-smoke/
├── legacy/                         # reference only -- the original three repos
│   ├── sql/  api/  web/
├── lib/CoreSmoke/                  # the 2.0 app
│   ├── App.pm                      # Mojolicious base class, helpers, routing
│   ├── Controller/                 # Api, JsonRpc, System, Ingest, Web, Admin
│   ├── JsonRpc/Methods.pm          # shared method registry (REST + JSONRPC)
│   ├── Model/                      # DB, Reports, Search, Matrix, Plevel,
│   │                               #   ReportFiles, Ingest, Auth
│   └── Schema/migrations.sql
├── templates/                      # Mojolicious EP templates
│   ├── layouts/                    #   default layout (topbar + footer)
│   ├── components/                 #   reusable design-system partials
│   ├── web/                        #   page templates (latest, search, matrix, ...)
│   ├── admin/                      #   admin UI (dashboard, tokens, users)
│   └── partials/                   #   topbar menu, command palette
├── public/                         # coresmoke.css, app.js, logo, htmx
├── script/
│   ├── smoke                       # Mojolicious launcher
│   ├── migrate                     # create/upgrade SQLite schema
│   ├── create-admin                # bootstrap admin user
│   ├── fix-plevels                 # recompute plevel for all reports
│   ├── import-from-pgdump          # legacy PG -> SQLite importer
│   ├── import-report-files-tarball # place on-disk report files from tarball
│   └── install-deps                # cpan dependency installer
├── etc/
│   ├── coresmoke{,.development,.test,.production}.conf
│   └── openapi.yaml                # API spec (served at /api/openapi/web.*)
├── t/                              # Test::Mojo suite (870+ tests)
├── docs/                           # current-state documentation
├── data/                           # gitignored: smoke.db, reports/, ...
├── plans/                          # the planning docs that drove the rewrite
├── cpanfile + cpanfile.snapshot
├── Dockerfile + Dockerfile.base + docker-compose.yml
└── .github/workflows/              # ci.yml (test+docker) + base.yml (base image)
```

## API surface

Every legacy method is exposed *both* as a REST path *and* as a JSONRPC
2.0 method at `POST /api`, sharing a single DAO so the two protocols
cannot drift apart. See `etc/openapi.yaml` (also reachable at
`/api/openapi/web.{json,yaml}`) for the full spec.

Pre-1.81 Test::Smoke clients are supported via:

- `POST /api/old_format_reports` -- form-urlencoded `json=<JSON>`
- `POST /report` -- built-in alias for the legacy Fastly redirect target

Both paths handle gzip request bodies (`Content-Encoding: gzip`).

## Admin interface

The web UI at `/admin` provides token and user management behind
session-based authentication (Argon2id + pepper). Bootstrap the first
admin user with `make create-admin USER=<name> PASS=<pw>`, then log in
at `/admin/login`.

- **Dashboard** -- report and token stats at a glance
- **API tokens** -- create, inspect, and cancel bearer tokens for
  authenticated ingest (`Authorization: Bearer <token>`)
- **Users** -- create admins, change passwords, delete accounts (last
  admin is protected)

## Operations

- **Listen port** is `3000`. **Hypnotoad workers** default to `2`.
- **Logging** goes to STDERR (`Mojo::Log`). The container captures it
  via Docker's logging driver -- no log files inside the container.
- **Health probes**: `GET /healthz` is always 200 if the process is
  alive; `GET /readyz` is 200 only if `SELECT 1` against SQLite works.
- **Backups** are out of scope for 2.0; long-term plan is S3-based
  off-host backups (decision #35). For now, snapshot `data/` how you
  normally would (`sqlite3 data/smoke.db .backup data/backup.db`).
- **Retention** -- there is none. SQLite handles billions of rows;
  add a janitor only when somebody asks for one (decision #25).
- **Multi-arch images** are built for `linux/amd64` and `linux/arm64`
  in CI and pushed to `ghcr.io/<owner>/coresmoke:latest` from `main`.
- **CVE scanning** runs Trivy in CI as report-only; findings are
  visible in the workflow run but never fail the build (decision #49).

## Migrating legacy data

`script/import-from-pgdump --source legacy.psql --target data/smoke.db`
streams a `pg_dump` plain-text file into the 2.0 SQLite schema, including
`report_hash` computation and `plevel` recompute via `Model::Plevel`. See
`plans/10-deferred-migration.md` for the full design and the (deferred)
plan for migrating the bytea columns onto disk.

## Plans

The 11 sub-plans in `plans/` drove the rewrite:

| # | File | Scope |
|---|------|-------|
| 00 | `plans/00-overview.md` | architecture + decisions |
| 01 | `plans/01-skeleton.md` | Mojolicious app skeleton |
| 02 | `plans/02-database.md` | SQLite schema + migration + plevel port |
| 03 | `plans/03-api-rest.md` | REST controllers |
| 04 | `plans/04-api-jsonrpc.md` | JSONRPC 2.0 dispatcher |
| 05 | `plans/05-ingest.md` | report ingestion (modern + legacy + gzip) |
| 06 | `plans/06-business-logic.md` | search filter, failure matrix, on-disk files |
| 07 | `plans/07-web-templates.md` | server-rendered pages with HTMX |
| 08 | `plans/08-docker.md` | single multi-stage Dockerfile |
| 09 | `plans/09-testing.md` | Test::Mojo strategy + CI |
| 10 | `plans/10-deferred-migration.md` | legacy-data importer (deferred) |

## License

Same terms as Perl itself (decision #4).
