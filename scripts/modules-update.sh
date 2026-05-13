#!/usr/bin/env bash
# modules-update.sh — clone or refresh modules per modules.yaml.
#
# Usage:  scripts/modules-update.sh [<name> ...|all|.|'*']
#         (no args = all modules in modules.yaml)
#
# Env: MODULES_UPDATE_SHALLOW=1  clone with --depth 1
#      MAKE                      make binary (defaults to `make`)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/manifest.sh"
cd "$REPO_ROOT"

MAKE_BIN="${MAKE:-make}"

available="$(manifest_modules | xargs)"
requested="$*"
if [ -z "$requested" ]; then
  echo "==> No module specified — defaulting to all ($available)"
  requested="$available"
fi
for r in $requested; do
  case "$r" in all|.|'*') requested="$available"; break ;; esac
done

depth_args=""
if [ "${MODULES_UPDATE_SHALLOW:-}" = "1" ]; then
  echo "==> MODULES_UPDATE_SHALLOW=1: cloning with --depth 1"
  depth_args="--depth 1"
fi

for name in $requested; do
  case " $available " in *" $name "*) ;; *)
    echo "ERROR: unknown module '$name' (not listed in modules.yaml)"
    echo "Available modules: $available"
    exit 1 ;;
  esac

  repo="$(manifest_field "$name" repo)"
  version="$(manifest_field "$name" version)"
  commit="$(manifest_field "$name" commit)"
  dest="modules/$name/src"

  if [ -z "$repo" ]; then
    echo "ERROR: 'repo' is not set for '$name' in modules.yaml"; exit 1
  fi
  if [ -z "$commit" ] && [ -z "$version" ]; then
    echo "ERROR: need either 'commit' or 'version' for '$name' in modules.yaml"; exit 1
  fi

  if [ ! -d "$dest/.git" ]; then
    rm -rf "$dest"
    if [ -n "$commit" ]; then
      echo "==> Cloning $name @ commit $commit from $repo into $dest"
      git init -q "$dest"
      git -C "$dest" remote add origin "$repo"
      if [ -n "$depth_args" ]; then
        git -C "$dest" fetch $depth_args origin "$commit" 2>/dev/null \
          || { echo "    (shallow SHA fetch not supported by server, doing full fetch)"; \
               git -C "$dest" fetch origin; }
      else
        git -C "$dest" fetch origin
      fi
      git -C "$dest" checkout -q --detach "$commit"
      git -C "$dest" submodule update --init --recursive $depth_args
    else
      echo "==> Cloning $name $version from $repo into $dest"
      git clone --recursive $depth_args --branch "$version" "$repo" "$dest"
    fi
  else
    if [ -n "$commit" ]; then
      current="$(git -C "$dest" rev-parse HEAD)"
      if [ "$current" = "$commit" ] || [ "${current#$commit}" != "$current" ]; then
        echo "==> $name already at commit $commit"
      else
        echo "==> Moving $name to commit $commit"
        if [ -n "$depth_args" ]; then
          git -C "$dest" fetch $depth_args origin "$commit" 2>/dev/null \
            || { echo "    (shallow SHA fetch not supported by server, doing full fetch)"; \
                 git -C "$dest" fetch origin; }
        else
          git -C "$dest" fetch origin "$commit" 2>/dev/null \
            || git -C "$dest" fetch origin
        fi
        git -C "$dest" checkout -f --detach "$commit"
      fi
    else
      echo "==> Ensuring $name is at $version"
      git -C "$dest" fetch $depth_args origin "$version" 2>/dev/null \
        || git -C "$dest" fetch $depth_args origin "refs/tags/$version:refs/tags/$version" 2>/dev/null \
        || git -C "$dest" fetch origin
      git -C "$dest" checkout -f "$version" 2>/dev/null \
        || git -C "$dest" reset --hard FETCH_HEAD
    fi
    echo "==> Re-syncing submodules for $name"
    git -C "$dest" submodule sync --recursive
    git -C "$dest" submodule update --init --recursive $depth_args
  fi
  touch "$dest/.prepared"
done

echo
echo "==> Refreshing redis-gen.conf via sync-redis-conf"
"$MAKE_BIN" --no-print-directory sync-redis-conf MODULES="$requested"

echo
echo "==> Modules updated: $requested"
echo "    Next: run 'make bootstrap [<name> ...]' to install per-module build/test deps."
