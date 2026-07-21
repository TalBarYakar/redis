#!/bin/sh
# bootstrap.sh — install per-module build/test prerequisites.
#
# Usage:  scripts/bootstrap.sh [<name> ...|all|.|'*']
#
# Top-level entry point is `make bootstrap`. Dispatches to each cloned
# module's `make -C modules/<name>/src bootstrap` (the upstream module
# convention).
# Continues past failures, prints a summary, exits non-zero on any failure.
#
# Env: MAKE                       make binary (defaults to `make`)
#      PIP_BREAK_SYSTEM_PACKAGES   forced to 1

set -eu

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)" || exit 1
. "$SCRIPT_DIR/lib/manifest.sh"
cd "$REPO_ROOT"

MAKE_BIN="${MAKE:-make}"

# check-deps: report which prerequisites are already installed vs missing,
# WITHOUT installing anything. Strip the flag out of the positional args
# (so it isn't mistaken for a module name) and pass it to each module's
# bootstrap via the CHECK_DEPS env var.
CHECK_DEPS=0
_args=""
for _a in "$@"; do
  case "$_a" in
    check-deps|--check-deps|--deps-check) CHECK_DEPS=1 ;;
    *) _args="$_args $_a" ;;
  esac
done
# shellcheck disable=SC2086
set -- $_args
export CHECK_DEPS

# Ensure sudo + python3 exist when running as root inside a slim container,
# matching the legacy Makefile recipe behaviour.
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -eq 0 ] && ! command -v sudo >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo python3
  elif command -v tdnf >/dev/null 2>&1; then
    tdnf install -y sudo python3
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash make git sudo python3
  fi
fi

cloned="$(cloned_modules)"
selected="$(resolve_modules "$*" "$cloned")"

if [ -z "$selected" ]; then
  echo "ERROR: no modules to install deps for (no modules/*/src with .git or .prepared)"
  echo "       run 'make modules-update all' or clone into modules/<name>/src"
  exit 1
fi

if [ "$CHECK_DEPS" = 1 ]; then
  echo "==> Checking deps for: $selected (no installation)"
else
  echo "==> Installing deps for: $selected"
fi
export PIP_BREAK_SYSTEM_PACKAGES=1

# check-deps: modules append "ok|missing <pkg>" records here instead of each
# printing its own list; we print one deduped union across all modules below.
if [ "$CHECK_DEPS" = 1 ]; then
  DEPS_REPORT_FILE="$(mktemp)"
  export DEPS_REPORT_FILE
  trap 'rm -f "$DEPS_REPORT_FILE"' EXIT
fi

failed=""
for name in $selected; do
  echo
  echo "==> [deps] $name"
  src_mk="modules/$name/src/Makefile"
  if [ ! -f "$src_mk" ]; then
    echo "    !! SKIP: $src_mk does not exist"
    echo "       (the upstream clone may be incomplete; try 'make modules-update $name')"
    failed="$failed $name"
    continue
  fi
  # In check-deps mode, never invoke a module whose bootstrap can't honor it —
  # it would install for real. Support is advertised by referencing the shared
  # contract (DEPS_REPORT_FILE) anywhere under .install/ — the name-based
  # modules and redisearch's verify_build_deps.sh all write to it.
  if [ "$CHECK_DEPS" = 1 ] && ! grep -rq DEPS_REPORT_FILE "modules/$name/src/.install" 2>/dev/null; then
    echo "    !! SKIP: $name does not support check-deps (would install for real)"
    continue
  fi
  # Per-module convention: the inner target is still called `bootstrap` —
  # that's defined by each module's own Makefile, not by us.
  if ! grep -qE '^bootstrap[[:space:]]*:' "$src_mk"; then
    echo "    !! SKIP: no 'bootstrap' target in $src_mk"
    echo "       Add one to the upstream Makefile, e.g.:"
    echo "           bootstrap:"
    echo "                   ./sbin/setup"
    echo "           .PHONY: bootstrap"
    echo "       then commit & push to the module's repo."
    failed="$failed $name"
    continue
  fi
  if ! "$MAKE_BIN" -C "modules/$name/src" bootstrap; then
    failed="$failed $name"
  fi
done

echo
if [ -n "$failed" ]; then
  if [ "$CHECK_DEPS" = 1 ]; then
    # In check mode a non-zero module bootstrap means missing deps, not a
    # build failure. Exit non-zero anyway so CI can gate on it.
    echo "==> Deps check: missing prerequisites in:$failed (see lists above)"
    echo "    Run 'make bootstrap$failed' to install them."
  else
    echo "==> Deps install completed with FAILURES for:$failed"
    echo "    Re-run 'make bootstrap$failed' after fixing the issues above."
  fi
  exit 1
fi
if [ "$CHECK_DEPS" = 1 ]; then
  # One deduped union across every checked module. A package's installed state
  # is host-global, so dedup by name is safe (no per-module conflicts).
  if [ ! -s "$DEPS_REPORT_FILE" ]; then
    echo "==> Deps check: no modules reported (none support check-deps)"
    exit 0
  fi
  installed=$(sort -u "$DEPS_REPORT_FILE" | awk '$1=="ok"{print $2}')
  missing=$(sort -u "$DEPS_REPORT_FILE"   | awk '$1=="missing"{print $2}')
  if [ -z "$missing" ];   then n_missing=0; else n_missing=$(printf '%s\n' "$missing"   | wc -l | tr -d ' '); fi
  if [ -z "$installed" ]; then n_ok=0;      else n_ok=$(printf '%s\n' "$installed" | wc -l | tr -d ' '); fi
  total=$((n_ok + n_missing))
  if [ -t 1 ]; then RED="$(printf '\033[1;31m')"; GRN="$(printf '\033[1;32m')"; RST="$(printf '\033[0m')"; else RED=""; GRN=""; RST=""; fi
  echo "==> Dependency check across: $selected — nothing installed"
  if [ "$n_missing" -gt 0 ]; then
    echo "${RED}NOT INSTALLED ($n_missing):${RST}"
    printf '%s\n' "$missing" | while IFS= read -r p; do [ -n "$p" ] && echo "${RED}    $p${RST}"; done
  else
    echo "${GRN}not installed: (none)${RST}"
  fi
  if [ "${VERBOSE:-0}" = 1 ]; then
    echo "${GRN}installed:${RST}"
    printf '%s\n' "$installed" | while IFS= read -r p; do [ -n "$p" ] && echo "${GRN}    $p${RST}"; done
  else
    echo "${GRN}installed: $n_ok/$total (set VERBOSE=1 to list)${RST}"
  fi
  echo "    Run 'make bootstrap' to install anything not installed."
  [ "$n_missing" -eq 0 ] || exit 1
else
  echo "==> Deps install complete for: $selected"
  echo "    Next: 'make build [<name>]' then 'make test [<name>]' or 'make run'."
fi
