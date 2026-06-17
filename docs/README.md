# CoreSmokeDB docs

Current-state knowledge base. For terse rules + gotchas see
`/CLAUDE.md` at the repo root; for forward-looking design see
`plans/`.

## Index

- `architecture/`
  - [`request-flow.md`](architecture/request-flow.md) &mdash; HTTP
    lifecycle, route map, HTMX dispatch, JSONRPC, security headers.
  - [`schema.md`](architecture/schema.md) &mdash; all tables, columns,
    constraints, indexes, entity relationships, on-disk file layout.
  - [`ingest-pipeline.md`](architecture/ingest-pipeline.md) &mdash;
    wire formats, normalization, plevel, dedup, file storage.
- `conventions/`
  - [`design-system.md`](conventions/design-system.md) &mdash; UI
    components, tokens, helpers/partials, dark mode, HTMX recipes.
- `design-system/`
  - `metacpan-design-system.html` &mdash; the visual reference. Open
    in a browser. Single source of truth for class names and tokens.
- `features/` &mdash; one `.md` per user-facing feature (search,
  matrix, ingest endpoints, web pages). (Skeleton, growing.)
- `operations/` &mdash; runbooks, troubleshooting, on-call notes.
  (Skeleton, growing.)

## When to read

Before any non-trivial change touching an area, scan the relevant
subdir. If a doc contradicts the code, trust the code and flag the
drift.

## When to write

Update or create a doc when the change is one of:
- A new user-facing feature (endpoint, page, CLI command, UI).
  Add / update `features/<feature>.md`.
- An architectural change (data flow, module boundary, schema,
  pipeline). Update `architecture/`.
- A new convention or gotcha worth more than a one-liner. Put the
  deep reference in `conventions/`; keep the terse rule in
  `/CLAUDE.md`.

Skip doc updates for pure refactors, cosmetic changes, or one-off bug
fixes whose root cause already lives in the commit message.
