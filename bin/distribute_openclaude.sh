#!/usr/bin/env bash
# distribute_openclaude.sh — build the OpenClaude fork and ship the
# pre-built tarball to a list of hosts over SSH.
#
# Usage:
#   ./distribute_openclaude.sh                       # build + ship to all hosts
#   ./distribute_openclaude.sh --build-only          # build & pack, don't deploy
#   ./distribute_openclaude.sh --skip-build          # ship the existing tarball
#   ./distribute_openclaude.sh host1 host2 ...       # deploy to a subset
#   ./distribute_openclaude.sh --version             # print version + exit
#
# Hosts (default set): aimax hx faex boexli ociweb krypto private
# Access: ssh <hostname>  (uses current user, ~/.ssh/config honoured)
#
# Requires on build host:  bun ≥1.3 (for bun install + bun run build)
# Requires on each target: node ≥22, npm (for `npm install -g <tgz>`)

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────

REPO_DIR="${OPENCLAUDE_REPO_DIR:-/data/Github/openclaude}"
STAGE_DIR="${OPENCLAUDE_STAGE_DIR:-/tmp/openclaude-dist}"
ALL_HOSTS=(aimax hx faex boexli ociweb krypto private)
# User comes from ~/.ssh/config (Host <name> blocks). Override per-host via
# OPENCLAUDE_SSH_USER or, in the rare case of a single different host, with
# ssh's user@host syntax on the command line.
SSH_USER="${OPENCLAUDE_SSH_USER:-}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# Build "user@host" only when SSH_USER is set; otherwise let ssh pick the
# user from ~/.ssh/config (which is what we want here).
host_target() { [ -n "$SSH_USER" ] && echo "$SSH_USER@$1" || echo "$1"; }
REMOTE_TMP="${OPENCLAUDE_REMOTE_TMP:-/tmp/openclaude-stage}"
LOG_DIR="${OPENCLAUDE_LOG_DIR:-/data/ai/orchestrator/logs}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/distribute_openclaude.log"

# ── Logging ──────────────────────────────────────────────────────────────────

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" ; }
die()  { log "ERROR: $*"; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────────

DO_BUILD=1
DO_DEPLOY=1
HOSTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --build-only)  DO_DEPLOY=0 ;;
    --skip-build)  DO_BUILD=0 ;;
    --version)     grep -m1 '"version"' "$REPO_DIR/package.json" | sed -E 's/.*"version": *"([^"]+)".*/\1/'; exit 0 ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do HOSTS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *)  HOSTS+=("$1") ;;
  esac
  shift
done

[ ${#HOSTS[@]} -eq 0 ] && HOSTS=("${ALL_HOSTS[@]}")

# ── Sanity ───────────────────────────────────────────────────────────────────

[ -d "$REPO_DIR" ] || die "repo not found: $REPO_DIR"
command -v bun   >/dev/null || die "bun not on PATH (install bun ≥1.3)"
command -v ssh   >/dev/null || die "ssh not on PATH"
command -v npm   >/dev/null || die "npm not on PATH (needed for the tarball install)"

VERSION="$(grep -m1 '"version"' "$REPO_DIR/package.json" \
          | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
[ -n "$VERSION" ] || die "could not read version from $REPO_DIR/package.json"

TARBALL_NAME="openclaude-${VERSION}.tgz"
TARBALL_PATH="$STAGE_DIR/$TARBALL_NAME"

log "OpenClaude v${VERSION}"
log "  repo:      $REPO_DIR"
log "  stage:     $STAGE_DIR"
log "  tarball:   $TARBALL_PATH"
log "  hosts:     ${HOSTS[*]}"

# ── Build ────────────────────────────────────────────────────────────────────

if [ "$DO_BUILD" = 1 ]; then
  log "▶ bun install --frozen-lockfile"
  ( cd "$REPO_DIR" && bun install --frozen-lockfile ) || die "bun install failed"

  log "▶ bun run build"
  ( cd "$REPO_DIR" && bun run build ) || die "bun run build failed"

  log "▶ smoke: node dist/cli.mjs --version"
  ( cd "$REPO_DIR" && node dist/cli.mjs --version ) >>"$LOG_FILE" 2>&1 \
    || die "smoke check failed — bundled CLI does not start"

  mkdir -p "$STAGE_DIR"
  # clear stale tarballs so we always ship the one we just built
  rm -f "$STAGE_DIR"/openclaude-*.tgz
  log "▶ npm pack"
  ( cd "$REPO_DIR" && npm pack --pack-destination "$STAGE_DIR" ) >>"$LOG_FILE" 2>&1 \
    || die "npm pack failed"

  [ -f "$TARBALL_PATH" ] || die "expected tarball missing: $TARBALL_PATH"
  log "✓ built $(du -h "$TARBALL_PATH" | cut -f1)  $TARBALL_PATH"
else
  [ -f "$TARBALL_PATH" ] || die "--skip-build but no tarball at $TARBALL_PATH"
  log "↷ skipping build, reusing $TARBALL_PATH"
fi

# ── Deploy ───────────────────────────────────────────────────────────────────

deploy_one() {
  local host="$1"
  log "──▶ $host"

  local target
  target="$(host_target "$host")"

  if ! ssh "${SSH_OPTS[@]}" "$target" true 2>>"$LOG_FILE"; then
    log "  ✗ ssh unreachable, skipping"
    return 1
  fi

  # 1. ship the tarball
  ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$REMOTE_TMP'" \
    || { log "  ✗ cannot mkdir $REMOTE_TMP on $host"; return 1; }

  scp "${SSH_OPTS[@]}" "$TARBALL_PATH" \
      "$target:$REMOTE_TMP/$TARBALL_NAME" \
    || { log "  ✗ scp failed on $host"; return 1; }

  # 2. install globally + smoke
  ssh "${SSH_OPTS[@]}" "$target" bash -s -- "$VERSION" "$REMOTE_TMP/$TARBALL_NAME" \
    <<'REMOTE' || { log "  ✗ install failed on $host"; return 1; }
    set -euo pipefail
    version="$1"; tgz="$2"

    # node ≥22 gate (matches package.json engines)
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "${node_major:-0}" -lt 22 ]; then
      echo "ERROR: node ≥22 required, found $(node -v 2>/dev/null || echo 'none')"
      exit 1
    fi

    echo "▶ npm install -g $tgz"
    npm install -g "$tgz" >/tmp/openclaude-install.log 2>&1 \
      || { tail -20 /tmp/openclaude-install.log; exit 1; }

    echo "▶ openclaude --version"
    openclaude --version || true

    rm -f "$tgz"
    echo "OK v$version"
REMOTE

  log "  ✓ $host → openclaude v${VERSION}"
}

if [ "$DO_DEPLOY" = 1 ]; then
  failures=()
  for h in "${HOSTS[@]}"; do
    deploy_one "$h" || failures+=("$h")
  done
  echo
  if [ ${#failures[@]} -eq 0 ]; then
    log "✓ all ${#HOSTS[@]} host(s) updated to v${VERSION}"
  else
    log "✗ ${#failures[@]} failed: ${failures[*]}  (others OK)"
    exit 1
  fi
else
  log "↷ --build-only, tarball ready at $TARBALL_PATH"
fi
