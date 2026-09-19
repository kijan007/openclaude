#!/usr/bin/env bash
# openclaude-build.sh - compile, distribute, or both for the OpenClaude fork.
#
# Usage:
#   ./openclaude-build.sh              # compile + distribute (all hosts)
#   ./openclaude-build.sh --compile    # build only (install + build + smoke)
#   ./openclaude-build.sh --distribute # ship existing tarball to all hosts
#   ./openclaude-build.sh --skip-install   # compile mode, skip bun install
#   ./openclaude-build.sh host1 host2      # distribute to a subset of hosts
#   ./openclaude-build.sh --version        # print version + exit
#   ./openclaude-build.sh --help           # this help
#
# Hosts (default): aimax hx faex boexli ociweb krypto private
# Requires on build host:  bun >=1.3, node >=22, npm (for npm pack)
# Requires on each target: node >=22, npm (for `npm install -g <tgz>`)

set -euo pipefail

# ---- Config ------------------------------------------------------------------
REPO_DIR="${OPENCLAUDE_REPO_DIR:-/data/Github/openclaude}"
STAGE_DIR="${OPENCLAUDE_STAGE_DIR:-/tmp/openclaude-dist}"
ALL_HOSTS=(aimax hx faex boexli ociweb krypto private)
SSH_USER="${OPENCLAUDE_SSH_USER:-}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
host_target() { [ -n "$SSH_USER" ] && echo "$SSH_USER@$1" || echo "$1"; }
REMOTE_TMP="${OPENCLAUDE_REMOTE_TMP:-/tmp/openclaude-stage}"
LOG_DIR="${OPENCLAUDE_LOG_DIR:-/data/ai/orchestrator/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/openclaude-build.log"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die()  { log "ERROR: $*"; exit 1; }

# ---- Version -----------------------------------------------------------------
get_version() {
  grep -m1 '"version"' "$REPO_DIR/package.json" \
    | sed -E 's/.*"version": *"([^"]+)".*/\1/'
}

# ---- Package basename for tarball (handles scoped names) ---------------------
get_pkgname() {
  # @scope/name -> scope-name  (matches what `npm pack` emits for the tarball)
  grep -m1 '"name"' "$REPO_DIR/package.json" \
    | sed -E 's/.*"name": *"([^"]+)".*/\1/' \
    | sed -e 's/^@//' -e 's|/|-|'
}

# ---- Args --------------------------------------------------------------------
DO_COMPILE=1
DO_DISTRIBUTE=0
DO_INSTALL=1
HOSTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --compile)      DO_COMPILE=1; DO_DISTRIBUTE=0 ;;
    --distribute)   DO_COMPILE=0; DO_DISTRIBUTE=1 ;;
    --skip-install) DO_INSTALL=0 ;;
    --version)      get_version; exit 0 ;;
    -h|--help)      sed -n '2,16p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do HOSTS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *)  HOSTS+=("$1") ;;
  esac
  shift
done

[ ${#HOSTS[@]} -eq 0 ] && HOSTS=("${ALL_HOSTS[@]}")

# ---- Sanity ------------------------------------------------------------------
[ -d "$REPO_DIR" ] || die "repo not found: $REPO_DIR"
command -v bun  >/dev/null || die "bun not on PATH (install bun >=1.3)"
command -v node >/dev/null || die "node not on PATH"
command -v npm  >/dev/null || die "npm not on PATH (needed for npm pack)"
command -v ssh  >/dev/null || die "ssh not on PATH (needed for deploy)"

VERSION="$(get_version)"
[ -n "$VERSION" ] || die "could not read version from $REPO_DIR/package.json"

PKG_NAME="$(get_pkgname)"
TARBALL_NAME="${PKG_NAME}-${VERSION}.tgz"
TARBALL_PATH="$STAGE_DIR/$TARBALL_NAME"

log "OpenClaude v${VERSION}  (compile=$DO_COMPILE distribute=$DO_DISTRIBUTE)"
log "  hosts: ${HOSTS[*]}"

# ---- Compile -----------------------------------------------------------------
if [ "$DO_COMPILE" = 1 ]; then
  if [ "$DO_INSTALL" = 1 ]; then
    log ">> bun install --frozen-lockfile"
    ( cd "$REPO_DIR" && bun install --frozen-lockfile ) || die "bun install failed"
  else
    log "-> skipping bun install"
  fi

  log ">> bun run build"
  ( cd "$REPO_DIR" && bun run build ) || die "bun run build failed"

  log ">> smoke: node dist/cli.mjs --version"
  ( cd "$REPO_DIR" && node dist/cli.mjs --version ) 2>&1 \
    | tail -1 | tee -a "$LOG_FILE" \
    || die "smoke check failed - bundled CLI does not start"

  log ">> npm pack"
  mkdir -p "$STAGE_DIR"
  rm -f "$STAGE_DIR"/${PKG_NAME}-*.tgz
  ( cd "$REPO_DIR" && npm pack --pack-destination "$STAGE_DIR" ) >>"$LOG_FILE" 2>&1 \
    || die "npm pack failed"

  [ -f "$TARBALL_PATH" ] || die "expected tarball missing: $TARBALL_PATH"
  log "ok built $(du -h "$TARBALL_PATH" | cut -f1)  $TARBALL_PATH"
else
  [ -f "$TARBALL_PATH" ] || die "--distribute but no tarball at $TARBALL_PATH"
  log "-> reusing tarball $TARBALL_PATH"
fi

# ---- Distribute --------------------------------------------------------------
deploy_one() {
  local host="$1"
  log "--- $host"
  local target; target="$(host_target "$host")"

  if ! ssh "${SSH_OPTS[@]}" "$target" true 2>>"$LOG_FILE"; then
    log "  x ssh unreachable, skipping"; return 1
  fi

  ssh "${SSH_OPTS[@]}" "$target" "mkdir -p '$REMOTE_TMP'" \
    || { log "  x cannot mkdir $REMOTE_TMP on $host"; return 1; }

  scp "${SSH_OPTS[@]}" "$TARBALL_PATH" "$target:$REMOTE_TMP/$TARBALL_NAME" \
    || { log "  x scp failed on $host"; return 1; }

  ssh "${SSH_OPTS[@]}" "$target" bash -s -- "$VERSION" "$REMOTE_TMP/$TARBALL_NAME" \
    <<'REMOTE' || { log "  x install failed on $host"; return 1; }
    set -euo pipefail
    version="$1"; tgz="$2"
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "${node_major:-0}" -lt 22 ]; then
      echo "ERROR: node >=22 required, found $(node -v 2>/dev/null || echo 'none')"
      exit 1
    fi
    echo ">> npm install -g $tgz"
    npm install -g "$tgz" >/tmp/openclaude-install.log 2>&1 \
      || { tail -20 /tmp/openclaude-install.log; exit 1; }
    echo ">> kijanclaude --version"
    kijanclaude --version || true
    rm -f "$tgz"
    echo "OK v$version"
REMOTE

  log "  ok $host -> openclaude v${VERSION}"
}

if [ "$DO_DISTRIBUTE" = 1 ]; then
  failures=()
  for h in "${HOSTS[@]}"; do
    deploy_one "$h" || failures+=("$h")
  done
  echo
  if [ ${#failures[@]} -eq 0 ]; then
    log "ok all ${#HOSTS[@]} host(s) updated to v${VERSION}"
  else
    log "x ${#failures[@]} failed: ${failures[*]}  (others OK)"
    exit 1
  fi
else
  log "--compile only, tarball ready at $TARBALL_PATH"
  log "  (run with --distribute to ship to ${HOSTS[*]})"
fi
