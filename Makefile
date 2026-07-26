# CoreSmoke 2.0 — common build / run / test targets.
#
#   make             # show help
#   make build       # install brew + cpan dependencies
#   make test        # run the test suite
#   make dev         # start morbo (dev server with auto-reload)
#   make start       # start hypnotoad (production-like)
#   make import SRC=csdb.psql   # import a legacy pg_dump into data/smoke.db
#
# On macOS, `build` ensures required brew packages are installed before
# invoking cpan to install missing Perl modules from cpanfile.

SHELL       := /bin/bash
PERL        ?= perl
PROVE       ?= prove
HYPNOTOAD   ?= hypnotoad
MORBO       ?= morbo
PERLCRITIC  ?= $(shell $(PERL) -MFile::Basename -e '$$d = dirname($$^X); print -x "$$d/perlcritic" ? "$$d/perlcritic" : "perlcritic"')
COVER       ?= $(shell $(PERL) -MFile::Basename -e '$$d = dirname($$^X); print -x "$$d/cover" ? "$$d/cover" : "cover"')

UNAME_S     := $(shell uname -s)
BREW_PKGS   := xz

APP         := script/smoke
DB_PATH     ?= data/smoke.db
DEV_DB_PATH ?= data/development.db
REPORTS_DIR ?= data/reports
PID_FILE    ?= data/hypnotoad.pid
SRC         ?=

# Vendored client-side libraries.
HTMX_VERSION  ?= 2.0.4
HTMX_FILE     := public/htmx.min.js
HTMX_URL      := https://unpkg.com/htmx.org@$(HTMX_VERSION)/dist/htmx.min.js
VENDORED_JS   := $(HTMX_FILE)

# Every target in this Makefile is for local-dev use (developer machine,
# repo checkout). The Docker image runs script/smoke prefork directly
# from CMD and is unaffected. Tests override MOJO_MODE=test inside
# TestApp.pm before constructing Test::Mojo.
export MOJO_MODE := development

.DEFAULT_GOAL := help

.PHONY: help build deps brew-deps cpan-deps vendor \
        test critic cover \
        dev start stop restart reload \
        migrate fix-plevels create-admin \
        import import-fresh dev-db dev-db-fresh \
        clean clean-cover distclean check-src

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

help:
	@echo "CoreSmoke 2.0 — make targets"
	@echo ""
	@echo "  build         Install brew packages (macOS), cpan modules, vendored JS"
	@echo "  deps          Alias for build"
	@echo "  brew-deps     Install only the macOS brew packages"
	@echo "  cpan-deps     Install only the cpan modules from cpanfile"
	@echo "  vendor        Fetch vendored client-side JS (htmx) into public/"
	@echo ""
	@echo "  dev           Run the app under morbo (auto-reload, dev mode)"
	@echo "  start         Start hypnotoad (production-like, port 3000)"
	@echo "  stop          Stop hypnotoad"
	@echo "  restart       Stop then start hypnotoad"
	@echo "  reload        Hot-reload hypnotoad (re-exec workers)"
	@echo "  migrate       Create / upgrade data/development.db schema"
	@echo "  fix-plevels   Recompute report.plevel for every row"
	@echo ""
	@echo "  test          Run the full test suite (prove -lr t/)"
	@echo "  critic        Run perlcritic at severity 5 over lib/ and script/"
	@echo "  cover         Run tests under Devel::Cover and emit a report"
	@echo ""
	@echo "  import        Import a legacy pg_dump into the prod DB"
	@echo "                  (data/smoke.db):  make import SRC=csdb.psql"
	@echo "  import-fresh  Same as import but wipes data/smoke.db first"
	@echo "  dev-db        Import a legacy pg_dump into the development DB"
	@echo "                  (data/development.db):  make dev-db SRC=csdb.psql"
	@echo "  dev-db-fresh  Same as dev-db but wipes data/development.db first"
	@echo ""
	@echo "  clean         Remove cover_db and other build artifacts"
	@echo "  distclean     clean + remove data/ (DESTROYS the local DB)"

# ---------------------------------------------------------------------------
# Dependency installation
# ---------------------------------------------------------------------------

build: brew-deps cpan-deps vendor
	@echo "[build] complete"

deps: build

# ---------------------------------------------------------------------------
# Vendored client-side assets
# ---------------------------------------------------------------------------
#
# htmx is fetched on demand. The committed repo intentionally has no
# placeholder file, so the FIRST `make dev` / `make start` / `make build`
# downloads the real release into public/. Subsequent runs are no-ops
# because the file already exists. To upgrade, bump HTMX_VERSION at the
# top of this Makefile and `make vendor` (or rm public/htmx.min.js).
#
# The Dockerfile.base builder stage fetches its own copy into the base
# image -- this target is purely for local dev work.
vendor: $(VENDORED_JS)

$(HTMX_FILE):
	@mkdir -p $(@D)
	@echo "[vendor] fetching htmx $(HTMX_VERSION) -> $@"
	@curl -fsSL $(HTMX_URL) -o $@

brew-deps:
ifeq ($(UNAME_S),Darwin)
	@command -v brew >/dev/null 2>&1 \
	    || { echo "[brew-deps] homebrew not found — install from https://brew.sh"; exit 1; }
	@for pkg in $(BREW_PKGS); do \
	    if brew list --formula "$$pkg" >/dev/null 2>&1; then \
	        echo "[brew-deps] $$pkg already installed"; \
	    else \
	        echo "[brew-deps] installing $$pkg"; \
	        brew install "$$pkg" || exit 1; \
	    fi; \
	done
else
	@echo "[brew-deps] non-darwin host ($(UNAME_S)); skipping"
endif

cpan-deps:
	@$(PERL) script/install-deps

# ---------------------------------------------------------------------------
# Run targets
# ---------------------------------------------------------------------------

dev: $(VENDORED_JS)
	exec $(MORBO) $(APP)

start: $(VENDORED_JS)
	$(HYPNOTOAD) $(APP)

stop:
	$(HYPNOTOAD) -s $(APP)

# `hypnotoad -s` returns immediately after sending SIGQUIT, but the
# master can take up to graceful_timeout (30s in prod) to actually exit
# and free port 3000. Wait for the pid file to disappear before
# starting again, or the new daemon will fail to bind.
restart:
	$(HYPNOTOAD) -s $(APP)
	@n=0; while [ -e $(PID_FILE) ] && [ $$n -lt 35 ]; do \
	    [ $$n -eq 0 ] && echo "[restart] waiting for $(PID_FILE) to be removed..."; \
	    sleep 1; n=$$((n+1)); \
	done; \
	if [ -e $(PID_FILE) ]; then \
	    echo "[restart] timeout: $(PID_FILE) still present after 35s"; exit 1; \
	fi
	$(HYPNOTOAD) $(APP)

reload:
	$(HYPNOTOAD) $(APP)

# Create / upgrade the development DB schema in place. Honors
# $SMOKE_DB_PATH if set; otherwise defaults to data/development.db.
# Idempotent: running it on an already-current DB is a no-op.
migrate:
	./script/migrate

# Recompute report.plevel for every row using the current
# Plevel.pm logic. Idempotent and cheap (one UPDATE per row that
# differs). Useful after pulling a Plevel.pm change or noticing weird
# /latest sort order on imported data.
fix-plevels:
	./script/fix-plevels

# Create the first admin user for the web admin UI.
# Usage: make create-admin USER=admin PASS=secret
create-admin:
	@if [ -z "$(USER)" ] || [ -z "$(PASS)" ]; then \
	    echo "usage: make create-admin USER=<username> PASS=<password>"; exit 2; \
	fi
	./script/create-admin --username "$(USER)" --password "$(PASS)"

# ---------------------------------------------------------------------------
# Test, lint, coverage
# ---------------------------------------------------------------------------

test:
	$(PROVE) -lr t/

critic:
	$(PERLCRITIC) --severity 5 lib/ script/

cover:
	$(COVER) -delete
	HARNESS_PERL_SWITCHES='-MDevel::Cover=-silent,1,+ignore,^t/,+ignore,^local/' $(PROVE) -lr t/
	$(COVER)

# ---------------------------------------------------------------------------
# Legacy data import
# ---------------------------------------------------------------------------

check-src:
	@if [ -z "$(SRC)" ]; then \
	    echo "usage: make $(MAKECMDGOALS) SRC=path/to/dump.psql"; exit 2; \
	fi
	@if [ ! -r "$(SRC)" ]; then \
	    echo "cannot read SRC=$(SRC)"; exit 2; \
	fi

import: check-src
	./script/import-from-pgdump --source "$(SRC)" --target "$(DB_PATH)"

import-fresh: check-src
	./script/import-from-pgdump --source "$(SRC)" --target "$(DB_PATH)" --fresh

# Same as `import`/`import-fresh` but writes to the development DB
# (data/development.db) -- the one `make start` and `make dev` open
# while running in development mode. Use these on a fresh checkout
# to seed your dev environment from a legacy pg_dump.
dev-db: check-src
	./script/import-from-pgdump --source "$(SRC)" --target "$(DEV_DB_PATH)"

dev-db-fresh: check-src
	./script/import-from-pgdump --source "$(SRC)" --target "$(DEV_DB_PATH)" --fresh

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean: clean-cover
	@find . -name '*.swp' -delete

clean-cover:
	rm -rf cover_db

distclean: clean
	@echo "[distclean] removing $(DB_PATH)* and $(REPORTS_DIR)/"
	rm -f $(DB_PATH) $(DB_PATH)-wal $(DB_PATH)-shm
	rm -rf $(REPORTS_DIR)
