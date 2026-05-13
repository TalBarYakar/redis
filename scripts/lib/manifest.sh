#!/usr/bin/env bash
# Shared helpers for scripts/ — manifest reading + module selection.
#
# Source from another script:
#   SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/lib/manifest.sh"
#
# Exposes:
#   manifest_modules                           - sorted module names from modules.yaml
#   manifest_field <name> <field>              - one field for one module ("" if missing)
#   cloned_modules                             - names with .prepared or .git under modules/<n>/src
#   resolve_modules <requested> <cloned> [allow_extras]
#         Mirrors the case-statement repeated in build/bootstrap/run/test recipes.
#         <allow_extras> is a space-separated list of synonyms in addition to the
#         standard "" / all / . / '*'  (e.g. "redis none" for build, "none" for run).
#         Echoes the resolved space-separated module list. Exits 1 on errors.
#
# Awk programs mirror modules/manifest.mk's MANIFEST_NAMES_AWK / MANIFEST_FIELD_AWK
# so YAML parsing stays in one shape across Make + shell.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
MODULES_MANIFEST_FILE="${MODULES_MANIFEST_FILE:-$REPO_ROOT/modules.yaml}"

manifest_modules() {
  awk '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      if (length() > 0) print
    }
  ' "$MODULES_MANIFEST_FILE" 2>/dev/null | sort -u
}

manifest_field() {
  local want="$1" field="$2"
  awk -v want="$want" -v field="$field" '
    BEGIN { cur = "" }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      cur = line
      next
    }
    cur == want {
      pat = "^[[:space:]]+" field ":"
      if ($0 ~ pat) {
        v = $0
        sub("^[[:space:]]+" field ":[[:space:]]*", "", v)
        sub(/[[:space:]]+$/, "", v)
        print v
        exit
      }
    }
  ' "$MODULES_MANIFEST_FILE" 2>/dev/null
}

cloned_modules() {
  local cloned=""
  local name
  for name in $(manifest_modules); do
    if [ -f "$REPO_ROOT/modules/$name/src/.prepared" ] || [ -e "$REPO_ROOT/modules/$name/src/.git" ]; then
      cloned="$cloned $name"
    fi
  done
  echo "$cloned" | xargs
}

# Echo the resolved module list given user input + the set of cloned modules.
# Special tokens:
#   "" | all | . | '*'   -> the full <cloned> list
# Extras (passed in $3, space-separated) map to "" (empty selection); typical:
#   "redis none" for build, "none" for run.
# Errors to stderr and `exit 1` on unknown / mixed tokens.
resolve_modules() {
  local requested="$1" cloned="$2" extras="${3:-}"
  case "$requested" in
    ""|all|.|'*') echo "$cloned"; return ;;
  esac
  local r c found
  for r in $requested; do
    case "$r" in
      all|.|'*')
        echo "ERROR: '$r' cannot be mixed with explicit module names" >&2
        exit 1 ;;
    esac
    if [ -n "$extras" ]; then
      for e in $extras; do
        if [ "$r" = "$e" ]; then
          for r2 in $requested; do
            for e2 in $extras; do [ "$r2" = "$e2" ] && continue 2; done
            echo "ERROR: '$r' cannot be mixed with explicit module names" >&2
            exit 1
          done
          echo ""
          return
        fi
      done
    fi
    found=""
    for c in $cloned; do [ "$c" = "$r" ] && found=1; done
    if [ -z "$found" ]; then
      echo "ERROR: module '$r' is not available under modules/$r/src" >&2
      echo "  (expect .git or .prepared in modules/$r/src)" >&2
      echo "Modules found: $cloned" >&2
      echo "Hint: run 'make modules-update $r' or clone into modules/$r/src" >&2
      exit 1
    fi
  done
  echo "$requested"
}
