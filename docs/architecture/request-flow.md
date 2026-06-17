# Request flow

How an HTTP request reaches application logic and returns a response.

## Startup

`CoreSmoke::App` (`lib/CoreSmoke/App.pm`) is the Mojolicious
application class. `startup()` runs once per worker and:

1. Loads per-mode config from `etc/coresmoke.$mode.conf`.
2. Instantiates shared model objects (`Model::DB`, `Model::Reports`,
   `Model::ReportFiles`, `Model::Ingest`, `Model::Auth`) and stores
   them as application attributes.
3. Registers helpers (see below).
4. Sets the controller namespace to `CoreSmoke::Controller`.
5. Wires up a `before_dispatch` hook that generates a per-request
   CSP nonce and injects security headers.
6. Defines all routes (see "Route map").

## Route map

Routes live in `startup()` and group into five blocks:

| Block      | Prefix       | Controller      | Purpose                        |
|------------|--------------|-----------------|--------------------------------|
| Health     | `/healthz`, `/readyz` | System  | K8s probes                     |
| System     | `/system/*`  | System          | Ping, version, status, methods |
| REST API   | `/api/*`     | Api, Ingest     | JSON endpoints                 |
| JSONRPC    | `POST /api`, `POST /system` | JsonRpc | JSON-RPC 2.0 dispatch |
| Web        | `/`, `/latest`, `/search`, ... | Web | HTML pages (HTMX-enabled) |
| Admin      | `/admin/*`   | Admin (session-gated) | Token & user management |

REST API and JSONRPC expose the same data through the same model
methods. `CoreSmoke::JsonRpc::Methods` is the single registry of
method closures; both REST controllers and the JSONRPC dispatcher call
into it so the two protocols cannot drift.

### Ingest routes

Three URLs reach the same `Ingest#post_report` handler:

- `POST /api/report` -- modern Test::Smoke >= 1.81_01.
- `POST /api/old_format_reports` -- explicit legacy alias.
- `POST /report` -- pre-1.81 default (was a Fastly redirect target).

All three accept both `application/json` and
`application/x-www-form-urlencoded` wire formats, dispatching on the
request's Content-Type header.

## Request lifecycle

```
Client
  |
  v
Mojolicious router  -->  before_dispatch hook (CSP nonce, security headers)
  |
  v
Controller action   -->  extracts params from stash/query/body
  |
  v
Model method        -->  SQL via Mojo::SQLite  /  disk I/O via ReportFiles
  |
  v
Controller          -->  $c->render(json => ...) or $c->render(template => ...)
  |
  v
Response
```

### HTMX requests

Web controller actions detect HTMX via the `HX-Request` header.  A
single action renders different templates depending on request type:

- **Full page** (no HTMX): top-level template (e.g. `web/search`).
- **Form change** (HTMX, `HX-Trigger` matches the form id): region
  template that replaces the form + results together
  (e.g. `web/_search_region`).
- **Infinite scroll** (HTMX, no form trigger): rows-only fragment
  (e.g. `web/_reports_rows`).

OOB (out-of-band) swap targets update secondary elements (e.g. a
pagination summary header) from the same response, gated by a stash
flag so they appear only on HTMX responses.

## JSONRPC dispatch

`Controller::JsonRpc::dispatch()` parses the request body, detects
single vs. batch, and dispatches:

1. Parse JSON body. Non-JSON -> JSONRPC parse error (-32700).
2. Array body -> batch mode (cap at 100 elements).
3. Each request: look up `method` in `JsonRpc::Methods::%METHODS`.
4. Missing method -> method-not-found error (-32601).
5. Call the method closure with `($c, $params)`.
6. Wrap the return value in a `{ jsonrpc => '2.0', id => ...,
   result => ... }` envelope.
7. Application-level errors (report not found, validation failures)
   appear inside `result`, not in the JSONRPC `error` field.

Transport-level HTTP status is always 200 for JSONRPC; error semantics
are in the response body per the JSON-RPC 2.0 spec.

## Security headers

The `before_dispatch` hook injects:

- **CSP**: `default-src 'self'; script-src 'self' 'nonce-<random>';
  style-src 'self' 'unsafe-inline'`.  Every inline `<script>` must
  carry the nonce attribute.  Inline event handlers (`onclick` etc.)
  are blocked.
- **X-Content-Type-Options**: `nosniff`.
- **X-Frame-Options**: `DENY`.
- **Referrer-Policy**: `strict-origin-when-cross-origin`.

## Helpers

`App.pm` registers helpers that templates and controllers use:

| Helper          | Returns              | Purpose                              |
|-----------------|----------------------|--------------------------------------|
| `sqlite`        | Mojo::SQLite handle  | DB access                            |
| `report_files`  | Model::ReportFiles   | On-disk compressed file access       |
| `reports`       | Model::Reports       | Report queries (latest, search, etc.)|
| `ingest`        | Model::Ingest        | Report ingestion                     |
| `auth`          | Model::Auth          | Admin user + API token management    |
| `url_escape`    | escaped string       | Mojo::Util::url_escape wrapper       |
| `selected_if`   | `'selected'` or `''` | For `<option>` markup                |
| `duration_hms`  | `"1h 5m 12s"`       | Human-readable duration              |
| `asset_url`     | `/path?v=<mtime>`   | Cache-busting static asset URLs      |
| `badge`         | Mojo::ByteStream    | Design-system badge component        |
| `status_pill`   | Mojo::ByteStream    | Colored status indicator             |
| `nav_link`      | Mojo::ByteStream    | Topbar navigation link               |
| `btn_link`      | Mojo::ByteStream    | Button-styled link                   |
| `commify`       | `"1,234"`           | Thousands-separator formatting       |
| `heatmap_ratio` | 0--80               | Log-scale ratio for matrix heatmap   |
