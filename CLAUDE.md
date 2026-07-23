# CLAUDE.md — project-specific notes for AI assistants

This is a Mojolicious 2.0 rewrite of the legacy CoreSmokeDB stack. It
collapses three repos (`Perl5-CoreSmokeDB{,-API,-Web}`, mounted under
`legacy/`) into one Perl 5.42 app backed by SQLite, with on-disk xz
report files instead of `bytea` columns. The `plans/` directory holds
the planning docs; this file is the **gotchas and conventions** layer
on top.

## Where things live

```
lib/CoreSmoke/         — namespace is `CoreSmoke`, NOT `Perl5::CoreSmoke`
  App.pm               — Mojolicious base class
  Controller/          — Api, JsonRpc, System, Ingest, Web
  JsonRpc/Methods.pm   — single registry shared by REST + JSONRPC
  Model/               — DB, Reports, Search, Matrix, Plevel,
                         ReportFiles, Ingest
  Schema/migrations.sql
templates/             — Mojolicious EP templates
  layouts/default.html.ep — top-level shell (topbar + main + footer)
  partials/menu.html.ep   — split topbar (brand / nav / utilities)
  partials/palette.html.ep — Cmd+K command-palette overlay markup
  components/          — reusable design-system partials, see below
  web/                 — page templates per Web controller action
public/                — coresmoke.css, app.js, favicon.ico, icon.svg,
                         (gitignored) htmx.min.js
script/{smoke,migrate,fix-plevels,import-from-pgdump}
etc/{coresmoke,*.conf,openapi.yaml}
data/                  — gitignored: SQLite + reports/ tree
t/                     — sequential prove (single shared t/test.db)
docs/                  — knowledge base (see "Docs" section below)
  README.md            — index
  architecture/        — request flow, DB, ingest, JSONRPC dispatch
  features/            — one .md per user-facing feature
  conventions/         — coding/test/deploy patterns
  operations/          — runbooks, troubleshooting
plans/00..10/          — the planning docs
```

## Docs — knowledge base

`docs/` is the **current-state** reference for this project. It answers
"how does feature X work today?" and "what convention applies here?".

Roles, kept distinct on purpose:

| Where         | What goes there                                            |
|---------------|------------------------------------------------------------|
| `plans/`      | Forward-looking design (what we intend to build).          |
| `docs/`       | How things actually work right now.                        |
| `CLAUDE.md`   | Terse rules + gotchas that bite repeatedly. Entry point.   |

### Layout

- `docs/README.md`     — index, points at the rest.
- `docs/architecture/` — request flow, schema, ingest pipeline, JSONRPC
                         dispatch, htmx integration, etc.
- `docs/features/`     — one `.md` per user-facing feature
                         (search, matrix, ingest endpoints, web pages).
- `docs/conventions/`  — coding/test/deploy patterns that need more than
                         a CLAUDE.md gotcha line.
- `docs/operations/`   — runbooks, troubleshooting, on-call notes.

### When to read

**Before making non-trivial code changes**, scan `docs/` for context on
the area you're touching. Start at `docs/README.md`, then drill into the
relevant subdir. If a doc contradicts the code, trust the code and flag
the drift to the user.

### When to write / update

Update or create a `docs/` file when the change is one of:

- **New user-facing feature** — endpoint, page, CLI command, or
  significant UI change. Add/update `docs/features/<feature>.md`.
- **Architectural change** — data flow, module boundaries, schema,
  ingest pipeline, deployment shape. Update `docs/architecture/`.
- **New convention or gotcha** worth more than a one-liner. Put deep
  reference in `docs/conventions/`; keep the terse rule in `CLAUDE.md`.

Skip doc updates for pure refactors, cosmetic changes, or one-off bug
fixes whose root cause already lives in the commit message.

If the right doc doesn't exist yet, create it — don't skip the update.
Ask the user when scope is unclear.

## DB / file locations by mode

| Mode | DB path | Reports tree |
|------|---------|--------------|
| development (`make start`/`make dev`) | `data/development.db` | `data/reports/` |
| test (TestApp.pm sets MOJO_MODE=test) | `t/test.db` | `t/data/reports-tmp/` |
| production (Docker container) | `/data/smoke.db` (env-mounted volume) | `/data/reports/` |

`Model::DB` and `Model::ReportFiles` resolve relative paths under
`MOJO_HOME` via `_resolve_path`; absolute paths from `$ENV{SMOKE_DB_PATH}`
or `$ENV{SMOKE_REPORTS_DIR}` pass through unchanged.

## Auto-migrate is OFF in development

`auto_migrate => 0` in `etc/coresmoke.development.conf`. `make start`
refuses to silently fabricate an empty DB. Run **one of**:

- `make migrate` — empty schema only
- `make dev-db SRC=csdb.psql` — populated from a pg_dump
- `make fix-plevels` — recompute `report.plevel` after a Plevel.pm change

Production and test modes still auto-migrate (container's first boot
needs to bootstrap an empty `/data`; tests reset `t/test.db` between
runs).

## Things that bit us once and shouldn't again

### `return` vs `return undef`

**Default: always `return;` -- never `return undef;`.** perlcritic
enforces this via `Subroutines::ProhibitExplicitReturnUndef` at
severity 5, and `make critic` is a commit gate. A bare `return;`
yields `undef` in scalar context and `()` (empty list) in list
context, which is what callers almost always want.

The **only** time `return undef;` is justified: a sub that may be
called in **list context** AND represents a "this slot is null but
should still be counted" semantic -- e.g. column decoders fed into
`map { decode_field($_) } @raw`, where bare `return;` would yield
`()` instead of `(undef)` and silently shift every subsequent column
in the row. (This exact bug ate every `\N` field in the pg-dump
importer once -- don't let it happen again.)

When you genuinely need it, the exemption is verbose on purpose:

```perl
return undef;  ## no critic (Subroutines::ProhibitExplicitReturnUndef)
```

plus a one-line comment explaining why list context matters here.
If you can't write that comment honestly, you don't need
`return undef;` -- just `return;`.

### `use v5.42` enables strict ASCII source encoding

Em-dashes (`—`) in comments will break compilation. Stick to ASCII in
.pm files.

`Date::Parse` uses `eval "..."` with non-ASCII month names, which dies
under v5.42's strict ASCII. Files that import it need:

```perl
use v5.42;
no source::encoding;   # Date::Parse uses eval-strings w/ non-ASCII chars
```

(Currently `lib/CoreSmoke/Model/Ingest.pm`.)

### Mojolicious EP templates: `print` doesn't go to the output

```ep
% if ($x) { print 'selected'; }   # WRONG — writes to controller stdout
<%= $x ? 'selected' : '' %>       # right
<%= selected_if($x) %>            # right (helper in App.pm)
```

The latent `print 'selected'` bug meant our `<select>` dropdowns
weren't actually marking the picked option `selected` — only became
visible after we started swapping the form on filter change.

### Mojolicious helpers we register

App.pm registers a few helpers that aren't in `Mojolicious::Plugin::DefaultHelpers`:

- `url_escape($s)` — wraps `Mojo::Util::url_escape`. Default Mojo
  doesn't expose it, but our templates use it for query-string
  assembly.
- `selected_if($cond)` — returns `'selected'` or `''` for
  `<option>`/`<input>` markup.
- `sqlite`, `report_files`, `reports`, `ingest`, `auth` — DAO accessors.
- `bearer_token` — extracts Bearer token from Authorization header.
  Returns the token string or undef. Used by Ingest and JSONRPC
  post_report handlers.
- `duration_hms($seconds)` — formats a duration like `1h 5m 12s`.
- `badge($text, $variant)` / `status_pill($summary)` /
  `nav_link($label, $href)` / `btn_link($label, $href, $variant?, $size?)`
  — design-system component helpers. Return `Mojo::ByteStream` of
  pre-escaped HTML. See "Design system" below.
- `asset_url('/coresmoke.css')` — appends `?v=<mtime>` for cache busting.
  Use it in the layout for every static CSS/JS asset reference.
  mtime is stat'd once per worker per asset (closure-cached), so it's
  effectively free. Hot-reload (`make reload`) restarts workers and
  picks up the new mtime automatically.

### Controller namespace

```perl
$self->routes->namespaces(['CoreSmoke::Controller']);
```

Without this, Mojolicious looks for controllers under
`CoreSmoke::App::Controller::*` and 500s with "Controller does not exist".

### Mojo::SQLite pragmas

Mojo::SQLite does **not** enable `PRAGMA foreign_keys = ON` or
`journal_mode = WAL` by default. `Model::DB::sqlite()` registers an
`on(connection => ...)` callback that runs both for every new handle.

### `or die` in hash construction

`path => $args{path} or die '...'` parses as
`(path, $args{path}) or die '...'` — the right-hand `or` consumes the
pair. Use `//`:

```perl
my $path = $args{path} // die 'path required';
my $self = bless { path => $path, ... }, $class;
```

### Hypnotoad doesn't preserve cwd

Hence `_resolve_path` in App.pm. Also the `Mojolicious::Plugin::Config`
`pid_file` is resolved against `cwd` not `MOJO_HOME`, so we rewrite it
in startup too.

### HTMX recipes that work here

- **Replace the trigger element on infinite scroll**: `hx-swap="outerHTML"`
  (not `afterend`, which leaves stale "Loading more..." rows).
- **Refresh form + table together on filter change**: target a wrapper
  `<div id="search-region">` with `hx-swap="outerHTML"`. Distinguish
  form-change requests from infinite-scroll requests via the
  `HX-Trigger` header (form has id="search-form", load-more `<tr>` has
  no id).
- **Live-update a header during infinite scroll**: emit an OOB
  `<element id="..." hx-swap-oob="true">` from the same response. Gate
  via a stash flag so the OOB markup only appears on HTMX responses,
  not on the initial full-page render (where it would just duplicate
  the inline element).
- **Push a clean URL**: `hx-push-url="true"` + `hx-on::config-request`
  to drop default-valued (`all`/empty) params from
  `event.detail.parameters` before HTMX builds the URL.

### Design system: use it, don't reinvent it

Visual reference: `docs/design-system/metacpan-design-system.html`
(open in a browser). Long-form usage notes:
`docs/conventions/design-system.md`.

**For any UI work** — new page, edited page, new HTMX fragment — reach
for these in priority order:

1. A helper from `App.pm`: `badge`, `status_pill`, `nav_link`,
   `btn_link`. Cheapest, most ergonomic.
2. A partial in `templates/components/`: `hero`, `stat`, `page_header`,
   `breadcrumb`, `card`, `alert`, `data_table`, `code_block`,
   `empty_state`, `form_field`, `pagination_summary`, `tabs`,
   `spinner`, `skeleton_rows`, `status_chips`, `badge`. Always pass
   content via `body => begin ... end` blocks for blocks that need
   raw HTML.
3. Existing design-system classes from `public/coresmoke.css`
   (`.btn`, `.card`, `.alert`, `.data-table`, `.dl-grid`, ...).
4. Only if none of the above fit: extend `coresmoke.css` with a new
   rule that **composes from existing tokens** (`var(--accent)`,
   `var(--space-4)`, `--success-500`, etc.) and add a partial or
   helper for it. Document it in `docs/conventions/design-system.md`.

**Forbidden** (CI grep checks for these in the verification step):

- Hex colors anywhere outside the `:root` and `[data-theme="dark"]`
  blocks of `public/coresmoke.css`.
- `style="..."` in templates, **except** the documented
  `style="--ratio: NN%"` on heatmap cells in `web/matrix.html.ep`.
- Pixel sizes outside the `--space-*` scale (exceptions: 1-3px
  borders, the heatmap `--ratio` percentage).
- Class names that don't appear in `public/coresmoke.css` — if you
  invent a class, define it.

**Page header**: every page sets a `page_header` stash entry; the
layout includes the partial. Minimum is `crumbs => [...]` +
`title => '...'`. Optional: `subtitle`, `actions => begin ... end`.

**HTMX + components**: when returning an HTMX fragment, render the
SAME partial as the full-page render. OOB swap targets keep their ids
across renders (`#latest-summary`, `#search-region`, no-id load-more
`<tr>`). The `pagination_summary` partial emits `data-count="N"` so
the filter-change toast in `app.js` can read it without a re-query.

**Dark mode**: bootstrap script in the `<head>` of `default.html.ep`
sets `data-theme` from `localStorage.theme` (falls back to
`prefers-color-scheme`). Toggle via the topbar button. **Never**
assume background is white — use `--bg-*` / `--fg-*` tokens. Test
both themes before considering a UI change done.

**Cmd+K palette**: `templates/partials/palette.html.ep` renders a
closed-by-default overlay. `app.js` opens it on `Cmd+K`/`Ctrl+K`
and on click of the topbar trigger chip. Free-text Enter submits to
`/search?selected_summary=<query>`. Add jump entries to the
palette's `<ul class="palette-list">` when introducing a new
top-level page.

**Hero blocks**: landing pages (`/latest`, `/matrix`, `/about`) use
the `hero` partial: optional eyebrow, big Fraunces title with `<em>`
italic accent, lede paragraph, and a stat strip
(`stats => [{ label, value, variant?: success|danger|accent }, ...]`).
Use sparingly — sub-pages (e.g. `/report/:rid`, `/submatrix`,
`/file/...`) keep the smaller `page_header` partial.

**Brand & logo**: `public/logo.png` is the canonical brand mark
(also referenced by `<link rel="icon">` and the topbar / footer
brand block). Topbar brand is a 3-row composition: 36px round logo,
`brand-name` (Fraunces, italic accent on the suffix `<em>DB</em>`),
small uppercase `brand-meta`. Don't replace it with text-only.

**Tables**: every tabular page uses the `data_table` partial. Power
features wired in `coresmoke.css` + `app.js`:
- Sticky `<thead>` (already in `.data-table th`).
- Subtle zebra rows + hover.
- Clickable rows: add `data-href="/report/<id>"` on `<tr>`; JS
  navigates on click (ignores clicks on inner links/buttons).
- Status emphasis: row gets `row-accent-<variant>` AND the status
  cell gets `status-cell-<variant>` for the column tint.
- Sortable columns: pass `headers => [{label, sort=><key>}, ...]`.
  Each `<td>` carries `data-sort-key="<key>"` (and optional
  `data-sort-value=` for non-text comparisons). Sorting is
  client-side, scoped to the visible page; works without HTMX swaps.
- Density toggle: topbar button toggles
  `body.density-compact`. JS persists `localStorage.density`.
  Compact halves row padding via the rule in `coresmoke.css`.

**Asset cache busting**: every `<link rel=stylesheet>` and `<script
src>` that points at `/coresmoke.css`, `/app.js`, `/htmx.min.js`,
`/logo.png`, etc. MUST go through the `asset_url` helper:
`<%= asset_url '/coresmoke.css' %>`. The helper appends
`?v=<mtime>`; a fresh edit + `make reload` invalidates browser
caches automatically.

### SQLite GLOB vs LIKE

LIKE is case-insensitive for ASCII; GLOB is case-sensitive. The
Status filter on `/search` matches `FAIL(M)` ≠ `FAIL(m)` via GLOB
patterns like `FAIL(*M*)`.

### Docker

- Two-image build:
  - `Dockerfile.base` (built by `.github/workflows/base.yml`) carries
    apt + CPAN deps + the unprivileged `smoke` user + vendored htmx.
    Rebuilds **only** when `cpanfile`, `cpanfile.snapshot`, or
    `Dockerfile.base` change (or weekly cron, or workflow_dispatch).
    `no-cache: true` so the install really runs each time.
  - `Dockerfile` is just `FROM ${BASE_IMAGE} + COPY . /app + ENV/CMD`.
    Per-commit builds are essentially a single COPY layer.
- Base image is `perl:5.42-slim` (Debian-slim). `perl:5.42-alpine`
  isn't published, so don't try to switch to Alpine.
- `COPY --chown=smoke:smoke` instead of `chown -R` after COPY: avoids
  duplicating the entire CPAN tree into a new layer.
- The CI docker job is gated `if: github.event_name == 'push' &&
  github.ref == 'refs/heads/main'` — PRs run only the test job.

### CI gotchas

- `perl-actions/install-with-cpm@v2` defaults `global: true` and
  `sudo: true`. We use `sudo: false` (slim has no sudo, and we run as
  root in the container anyway) and `snapshot: false` (action calls
  Carton::Snapshot which isn't installed yet at that point).
- `cpm --workers=6` (1.5× the 4-vCPU runner) keeps cores busy during
  network/disk waits.
- Capture cpm output to a log and dump on failure only — Menlo's
  per-file install lines drown the build log otherwise.

## Conventions

- **Docs follow code**: features and architectural changes update
  `docs/` in the same PR (see "Docs — knowledge base" section above).
- **Tests are sequential**: single shared `t/test.db` reset between
  tests. `prove -lr t/`, no `-j`.
- **perlcritic severity 5**, fail on violation. Run via `make critic`.
  Rules are enforced, not advisory. The one that bites most often is
  `Subroutines::ProhibitExplicitReturnUndef` -- never write
  `return undef;` without a documented reason (see "`return` vs
  `return undef`" above). Default to plain `return;`; scalar context
  gives you `undef` for free.
- **Devel::Cover** report-only in CI, no threshold.
- **Commits**: detailed body explaining the why; ends with
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
  Both `make test` AND `make critic` must pass before committing --
  perlcritic violations are fail-the-build, not warnings, so don't
  commit code that hasn't cleared both gates.
- **Ingest URLs**: `POST /api/report` (modern default since
  Test::Smoke 1.81_01), `POST /api/old_format_reports`, and
  `POST /report` (pre-1.81 default) all hit the same
  `Ingest#post_report` handler, which dispatches on Content-Type
  and accepts BOTH wire formats: legacy
  `application/x-www-form-urlencoded` with `json=<urlencoded JSON>`
  and modern `application/json` body `{"report_data": <JSON>}`.
  This protects against smoker config drift (URL upgraded but
  client wasn't, or vice versa). The Fastly silent redirect from
  `/report` -> `/api/old_format_reports` is being retired -- the
  Mojolicious router now handles both paths natively, so no edge
  rewrite is needed. `gzip` Content-Encoding accepted on every
  POST. The legacy `/api/outfle/:rid` typo is kept as an alias for
  `/api/outfile/:rid` -- existing clients in the wild still hit it.
- **Supported Test::Smoke client versions**: `>= 1.70`. Anything
  older is not supported and may be rejected without notice. The
  oldest version observed reporting in the last 10 years (per
  `data/development.db`) is `1.70_02`, so 1.70 is the practical
  floor.
- **Don't drop the form-decode path**: pre-1.81 clients (which
  use `application/x-www-form-urlencoded` with `json=...`, escaped
  via `CGI::Util::escape` before Oct 2022 and `URI::Escape`
  after) still account for the majority of inbound traffic --
  versions 1.71, 1.72, 1.78, 1.79, 1.80 all submitted reports
  within the last few days. The form-encoded ingest path is
  load-bearing and not "legacy compat for emergencies" -- treat
  it as a first-class wire format.
- **`legacy/` is reference only**: never modify. Submodules in
  `.gitmodules` use **relative paths and https://** URLs (the original
  `git submodule add` with absolute paths broke `git submodule status`).

## Common operations

```sh
make start                     # hypnotoad on :3000 (dev mode)
make stop / make reload
make dev                       # morbo with auto-reload

make migrate                   # empty schema in data/development.db
make dev-db SRC=csdb.psql      # populate from pg_dump
make fix-plevels               # recompute report.plevel for every row

make test                      # prove -lr t/  (sequential)
make critic                    # perlcritic --severity 5 lib/ script/
make cover                     # Devel::Cover report

make build                     # brew + cpan + vendored htmx
make vendor                    # just fetch public/htmx.min.js

# Docker (prod)
docker compose up              # ./data:/data, port 3000
```

## Plans

`plans/00-overview.md` is the master index. Plans 01–10 cover
skeleton, schema, REST, JSONRPC, ingest, business logic, web
templates, Docker, testing, and the deferred legacy-data migration.
The 49 confirmed decisions live at the top of the master plan in
`/Users/toddr/.claude/plans/using-the-3-repos-typed-raven.md` (private
to the developer's claude data dir, not in the repo).
