#!/bin/sh
# Run the clean-environment Redis+modules build smoke test used by the
# TimeSeries Dockerfile matrix workflow.

set -eu

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

REDIS_PORT="${REDIS_PORT:-6379}"
DEPLOY_PREFIX="${DEPLOY_PREFIX:-/opt/redis-deploy}"
TARBALL="${TARBALL:-/tmp/redis-HEAD.tar.gz}"
TARBALL_CHECK="${TARBALL_CHECK:-/tmp/redis-tarball-check}"
TAR_BIN="${TAR:-$(command -v gtar 2>/dev/null || command -v tar 2>/dev/null || true)}"
RUN_LOG="${RUN_LOG:-/tmp/redis-skill-run.log}"
DEPLOY_RUN_LOG="${DEPLOY_RUN_LOG:-/tmp/redis-skill-deploy-run.log}"
LTO_PASS_MARKER="${LTO_PASS_MARKER:-/tmp/redis-skill-lto-build-pass}"

server_pid=""
deployed_pid=""
phase="${1:-all}"

log() {
  printf '\n==> %s\n' "$*"
}

run() {
  printf '\n\033[1m============================================================\033[0m\n'
  printf '\033[1mCOMMAND: %s\033[0m\n' "$*"
  printf '\033[1m============================================================\033[0m\n'
  "$@"
}

tail_file() {
  file="$1"
  [ -f "$file" ] || return 0
  echo "--- tail: $file ---"
  tail -80 "$file" || true
}

shutdown_server() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    src/redis-cli -p "$REDIS_PORT" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}

shutdown_deployed_server() {
  if [ -n "$deployed_pid" ] && kill -0 "$deployed_pid" 2>/dev/null; then
    "$DEPLOY_PREFIX/bin/redis-cli" -p "$REDIS_PORT" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    wait "$deployed_pid" 2>/dev/null || true
  fi
  deployed_pid=""
}

on_error() {
  rc=$?
  tail_file "$RUN_LOG"
  tail_file "$DEPLOY_RUN_LOG"
  exit "$rc"
}

trap 'shutdown_server; shutdown_deployed_server' 0

wait_for_redis() {
  cli="$1"
  log_file="$2"
  tries=0
  while [ "$tries" -lt 120 ]; do
    if "$cli" -p "$REDIS_PORT" PING >/dev/null 2>&1; then
      return 0
    fi
    if [ -f "$log_file" ] && grep -qiE 'failed|fatal|abort|Address already in use' "$log_file"; then
      tail_file "$log_file"
      return 1
    fi
    sleep 1
    tries=$((tries + 1))
  done
  tail_file "$log_file"
  echo "ERROR: redis-server did not become ready on port $REDIS_PORT" >&2
  return 1
}

assert_module_loaded() {
  cli="$1"
  needle="$2"
  if ! "$cli" -p "$REDIS_PORT" MODULE LIST | grep -qi "$needle"; then
    "$cli" -p "$REDIS_PORT" MODULE LIST || true
    echo "ERROR: module '$needle' was not loaded" >&2
    return 1
  fi
}

verify_modules() {
  cli="$1"

  run "$cli" -p "$REDIS_PORT" PING
  assert_module_loaded "$cli" timeseries
  assert_module_loaded "$cli" bf
  assert_module_loaded "$cli" ReJSON
  assert_module_loaded "$cli" search

  run "$cli" -p "$REDIS_PORT" TS.CREATE ts
  run "$cli" -p "$REDIS_PORT" TS.ADD ts '*' 1
  run "$cli" -p "$REDIS_PORT" TS.INFO ts

  run "$cli" -p "$REDIS_PORT" BF.ADD bf x
  run "$cli" -p "$REDIS_PORT" BF.EXISTS bf x

  run "$cli" -p "$REDIS_PORT" JSON.SET j '$' '{"a":1}'
  run "$cli" -p "$REDIS_PORT" JSON.GET j

  run "$cli" -p "$REDIS_PORT" FT.CREATE idx ON HASH SCHEMA t TEXT
  run "$cli" -p "$REDIS_PORT" FT._LIST
}

log "Context"
echo "repo: $ROOT"
echo "dockerfile: ${CI_DOCKERFILE:-unknown}"
echo "image: ${CI_IMAGE:-unknown}"
echo "platform: ${CI_PLATFORM:-unknown}"
echo "arch: ${CI_ARCH:-unknown}"
echo "osnick: ${OSNICK:-auto}"
echo "redis port: $REDIS_PORT"
git --no-pager log -1 --oneline

phase_modules_update() {
  run make modules-update all
}

phase_bootstrap() {
  run make bootstrap all
}

phase_build() {
  run make build all -j8 LTO=0
}

phase_lto_build() {
  log "Non-gating LTO build check"
  rm -f "$LTO_PASS_MARKER"
  run make clean
  if run make build all -j8 LTO=1; then
    : > "$LTO_PASS_MARKER"
    log "LTO build (make clean && make build LTO=1): PASS"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "LTO build (make clean && make build LTO=1): PASS" >> "$GITHUB_STEP_SUMMARY"
    fi
    return 0
  fi

  echo "WARNING: LTO build FAILED (non-gating; regular build passed)" >&2
  echo "::warning title=LTO build failed::Non-gating make clean && make build LTO=1 failed; continuing with LTO=0 restore"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "WARNING: LTO build FAILED (non-gating; regular build passed)" >> "$GITHUB_STEP_SUMMARY"
  fi
  echo "==> Restoring regular LTO=0 build artifacts for later smoke tests" >&2
  run make build all -j8 LTO=0
  return 0
}

phase_source_smoke() {
  log "Starting source-tree Redis with bundled modules"
  ARGS="--port $REDIS_PORT --appendonly no" nohup make run >"$RUN_LOG" 2>&1 &
  server_pid=$!
  wait_for_redis src/redis-cli "$RUN_LOG"
  verify_modules src/redis-cli
  shutdown_server
}

phase_lto_source_smoke() {
  if [ ! -f "$LTO_PASS_MARKER" ]; then
    log "Skipping LTO=1 source smoke because LTO=1 build did not pass"
    return 0
  fi
  phase_source_smoke
}

phase_package_deploy_smoke() {
  run make tarball TAG=HEAD
  run rm -rf "$TARBALL_CHECK"
  run mkdir -p "$TARBALL_CHECK"
  run "$TAR_BIN" -xf "$TARBALL" -C "$TARBALL_CHECK"

  EXTRACTED="$TARBALL_CHECK/redis-HEAD"
  for line in \
    "loadmodule ./modules/redisbloom/redisbloom.so" \
    "loadmodule ./modules/redisearch/redisearch.so" \
    "loadmodule ./modules/redisjson/rejson.so" \
    "loadmodule ./modules/redistimeseries/redistimeseries.so"
  do
    if ! grep -qxF "$line" "$EXTRACTED/redis.conf"; then
      echo "ERROR: missing tarball redis.conf line: $line" >&2
      exit 1
    fi
  done

  run mkdir -p "$DEPLOY_PREFIX"
  (
    cd "$EXTRACTED"
    run make deploy PREFIX="$DEPLOY_PREFIX" LTO=0
  )

  for so in redisbloom.so redisearch.so rejson.so redistimeseries.so; do
    line="loadmodule $DEPLOY_PREFIX/lib/redis/modules/$so"
    if ! grep -qxF "$line" "$EXTRACTED/redis.conf"; then
      echo "ERROR: deployed redis.conf missing absolute line: $line" >&2
      exit 1
    fi
  done

  run cp "$EXTRACTED/redis.conf" "$DEPLOY_PREFIX/redis.conf"

  log "Starting deployed Redis"
  nohup "$DEPLOY_PREFIX/bin/redis-server" "$DEPLOY_PREFIX/redis.conf" \
    --port "$REDIS_PORT" --appendonly no >"$DEPLOY_RUN_LOG" 2>&1 &
  deployed_pid=$!
  wait_for_redis "$DEPLOY_PREFIX/bin/redis-cli" "$DEPLOY_RUN_LOG"
  verify_modules "$DEPLOY_PREFIX/bin/redis-cli"

  for module_name in bf search ReJSON timeseries; do
    if ! grep -q "Module '$module_name' loaded" "$DEPLOY_RUN_LOG"; then
      tail_file "$DEPLOY_RUN_LOG"
      echo "ERROR: deployed server log did not show module '$module_name' loading" >&2
      exit 1
    fi
  done

  shutdown_deployed_server
}

case "$phase" in
  modules-update) phase_modules_update ;;
  bootstrap) phase_bootstrap ;;
  build) phase_build ;;
  lto-build) phase_lto_build ;;
  source-smoke) phase_source_smoke ;;
  lto-source-smoke) phase_lto_source_smoke ;;
  package-deploy-smoke) phase_package_deploy_smoke ;;
  all)
    phase_modules_update
    phase_bootstrap
    phase_build
    phase_source_smoke
    phase_lto_build
    phase_lto_source_smoke
    phase_package_deploy_smoke
    log "PASS: Redis build skill completed with make build LTO=0"
    ;;
  *)
    echo "Usage: $0 [modules-update|bootstrap|build|lto-build|source-smoke|lto-source-smoke|package-deploy-smoke|all]" >&2
    exit 2
    ;;
esac
