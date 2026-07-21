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

# Non-installing modes, passed to each module's bootstrap via env var:
#   check-deps : report which prerequisites are installed vs missing
#   dry-run    : print the install commands that WOULD run
# Note: use the bare tokens (not --dry-run) — make consumes `--`-flags itself.
# Strip the flag out of the positional args so it isn't taken for a module.
CHECK_DEPS=0
DRY_RUN=0
_args=""
for _a in "$@"; do
  case "$_a" in
    check-deps|--check-deps|--deps-check) CHECK_DEPS=1 ;;
    dry-run|--dry-run-deps|DRY-RUN)       DRY_RUN=1 ;;
    *) _args="$_args $_a" ;;
  esac
done
# shellcheck disable=SC2086
set -- $_args
export CHECK_DEPS DRY_RUN

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
elif [ "$DRY_RUN" = 1 ]; then
  echo "==> Dry-run for: $selected (printing install commands, no installation)"
else
  echo "==> Installing deps for: $selected"
fi
export PIP_BREAK_SYSTEM_PACKAGES=1
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
  # In a non-installing mode, never invoke a module whose bootstrap can't
  # honor it — it would install for real, defeating the whole point. Support
  # is advertised by referencing the env var anywhere under .install/.
  if [ "$CHECK_DEPS" = 1 ] && ! grep -rq CHECK_DEPS "modules/$name/src/.install" 2>/dev/null; then
    echo "    !! SKIP: $name does not support check-deps (would install for real)"
    continue
  fi
  if [ "$DRY_RUN" = 1 ] && ! grep -rq DRY_RUN "modules/$name/src/.install" 2>/dev/null; then
    echo "    !! SKIP: $name does not support dry-run (would install for real)"
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
  echo "==> Deps check complete for: $selected (nothing installed)"
  echo "    Run 'make bootstrap' to install anything reported as not installed."
elif [ "$DRY_RUN" = 1 ]; then
  echo "==> Dry-run complete for: $selected (nothing installed)"
  echo "    Run 'make bootstrap' to actually run the commands above."
else
  echo "==> Deps install complete for: $selected"
  echo "    Next: 'make build [<name>]' then 'make test [<name>]' or 'make run'."
fi
