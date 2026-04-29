# External Modules: build, run, and test

This document describes the Makefile additions that manage external Redis
modules as source-pinned dependencies — cloned into each module's own
`modules/<name>/src/` directory, built against this repo's Redis, loaded
into `redis-server` at runtime, and tested from one top-level entry
point.

All commands are invoked at the repo root. On macOS, you must use
`gmake` (GNU Make ≥ 4.x) instead of `make`, because upstream module
build systems rely on features missing from macOS's default Make 3.81.
Everywhere below, `make` means "GNU make"; substitute `gmake` on macOS.

---

## 1. Layout

| Path | Role |
|---|---|
| `modules/<name>/Makefile` | Pin file — declares `MODULE_REPO`, `MODULE_VERSION`, optional `MODULE_COMMIT`, `TARGET_MODULE` |
| `modules/common.mk` | Shared helpers included by each pin file |
| `modules/<name>/src/` | Checkout location — created by `make modules-update` |
| `src/redis-server` | Redis binary — produced by `make build` |

Only modules whose `modules/<name>/Makefile` pins `MODULE_REPO` are
considered "external". In-tree modules (e.g. `vector-sets`) are excluded.

### Pin variables

Each `modules/<name>/Makefile` declares:

```make
SRC_DIR        = src
MODULE_VERSION = v8.7.90          # tag or branch
MODULE_COMMIT  =                  # optional SHA; overrides MODULE_VERSION when non-empty
MODULE_REPO    = https://github.com/redistimeseries/redistimeseries
TARGET_MODULE  = $(SRC_DIR)/bin/$(FULL_VARIANT)/redistimeseries.so

include ../common.mk
```

Precedence when both are set: `MODULE_COMMIT` wins over `MODULE_VERSION`.
Leave `MODULE_COMMIT` empty to track the tag/branch.

---

## 2. Clone / update: `make modules-update`

```bash
make modules-update <name> [<name> ...]
make modules <name> [<name> ...]      # alias — same idempotent behavior
```

A single idempotent command: clones the module into `modules/<name>/src/`
at the pinned ref if it isn't there yet, otherwise moves the existing
clone to the current pin and re-syncs its submodules. Safe to re-run.

Name expansion:

| Argument | Selects |
|---|---|
| `<name>` | One module (e.g. `redistimeseries`) |
| `all` / `.` / `'*'` | Every module with a `MODULE_REPO` pin (quote the star so the shell doesn't glob) |

Examples:

```bash
make modules-update redistimeseries
make modules-update redisbloom redisearch redisjson
make modules-update all
```

The clone location is fixed at `modules/<name>/src/` (alongside the pin
Makefile). After every successful run, `modules/<name>/src/.prepared` is
touched so `common.mk`'s prepare step is satisfied and won't try to
re-clone on subsequent builds.

### Fetching full history: `make modules-unshallow`

`make modules-update` clones with `--depth 1` for speed/disk, which
leaves only the pinned tip commit visible to tools like Git Graph,
GitLens, or `git log`. To pull in the full upstream history (and the
submodules' full history) for already-cloned module(s):

```bash
make modules-unshallow redistimeseries
make modules-unshallow redisbloom redisearch
make modules-unshallow all
```

Idempotent: repos that already have full history are skipped. Note this
can add significant disk/network for large modules (e.g. `redisearch`).

---

## 3. Build: `make build`

```bash
make build [<name> ...|all|.|'*'|redis|none] [VAR=value ...]
```

Selection:

| Argument | Selects |
|---|---|
| *(none)* | Redis + every cloned module |
| `all` / `.` / `'*'` | Same as *(none)* |
| `redis` / `none` | Redis only; skip modules |
| `<name> [<name> ...]` | Redis + only the listed modules |

Invalid module names are detected **before** any compilation runs — you
won't waste time on a Redis rebuild just to hit a typo at the end.

Order (deliberate):

1. Validate selection.
2. Build Redis (`$(MAKE) -C src all`). If this fails, nothing else runs.
3. For each selected cloned module, invoke `$(MAKE) -C modules/<name>`
   (the wrapper Makefile, which uses `common.mk` to descend into
   `modules/<name>/src/`) with:
   ```make
   RM_INCLUDE_DIR=<repo>/src    # point at our redismodule.h
   RS_INCLUDE_DIR=<repo>/src    # redisearch SDK variant
   REDIS_SERVER=<repo>/src/redis-server
   ```
   Modules that honor these variables will compile against our freshly
   built `redismodule.h` and can use our `redis-server` for test
   harnesses. Modules that ignore them are unaffected.
4. Build stops on the first failing module (fail-fast).
5. Final output lists `src/redis-server` plus every `.so` produced per
   module.

Variables pass through: `make build VAR=value …`.

Examples:

```bash
make build                          # Redis + all cloned modules
make build redis                    # Redis only
make build redistimeseries          # Redis + just one module
make build redistimeseries redisbloom
```

---

## 4. Run: `make run`

```bash
make run [<name> ...] [ARGS="<redis-server args>"]
```

Starts `src/redis-server` and auto-loads modules via `--loadmodule`.

Selection:

| Argument | Selects |
|---|---|
| *(none)* | Load every cloned module |
| `all` / `.` / `'*'` | Same as *(none)* |
| `none` | Start Redis with no modules |
| `<name> [<name> ...]` | Load only the listed modules |

The `.so` path is discovered via `find` under `modules/<name>/` using
the filename from `TARGET_MODULE` (e.g. `rejson.so` for redisjson), so
**no hardcoded platform paths** — it works across macOS and Linux
regardless of each module's `FULL_VARIANT` naming (`macos-arm64v8-release`,
`linux-x64-release`, etc.). Release builds are preferred over debug
builds; `CMakeFiles/`, `tests/`, `samples/` are excluded.

Extra `redis-server` flags/config go through `ARGS`.

Examples:

```bash
make run                                              # all built modules, default port
make run redistimeseries                              # single module
make run redistimeseries redisbloom                   # subset
make run none                                         # bare redis-server
make run ARGS="--port 6400 --loglevel debug"          # all modules + custom args
make run redistimeseries ARGS="--port 6400"           # one module + custom args
make run none ARGS="redis.conf --appendonly yes"      # use a config file
```

Verification from another shell:

```bash
redis-cli -p 6379 MODULE LIST
```

If a module is cloned but not built, `make run` prints a warning and
skips it — it does not stop the other loads.

---

## 5. Test: `make test`

```bash
make test [all|<module> [<test_name>]] [TEST=<name>]
```

Dispatch:

| Command | Runs |
|---|---|
| `make test` | Redis tests only (`$(MAKE) -C src test`) |
| `make test all` / `.` / `'*'` | `make test` in every cloned module; continues past failures and summarizes at the end |
| `make test <module>` | `make test` in one module (full suite) |
| `make test <module> <test_name>` | `make test TEST=<test_name>` in one module |
| `make test <module> TEST=<name>` | Same, but for test names containing `:` (see below) |

### The `:` gotcha

GNU Make cannot have explicit target names containing `:` — the colon is
reserved for rule syntax. Test filters that include a `:` (common
convention: `file:test`, e.g. `test_asm:test_asm_with_data…`,
`test_basic.py:test_json_get`) **cannot** be passed positionally:

```bash
# Does NOT work — fails at parse time with a clear error:
make test redistimeseries test_asm:test_asm_with_data_and_queries_during_migrations

# Use TEST=<name> instead:
make test redistimeseries TEST=test_asm:test_asm_with_data_and_queries_during_migrations
```

Shell quotes (`"…"`, `'…'`) do **not** help — quoting is a shell concern,
not a Make one. The rule is:

| Arg shape | Make treats it as | May contain `:` |
|---|---|---|
| `foo` | Goal | No |
| `foo:bar` | Goal | No → error |
| `TEST=foo:bar` | Variable assignment | Yes |

### How test filtering is forwarded

Every cloned module (redisbloom, redisearch, redisjson, redistimeseries)
honors `TEST=<name>` in its own Makefile and forwards it to its test
runner (typically RLTest). Our `make test` simply sets that variable on
the sub-make invocation.

Examples:

```bash
make test                                          # Redis TCL tests
make test all                                      # every module's full suite
make test redistimeseries                          # redistimeseries full suite
make test redistimeseries ts_info                  # single simple-named test
make test redistimeseries TEST='test_asm:test_asm_with_data_and_queries_during_migrations'
make test redisjson       TEST='test_basic.py:test_json_get'
```

### `all` mode semantics

`make test all` runs each module's tests sequentially, **continuing on
failure** (unlike `make build`, which fails fast). At the end it prints
a summary of which modules failed and exits non-zero if any did. This
matches typical test-runner expectations — you see every module's
results in one go.

Single-module invocations `exec` the sub-make, so the module's exit
code propagates directly.

---

## 6. Common dependencies on macOS

Upstream module build/test systems expect tools not present in a stock
macOS install. Install these once:

```bash
# GNU Make 4.x (macOS ships 3.81)
brew install make
# Use `gmake` instead of `make` for everything below.

# Module test dependencies (Python)
pip3 install -r modules/<name>/src/tests/flow/requirements.txt
# redistimeseries' test_short_read.py also needs gevent on macOS,
# which its requirements.txt leaves commented out:
pip3 install gevent
```

Python 3.13 or 3.12 is a safer bet than 3.14 if a wheel fails to build.

---

## 7. End-to-end typical flow

```bash
# First time:
make modules-update all                       # fetch every module at its pin
make build                                    # build Redis, then every module

# Iterate:
make modules-update redisbloom                # bump to the current pin (re-runs are safe)
make build                                    # rebuild
make run redistimeseries redisbloom           # start Redis with just these two

# Verify:
redis-cli MODULE LIST

# Test:
make test                                     # Redis-only
make test redistimeseries                     # one module
make test redistimeseries TEST=ts_info        # one test
make test all                                 # every module
```

---

## 8. Full command reference

```
make modules-update <name> [<name> ...]      # idempotent: clones if missing, else updates to pin
make modules <name> [<name> ...]             # alias of modules-update
make modules-unshallow <name> [<name> ...]   # convert shallow clone(s) to full history

make build [<name> ...|all|.|'*'|redis|none] [VAR=value ...]

make run [<name> ...] [ARGS="<redis-server args>"]

make test
make test all | . | '*'
make test <module>
make test <module> <test_name>
make test <module> TEST=<name>                # required for names containing ':'
```

All targets are declared `.PHONY` and can be freely combined with make's
standard flags (`-j`, `-n`, `-C`, `-e`, …). Variables set on the command
line propagate to all sub-makes via `MAKEFLAGS`.
