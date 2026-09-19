#!/usr/bin/env bash
# compile.sh - build the OpenClaude fork and verify the bundled CLI is runnable.
#
# Usage:
#   ./compile.sh                 # install deps, build, smoke-test
#   ./compile.sh --skip-install  # skip `bun install`, just build + smoke
#   ./compile.sh --install-only  # only install deps, don't build
#   ./compile.sh --version       # print version + exit
#   ./compile.sh --help          # this help
#
# Output: dist/cli.mjs (bundled CLI), plus dist artifacts from scripts/build.ts.
#
# Requires: bun >=1.3 (bun install + bun run build), node >=22 (smoke test).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${OPENCLAUDE_LOG_DIR:-/data/ai/orchestrator/logs}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/compile.log"

# ---- Logging -----------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# ---- Args --------------------------------------------------------------------

DO_INSTALL=1
DO_BUILD=1

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-install) DO_INSTALL=0 ;;
    --install-only) DO_BUILD=0 ;;
    --version)
      grep -m1 '"version"' "$REPO_DIR/package.json" \
        | sed -E 's/.*"version": *"([^"]+)".*/\1/'; exit 0 ;;
    -h|--help)
      sed -n '2,13p' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  die "unexpected argument: $1" ;;
  esac
  shift
done

# ---- Sanity ------------------------------------------------------------------

[ -d "$REPO_DIR" ] || die "repo not found: $REPO_DIR"
command -v bun  >/dev/null || die "bun not on PATH (install bun >=1.3)"
command -v node >/dev/null || die "node not on PATH (needed for smoke test)"

VERSION="$(grep -m1 '"version"' "$REPO_DIR/package.json" \
           | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
[ -n "$VERSION" ] || die "could not read version from $REPO_DIR/package.json"

log "OpenClaude v${VERSION}"
log "  repo: $REPO_DIR"

# ---- Install -----------------------------------------------------------------

if [ "$DO_INSTALL" = 1 ]; then
  log ">> bun install --frozen-lockfile"
  ( cd "$REPO_DIR" && bun install --frozen-lockfile ) || die "bun install failed"
else
  log "-> skipping bun install"
fi

# ---- Build -------------------------------------------------------------------

if [ "$DO_BUILD" = 1 ]; then
  log ">> bun run build"
  ( cd "$REPO_DIR" && bun run build ) || die "bun run build failed"

  log ">> smoke: node dist/cli.mjs --version"
  ( cd "$REPO_DIR" && node dist/cli.mjs --version ) 2>&1 \
    | tail -1 | tee -a "$LOG_FILE" \
    || die "smoke check failed - bundled CLI does not start"

  [ -f "$REPO_DIR/dist/cli.mjs" ] || die "expected bundle missing: dist/cli.mjs"
  log "ok built v${VERSION} -> dist/cli.mjs"
else
  log "-> --install-only, deps installed"
fi
