# Top level makefile, the real stuff is at ./src/Makefile and in ./modules/Makefile

SUBDIRS = src
ifeq ($(BUILD_WITH_MODULES), yes)
	ifeq ($(MAKECMDGOALS),32bit)
    	$(error BUILD_WITH_MODULES=yes is not supported on 32 bit systems)
	endif
	SUBDIRS += modules
endif

default: all

# ----------------------------------------------------------------------------
# `make modules-update <name> [<name> ...]`   (alias: `make modules <name> ...`)
#
# Idempotent: if the module is not yet cloned at modules/<name>/src/, clones
# it at the pinned ref. If it is already cloned, fast-forwards/checks-out
# the current pin and re-syncs submodules. Safe to re-run.
#
# Pin data is loaded from `modules.yaml` at repo root via
# `utils/releasetools/modules-manifest.sh`. Each entry there carries:
#   repo     - required, git URL
#   version  - tag or branch; used when `commit` is empty
#   commit   - optional SHA; takes precedence over `version` when non-empty
#
# Name expansion: `all`, `.`, or '*' (quote the star) targets every module
# listed in modules.yaml.
# ----------------------------------------------------------------------------
# Manifest parsing (modules.yaml → AVAILABLE_MODULES + helpers). Both the
# top-level Makefile and modules/common.mk include this so a per-module
# build (`make -C modules/<name>`) sees the same data.
#
# The companion `modules/sync-redis-conf.mk` carries the repo-root-only
# `sync-redis-conf` recipe and is included from this Makefile *only*, so
# per-module builds never see that target (which would otherwise hijack
# their default goal — see modules/sync-redis-conf.mk for details).
include modules/manifest.mk
include modules/sync-redis-conf.mk

MODULES_GOALS := modules modules-update
ifneq ($(filter $(MODULES_GOALS),$(firstword $(MAKECMDGOALS))),)
  MODULES_ARGS := $(filter-out $(MODULES_GOALS),$(MAKECMDGOALS))
  # Turn the extra goals (module names) into no-op targets so .DEFAULT
  # below doesn't try to build them by recursing into $(SUBDIRS).
  $(foreach m,$(MODULES_ARGS),$(eval .PHONY: $(m))$(eval $(m): ; @:))
endif

# `make modules-unshallow <name> [<name> ...]` — fetch full history for the
# selected module(s)' shallow clones (so tools like Git Graph / `git log`
# show the full commit tree instead of only the pinned tip).
ifeq ($(firstword $(MAKECMDGOALS)),modules-unshallow)
  UNSHALLOW_ARGS := $(filter-out modules-unshallow,$(MAKECMDGOALS))
  $(foreach m,$(UNSHALLOW_ARGS),$(eval .PHONY: $(m))$(eval $(m): ; @:))
endif

# `make run <name> [<name> ...]` captures module names the same way.
ifeq ($(firstword $(MAKECMDGOALS)),run)
  RUN_ARGS := $(filter-out run,$(MAKECMDGOALS))
  $(foreach m,$(RUN_ARGS),$(eval .PHONY: $(m))$(eval $(m): ; @:))
endif

# `make build [<name> ...]` — same capture.
ifeq ($(firstword $(MAKECMDGOALS)),build)
  BUILD_ARGS := $(filter-out build,$(MAKECMDGOALS))
  $(foreach m,$(BUILD_ARGS),$(eval .PHONY: $(m))$(eval $(m): ; @:))
endif

# `make setup [<name> ...]` — install build/test prereqs for selected module(s).
ifeq ($(firstword $(MAKECMDGOALS)),setup)
  SETUP_ARGS := $(filter-out setup,$(MAKECMDGOALS))
  $(foreach m,$(SETUP_ARGS),$(eval .PHONY: $(m))$(eval $(m): ; @:))
endif

# `make test [all|<module> [<test_name>]]` capture — same trick.
# Note: Make cannot have explicit target names containing ':', so test names
# using the `file:test` convention (redisjson, RLTest filters, some
# redistimeseries tests like `test_asm:test_asm_with_data...`) must be passed
# via the TEST=<name> variable instead of as a positional argument.
ifeq ($(firstword $(MAKECMDGOALS)),test)
  TEST_ARGS := $(filter-out test,$(MAKECMDGOALS))
  TEST_ARGS_BAD := $(strip $(foreach m,$(TEST_ARGS),$(if $(findstring :,$(m)),$(m))))
  ifneq ($(TEST_ARGS_BAD),)
    $(error Test name(s) containing ':' cannot be passed positionally to make: '$(TEST_ARGS_BAD)'. Use TEST=<name> instead, e.g. `gmake test redistimeseries TEST='$(firstword $(TEST_ARGS_BAD))'`)
  endif
  $(foreach m,$(TEST_ARGS),$(eval .PHONY: $(m))$(eval $(m): ; @:))
endif

.DEFAULT:
	for dir in $(SUBDIRS); do $(MAKE) -C $$dir $@; done

install:
	for dir in $(SUBDIRS); do $(MAKE) -C $$dir $@; done

# ----------------------------------------------------------------------------
# `make build [<name> ...|all|.|'*'|none|redis] [VAR=value ...]`
#
# Module selection:
#   (no args)            build Redis + every cloned module
#   all / . / '*'        same as no args
#   redis / none         build Redis only; skip modules
#   <name> [<name> ...]  build Redis + only the listed modules
#
# Build order (important):
#   1. Build the main Redis (via `$(MAKE) -C src all`). If this fails we do
#      NOT attempt any module builds.
#   2. For each selected cloned module, invoke `$(MAKE) -C modules/<name>`
#      (the wrapper, which uses common.mk to descend into modules/<name>/src/),
#      passing:
#        RM_INCLUDE_DIR=$(CURDIR)/src   # our freshly built redismodule.h
#        RS_INCLUDE_DIR=$(CURDIR)/src
#        REDIS_SERVER=$(CURDIR)/src/redis-server
#      so each module compiles against the exact RedisModule API it will be
#      dlopen()'d into, and so any test harness run from the module points at
#      our build of redis-server.
#      Fail-fast on the first module that fails.
#   3. After a successful build, print the .so path(s) discovered per module.
#
# If no modules have been cloned yet, only the main Redis is built.
# ----------------------------------------------------------------------------
build:
	@set -e; \
	requested="$(BUILD_ARGS)"; \
	cloned=""; \
	for name in $(AVAILABLE_MODULES); do \
		if [ -f "modules/$$name/src/.prepared" ] || [ -e "modules/$$name/src/.git" ]; then \
			cloned="$$cloned $$name"; \
		fi; \
	done; \
	cloned=$$(echo $$cloned); \
	case "$$requested" in \
		""|all|.|'*') modules="$$cloned" ;; \
		redis|none) modules="" ;; \
		*) \
			for r in $$requested; do \
				case "$$r" in all|.|'*'|redis|none) \
					echo "ERROR: '$$r' cannot be mixed with explicit module names"; exit 1 ;; \
				esac; \
				found=""; \
				for c in $$cloned; do [ "$$c" = "$$r" ] && found=1; done; \
				if [ -z "$$found" ]; then \
					echo "ERROR: module '$$r' is not available under modules/$$r/src"; \
					echo "  (expect .git or .prepared in modules/$$r/src; see Makefile header for 'cloned')"; \
					echo "Modules found: $$cloned"; \
					echo "Hint: run 'make modules-update $$r' or clone into modules/$$r/src"; \
					exit 1; \
				fi; \
			done; \
			modules="$$requested" ;; \
	esac; \
	echo "==> Building main Redis (src/)"; \
	$(MAKE) -C src all; \
	if [ -z "$$modules" ]; then \
		echo; \
		if [ -z "$$cloned" ]; then \
			echo "==> No cloned modules under modules/*/src, Redis-only build"; \
		else \
			echo "==> Module builds skipped by request"; \
		fi; \
	else \
		echo; \
		echo "==> Building modules against $(CURDIR)/src (RM_INCLUDE_DIR) and $(CURDIR)/src/redis-server:"; \
		echo "   $$modules"; \
		failed=""; \
		for name in $$modules; do \
			echo; \
			echo "==> [module] $$name (modules/$$name)"; \
			if ! $(MAKE) -C "modules/$$name" \
				RM_INCLUDE_DIR="$(CURDIR)/src" \
				RS_INCLUDE_DIR="$(CURDIR)/src" \
				REDIS_SERVER="$(CURDIR)/src/redis-server"; then \
				failed="$$failed $$name"; \
				break; \
			fi; \
		done; \
		if [ -n "$$failed" ]; then \
			echo; \
			echo "ERROR: module build failed:$$failed"; \
			exit 1; \
		fi; \
	fi; \
	echo; \
	echo "==> Build complete."; \
	echo "    redis-server: $(CURDIR)/src/redis-server"; \
	if [ -n "$$modules" ]; then \
		echo "    Module artifacts:"; \
		for name in $$modules; do \
			sos=$$(find "modules/$$name" -type f -name '*.so' \
				-not -path '*/venv/*' \
				-not -path '*/.cargo/*' \
				-not -path '*/site-packages/*' \
				-not -path '*/deps/*' 2>/dev/null); \
			if [ -n "$$sos" ]; then \
				printf "      %-20s " "$$name:"; echo "$$sos" | head -1; \
				echo "$$sos" | tail -n +2 | sed 's|^|                           |'; \
			else \
				printf "      %-20s (no .so found)\n" "$$name:"; \
			fi; \
		done; \
	fi; \
	echo; \
	echo "==> Syncing redis.conf auto-managed modules block (based on .so presence)"; \
	$(MAKE) --no-print-directory sync-redis-conf

# ----------------------------------------------------------------------------
# `make setup [<name> ...|all|.|'*']`
#
# One-time install of build & test prereqs for the selected cloned
# module(s). The per-module setup logic lives in each upstream's own
# Makefile (`modules/<name>/src/Makefile`), so it's standalone-runnable
# as `cd modules/<name>/src && gmake setup` and can be committed back
# upstream. This target just dispatches via sub-make.
#
# Requires every cloned module to expose a `setup` target in its src
# Makefile (true for redisjson out of the box; added to redisbloom,
# redistimeseries, and redisearch in our forks).
#
# A module counts as "cloned" for setup/build/run/test if either
#   modules/<name>/src/.prepared exists (written by `make modules-update`), or
#   modules/<name>/src/.git exists (file or dir — supports manual clones and git worktrees).
#
# Module selection (matches build/run/test):
#   (no args) | all | . | '*'   every cloned module under modules/<name>/src
#   <name> [<name> ...]         the listed modules
#
# Continues past per-module failures, prints a summary, exits non-zero if
# any failed. Idempotent but slow; may prompt for sudo (apt/brew/dnf).
# NOT triggered automatically by `build` — invoke once on a fresh checkout.
# ----------------------------------------------------------------------------
setup:
	@requested="$(SETUP_ARGS)"; \
	cloned=""; \
	for name in $(AVAILABLE_MODULES); do \
		if [ -f "modules/$$name/src/.prepared" ] || [ -e "modules/$$name/src/.git" ]; then \
			cloned="$$cloned $$name"; \
		fi; \
	done; \
	cloned=$$(echo $$cloned); \
	case "$$requested" in \
		""|all|.|'*') selected="$$cloned" ;; \
		*) \
			for r in $$requested; do \
				case "$$r" in all|.|'*') \
					echo "ERROR: '$$r' cannot be mixed with explicit module names"; exit 1 ;; \
				esac; \
				found=""; \
				for c in $$cloned; do [ "$$c" = "$$r" ] && found=1; done; \
				if [ -z "$$found" ]; then \
					echo "ERROR: module '$$r' is not available under modules/$$r/src"; \
					echo "  (expect .git or .prepared; worktrees count as .git file)"; \
					echo "Modules found: $$cloned"; \
					echo "Hint: run 'make modules-update $$r' or ensure a git checkout at modules/$$r/src"; \
					exit 1; \
				fi; \
			done; \
			selected="$$requested" ;; \
	esac; \
	if [ -z "$$selected" ]; then \
		echo "ERROR: no modules to set up (no modules/*/src with .git or .prepared)"; \
		echo "       run 'make modules-update all' or clone into modules/<name>/src"; \
		exit 1; \
	fi; \
	echo "==> Setting up: $$selected"; \
	export PIP_BREAK_SYSTEM_PACKAGES=1; \
	failed=""; \
	for name in $$selected; do \
		echo; \
		echo "==> [setup] $$name"; \
		src_mk="modules/$$name/src/Makefile"; \
		if [ ! -f "$$src_mk" ]; then \
			echo "    !! SKIP: $$src_mk does not exist"; \
			echo "       (the upstream clone may be incomplete; try 'make modules-update $$name')"; \
			failed="$$failed $$name"; \
			continue; \
		fi; \
		if ! grep -qE '^setup[[:space:]]*:' "$$src_mk"; then \
			echo "    !! SKIP: no 'setup' target in $$src_mk"; \
			echo "       Add one to the upstream Makefile, e.g.:"; \
			echo "           setup:"; \
			echo "                   ./sbin/setup"; \
			echo "           .PHONY: setup"; \
			echo "       then commit & push to the module's repo."; \
			failed="$$failed $$name"; \
			continue; \
		fi; \
		if ! $(MAKE) -C "modules/$$name/src" setup; then \
			failed="$$failed $$name"; \
		fi; \
	done; \
	echo; \
	if [ -n "$$failed" ]; then \
		echo "==> Setup completed with FAILURES for:$$failed"; \
		echo "    Re-run 'make setup$$failed' after fixing the issues above."; \
		exit 1; \
	fi; \
	echo "==> Setup complete for: $$selected"; \
	echo "    Next: 'make build [<name>]' then 'make test [<name>]' or 'make run'."

# ----------------------------------------------------------------------------
# `make run [<name> ...] [ARGS="<redis-server args>"]`
#
# Starts src/redis-server with selected built module(s) auto-loaded via
# `--loadmodule`. Module selection:
#   (no args)            load every cloned module under modules/*/src
#   all / . / '*'        same as no args
#   none                 start with no modules at all
#   <name> [<name> ...]  load only the named modules
#
# The expected .so basename per module is read from TARGET_MODULE in
# modules/<name>/Makefile (handles quirks like redisjson → rejson.so).
# The actual .so path is located via `find` under modules/<name>/, so it
# works on any OS/arch without hardcoded `linux-x64-release` etc. Release
# builds are preferred over debug; paths under CMakeFiles/ and known test
# dirs are excluded.
#
# Extra server flags/config pass via ARGS:
#   make run ARGS="--port 6400 --daemonize no"
#   make run ARGS="redis.conf --loglevel debug"
#   make run redistimeseries ARGS="--port 6400"
# ----------------------------------------------------------------------------
run:
	@if [ ! -x src/redis-server ]; then \
		echo "ERROR: src/redis-server is not built. Run 'make build' (or 'make -C src all') first."; \
		exit 1; \
	fi; \
	requested="$(RUN_ARGS)"; \
	cloned=""; \
	for name in $(AVAILABLE_MODULES); do \
		if [ -f "modules/$$name/src/.prepared" ] || [ -e "modules/$$name/src/.git" ]; then \
			cloned="$$cloned $$name"; \
		fi; \
	done; \
	cloned=$$(echo $$cloned); \
	case "$$requested" in \
		""|all|.|'*') selected="$$cloned" ;; \
		none) selected="" ;; \
		*) \
			for r in $$requested; do \
				case "$$r" in all|.|'*'|none) \
					echo "ERROR: '$$r' cannot be mixed with explicit module names"; exit 1 ;; \
				esac; \
				found=""; \
				for c in $$cloned; do [ "$$c" = "$$r" ] && found=1; done; \
				if [ -z "$$found" ]; then \
					echo "ERROR: module '$$r' is not available under modules/$$r/src (.git or .prepared)"; \
					echo "Modules found: $$cloned"; \
					exit 1; \
				fi; \
			done; \
			selected="$$requested" ;; \
	esac; \
	load_flags=""; \
	for name in $$selected; do \
		wrapper="modules/$$name/Makefile"; \
		so_base=""; \
		if [ -f "$$wrapper" ]; then \
			target=$$(awk -F'=' '/^[[:space:]]*TARGET_MODULE[[:space:]]*=/ {sub(/^[ \t]*/,"",$$2); sub(/[ \t]*$$/,"",$$2); print $$2; exit}' "$$wrapper"); \
			so_base=$$(basename "$$target"); \
		fi; \
		[ -z "$$so_base" ] && so_base="$$name.so"; \
		name_dir="modules/$$name"; \
		candidates=$$(find "$$name_dir" -type f -name "$$so_base" 2>/dev/null \
			| grep -v -E '/(CMakeFiles|tests?|sample|samples|fixtures)/' || true); \
		so_path=$$(echo "$$candidates" | grep -E '(^|/)(release|[^/]*-release)(/|$$)' | head -1); \
		[ -z "$$so_path" ] && so_path=$$(echo "$$candidates" | head -1); \
		if [ -z "$$so_path" ]; then \
			echo "WARNING: no built $$so_base found under $$name_dir, skipping $$name (did you run 'make build'?)"; \
			continue; \
		fi; \
		echo "==> Loading $$name from $$so_path"; \
		load_flags="$$load_flags --loadmodule $$so_path"; \
	done; \
	if [ -z "$$load_flags" ]; then \
		echo "==> No modules selected; starting plain redis-server"; \
	fi; \
	echo "==> exec src/redis-server$$load_flags $(ARGS)"; \
	exec src/redis-server $$load_flags $(ARGS)

# ----------------------------------------------------------------------------
# `make test [redis|all|<module> [<test_name>]] [TEST=<name>]`
#
# Dispatches test execution:
#   make test                         run Redis tests (make -C src test)
#   make test redis | none            same — Redis tests only, no modules
#                                     (mirrors `make build redis|none`)
#   make test all | . | '*'           run `make test` for every cloned module
#   make test <module>                run full test suite for one module
#   make test <module> <test_name>    run a single test in one module
#                                     (passes TEST=<test_name>; convention
#                                     shared by redisbloom, redisearch,
#                                     redisjson, redistimeseries)
#   make test <module> TEST=<name>    same, but for test names Make can't
#                                     parse as goals (contain ':', e.g.
#                                     `file.py:test_foo`, `test_grp:test_a`)
#
# Positional <test_name> has the same effect as TEST=<name>; positional wins
# if both are supplied. Names containing ':' MUST use the TEST=... form —
# Make reserves ':' for rule syntax, so positional colon-names would fail at
# parse time (you'd get `target pattern contains no '%'`).
#
# In the "all" mode each module runs in sequence; failures are collected and
# reported at the end (non-zero exit if any failed), so you see every result.
# In the single-module modes, the module's make exit code propagates directly.
# ----------------------------------------------------------------------------
test:
	@args="$(TEST_ARGS)"; \
	test_var="$(TEST)"; \
	if [ -z "$$args" ]; then \
		echo "==> Running Redis tests (src/)"; \
		exec $(MAKE) -C src test; \
	fi; \
	set -- $$args; \
	target="$$1"; shift; \
	cloned=""; \
	for name in $(AVAILABLE_MODULES); do \
		if [ -f "modules/$$name/src/.prepared" ] || [ -e "modules/$$name/src/.git" ]; then \
			cloned="$$cloned $$name"; \
		fi; \
	done; \
	cloned=$$(echo $$cloned); \
	case "$$target" in \
		redis|none) \
			if [ $$# -gt 0 ] || [ -n "$$test_var" ]; then \
				echo "ERROR: cannot pass a test name together with '$$target'"; \
				echo "       ('$$target' selects Redis tests only — no module test name applies)"; \
				exit 1; \
			fi; \
			echo "==> Running Redis tests (src/)"; \
			exec $(MAKE) -C src test; \
			;; \
		all|.|'*') \
			if [ $$# -gt 0 ] || [ -n "$$test_var" ]; then \
				echo "ERROR: cannot pass a test name together with '$$target'"; \
				echo "       (select a single module when running one test)"; \
				exit 1; \
			fi; \
			if [ -z "$$cloned" ]; then \
				echo "ERROR: no cloned modules under modules/*/src"; \
				echo "       run 'make modules all' and 'make build' first"; \
				exit 1; \
			fi; \
			echo "==> Running tests for all cloned modules: $$cloned"; \
			failed=""; \
			for name in $$cloned; do \
				echo; \
				echo "==> [test] $$name (modules/$$name/src)"; \
				if ! $(MAKE) -C "modules/$$name/src" test; then \
					failed="$$failed $$name"; \
				fi; \
			done; \
			echo; \
			if [ -n "$$failed" ]; then \
				echo "==> Module tests FAILED for:$$failed"; \
				exit 1; \
			fi; \
			echo "==> Module tests passed for all cloned modules"; \
			;; \
		*) \
			ok=""; \
			for c in $$cloned; do [ "$$c" = "$$target" ] && ok=1; done; \
			if [ -z "$$ok" ]; then \
				echo "ERROR: module '$$target' is not cloned under modules/$$target/src"; \
				echo "Cloned modules: $$cloned"; \
				echo "Usage:"; \
				echo "  make test                             # run Redis tests"; \
				echo "  make test redis                       # run Redis tests (explicit)"; \
				echo "  make test all                         # run tests for every cloned module"; \
				echo "  make test <module>                    # run all tests for one module"; \
				echo "  make test <module> <test_name>        # run a single test (positional)"; \
				echo "  make test <module> TEST=<name>        # run a single test (use this for names with ':')"; \
				exit 1; \
			fi; \
			tname=""; \
			if [ $$# -eq 1 ]; then \
				tname="$$1"; \
			elif [ $$# -gt 1 ]; then \
				echo "ERROR: too many arguments."; \
				echo "Usage: make test <module> [<test_name>] [TEST=<name>]"; \
				exit 1; \
			fi; \
			if [ -z "$$tname" ] && [ -n "$$test_var" ]; then \
				tname="$$test_var"; \
			fi; \
			if [ -z "$$tname" ]; then \
				echo "==> Running all tests for module '$$target'"; \
				exec $(MAKE) -C "modules/$$target/src" test; \
			else \
				echo "==> Running test '$$tname' for module '$$target' (TEST=$$tname)"; \
				exec $(MAKE) -C "modules/$$target/src" test TEST="$$tname"; \
			fi \
			;; \
	esac

modules modules-update:
	@available="$(AVAILABLE_MODULES)"; \
	requested="$(MODULES_ARGS)"; \
	if [ -z "$$requested" ]; then \
		echo "Usage: make modules-update <name> [<name> ...]"; \
		echo "       make modules-update all    # or '.' or '*' (quote the star)"; \
		echo "Available modules: $$available"; \
		exit 1; \
	fi; \
	for r in $$requested; do \
		case "$$r" in \
			all|.|'*') requested="$$available"; break ;; \
		esac; \
	done; \
	for name in $$requested; do \
		case " $$available " in *" $$name "*) ;; *) \
			echo "ERROR: unknown module '$$name' (not listed in modules.yaml)"; \
			echo "Available modules: $$available"; \
			exit 1 ;; \
		esac; \
		repo=$$(awk    -v want="$$name" -v field=repo    '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
		version=$$(awk -v want="$$name" -v field=version '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
		commit=$$(awk  -v want="$$name" -v field=commit  '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
		dest="modules/$$name/src"; \
		if [ -z "$$repo" ]; then \
			echo "ERROR: 'repo' is not set for '$$name' in modules.yaml"; exit 1; \
		fi; \
		if [ -z "$$commit" ] && [ -z "$$version" ]; then \
			echo "ERROR: need either 'commit' or 'version' for '$$name' in modules.yaml"; exit 1; \
		fi; \
		if [ ! -d "$$dest/.git" ]; then \
			rm -rf "$$dest"; \
			if [ -n "$$commit" ]; then \
				echo "==> Cloning $$name @ commit $$commit from $$repo into $$dest"; \
				git init -q "$$dest"; \
				git -C "$$dest" remote add origin "$$repo"; \
				if ! git -C "$$dest" fetch --depth 1 origin "$$commit" 2>/dev/null; then \
					echo "    (shallow SHA fetch not supported by server, doing full fetch)"; \
					git -C "$$dest" fetch origin; \
				fi; \
				git -C "$$dest" checkout -q --detach "$$commit"; \
				git -C "$$dest" submodule update --init --recursive --depth 1; \
			else \
				echo "==> Cloning $$name $$version from $$repo into $$dest"; \
				git clone --recursive --depth 1 --branch "$$version" "$$repo" "$$dest"; \
			fi; \
		else \
			if [ -n "$$commit" ]; then \
				current=$$(git -C "$$dest" rev-parse HEAD); \
				if [ "$$current" = "$$commit" ] || [ "$${current#$$commit}" != "$$current" ]; then \
					echo "==> $$name already at commit $$commit"; \
				else \
					echo "==> Moving $$name to commit $$commit"; \
					if ! git -C "$$dest" fetch --depth 1 origin "$$commit" 2>/dev/null; then \
						echo "    (shallow SHA fetch not supported by server, doing full fetch)"; \
						git -C "$$dest" fetch origin; \
					fi; \
					git -C "$$dest" checkout -f --detach "$$commit"; \
				fi; \
			else \
				echo "==> Ensuring $$name is at $$version"; \
				git -C "$$dest" fetch --depth 1 origin "$$version" 2>/dev/null \
					|| git -C "$$dest" fetch --depth 1 origin "refs/tags/$$version:refs/tags/$$version" 2>/dev/null \
					|| git -C "$$dest" fetch origin; \
				git -C "$$dest" checkout -f "$$version" 2>/dev/null \
					|| git -C "$$dest" reset --hard FETCH_HEAD; \
			fi; \
			echo "==> Re-syncing submodules for $$name"; \
			git -C "$$dest" submodule sync --recursive; \
			git -C "$$dest" submodule update --init --recursive --depth 1; \
		fi; \
		touch "$$dest/.prepared"; \
	done; \
	echo; \
	echo "==> Syncing redis.conf auto-managed modules block"; \
	$(MAKE) --no-print-directory sync-redis-conf; \
	echo; \
	echo "==> Cloning/updating done. Now running 'make setup' for: $$requested"; \
	echo "    (skip with MODULES_UPDATE_SKIP_SETUP=1)"; \
	if [ "$(MODULES_UPDATE_SKIP_SETUP)" != "1" ]; then \
		$(MAKE) --no-print-directory setup $$requested; \
	else \
		echo "==> setup skipped (MODULES_UPDATE_SKIP_SETUP=1)"; \
	fi

# ----------------------------------------------------------------------------
# `make sync-redis-conf` — recipe lives in modules/sync-redis-conf.mk
# (included near the top of this Makefile). Kept out of modules/manifest.mk
# so it isn't visible from per-module builds. Listed in this Makefile's
# .PHONY further down so `gmake sync-redis-conf` works from the repo root
# and so `modules-update` can invoke it via $(MAKE).
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# `make modules-unshallow <name> [<name> ...]`
#
# `make modules-update` does a shallow, single-branch clone (--depth 1
# --branch <ref>) for speed, which leaves Git Graph / `git log` showing
# only the pinned tip and only that one branch. This target:
#
#   1. broadens origin's fetch refspec back to all branches and tags
#      (overwriting the single-branch refspec git wrote on clone);
#   2. fetches the full history (`--unshallow`) so every commit reachable
#      from any branch/tag becomes available locally;
#   3. does the same for each submodule.
#
# Idempotent: if the repo already has full history AND the broad
# refspec is already in place, nothing to do.
#
# Selection follows the same conventions as `make modules-update`:
#   <name> [<name> ...]   selected modules
#   all / . / '*'         every cloned module
# ----------------------------------------------------------------------------
modules-unshallow:
	@requested="$(UNSHALLOW_ARGS)"; \
	available="$(AVAILABLE_MODULES)"; \
	cloned=""; \
	for name in $$available; do \
		[ -d "modules/$$name/src/.git" ] && cloned="$$cloned $$name"; \
	done; \
	cloned=$$(echo $$cloned); \
	if [ -z "$$requested" ]; then \
		echo "Usage: make modules-unshallow <name> [<name> ...]"; \
		echo "       make modules-unshallow all   # or '.' or '*' (quote the star)"; \
		echo "Cloned modules: $$cloned"; \
		exit 1; \
	fi; \
	for r in $$requested; do \
		case "$$r" in \
			all|.|'*') requested="$$cloned"; break ;; \
		esac; \
	done; \
	if [ -z "$$cloned" ]; then \
		echo "ERROR: no cloned modules under modules/*/src"; \
		echo "       run 'make modules-update all' first"; \
		exit 1; \
	fi; \
	broaden_refspec() { \
		repo="$$1"; \
		git -C "$$repo" config --unset-all remote.origin.fetch 2>/dev/null || true; \
		git -C "$$repo" config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; \
		git -C "$$repo" config --bool remote.origin.tagopt false 2>/dev/null || true; \
	}; \
	for name in $$requested; do \
		dest="modules/$$name/src"; \
		if [ ! -d "$$dest/.git" ]; then \
			echo "ERROR: module '$$name' is not cloned at $$dest"; \
			echo "Cloned modules: $$cloned"; \
			exit 1; \
		fi; \
		echo "==> Broadening origin refspec for $$name ($$dest)"; \
		broaden_refspec "$$dest"; \
		if [ -f "$$dest/.git/shallow" ]; then \
			echo "==> Fetching full history + all branches/tags for $$name"; \
			git -C "$$dest" fetch --unshallow --tags origin '+refs/heads/*:refs/remotes/origin/*' \
				|| git -C "$$dest" fetch --depth=2147483647 --tags origin '+refs/heads/*:refs/remotes/origin/*'; \
		else \
			echo "==> Fetching all branches/tags for $$name (already deep)"; \
			git -C "$$dest" fetch --tags origin '+refs/heads/*:refs/remotes/origin/*'; \
		fi; \
		echo "==> Same treatment for $$name submodules"; \
		git -C "$$dest" submodule foreach --recursive ' \
			git config --unset-all remote.origin.fetch 2>/dev/null || true; \
			git config --add remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"; \
			if [ -f .git/shallow ] || [ -f "$$(git rev-parse --git-dir)/shallow" ]; then \
				git fetch --unshallow --tags origin "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null \
					|| git fetch --depth=2147483647 --tags origin "+refs/heads/*:refs/remotes/origin/*" \
					|| true; \
			else \
				git fetch --tags origin "+refs/heads/*:refs/remotes/origin/*" || true; \
			fi'; \
		touch "$$dest/.prepared"; \
	done

# ----------------------------------------------------------------------------
# `make release-tarball TAG=<tag> [STAGING_DIR=<dir>] [OUT_PATH=<path>] [TAR=<gnu-tar>]`
#
# Build a self-contained, reproducible source release tarball:
#
#   redis-<tag>/
#     <Redis core source tree from `git archive <tag>`>
#     modules/<name>/src/    <-- cloned per modules.yaml at pinned ref,
#                                with .git/ and .github/ stripped
#
# After `tar xzf redis-<tag>.tar.gz && cd redis-<tag>`, the user can run
#   gmake BUILD_WITH_MODULES=yes INSTALL_RUST_TOOLCHAIN=yes DISABLE_WERRORS=yes
#   ./src/redis-server redis.conf
# and have a working Redis + every bundled module loaded — without any git
# fetches or `make modules-update` invocations.
#
# Inputs:
#   TAG         (required)   git ref of Redis core to archive (e.g. 8.0.0)
#   STAGING_DIR (default:    /tmp/redis-tarball-staging-<tag>) — wiped on entry
#   OUT_PATH    (default:    /tmp/redis-<tag>.tar.gz)
#   TAR         (default:    gtar if found, else tar) — must be GNU tar so
#                            we can use --sort/--mtime/--owner/--group for
#                            byte-reproducible output across runs.
#
# Reproducibility: tar entries are sorted by name, mtimes set to the tag's
# commit timestamp, owner/group fixed to 0. Two runs from the same TAG
# produce byte-identical tarballs (assuming upstream module SHAs are
# unchanged).
# ----------------------------------------------------------------------------
TAR ?= $(shell command -v gtar 2>/dev/null || command -v tar 2>/dev/null)

release-tarball:
	@if [ -z "$(TAG)" ]; then \
		echo "ERROR: TAG=<tag> is required"; \
		echo "       e.g. 'make release-tarball TAG=8.0.0'"; \
		exit 1; \
	fi
	@if ! git rev-parse --verify -q "$(TAG)^{commit}" >/dev/null 2>&1; then \
		echo "ERROR: '$(TAG)' is not a valid git ref in this repo"; \
		exit 1; \
	fi
	@if [ -z "$(TAR)" ]; then \
		echo "ERROR: no tar binary found on PATH"; exit 1; \
	fi
	@if ! "$(TAR)" --version 2>&1 | grep -qi 'GNU tar'; then \
		echo "ERROR: GNU tar required (found: $$($(TAR) --version 2>&1 | head -1))"; \
		echo "       On macOS: brew install gnu-tar, then retry with TAR=gtar"; \
		exit 1; \
	fi
	@set -e; \
	tag="$(TAG)"; \
	staging="$(or $(STAGING_DIR),/tmp/redis-tarball-staging-$$tag)"; \
	out="$(or $(OUT_PATH),/tmp/redis-$$tag.tar.gz)"; \
	prefix="redis-$$tag"; \
	work="$$staging/$$prefix"; \
	echo "==> Staging at $$staging"; \
	rm -rf "$$staging"; \
	mkdir -p "$$work"; \
	echo "==> git archive Redis core @ $$tag → $$work"; \
	git archive --format=tar "$$tag" | "$(TAR)" -x -C "$$work"; \
	echo; \
	echo "==> Cloning bundled modules per modules.yaml"; \
	for name in $(AVAILABLE_MODULES); do \
		repo=$$(awk    -v want="$$name" -v field=repo    '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
		version=$$(awk -v want="$$name" -v field=version '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
		commit=$$(awk  -v want="$$name" -v field=commit  '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
		dest="$$work/modules/$$name/src"; \
		mkdir -p "$$work/modules/$$name"; \
		if [ -n "$$commit" ]; then \
			echo "  --> $$name @ commit $$commit ($$repo)"; \
			git init -q "$$dest"; \
			git -C "$$dest" remote add origin "$$repo"; \
			if ! git -C "$$dest" fetch --depth 1 origin "$$commit" 2>/dev/null; then \
				git -C "$$dest" fetch origin; \
			fi; \
			git -C "$$dest" checkout -q --detach "$$commit"; \
			git -C "$$dest" submodule update --init --recursive --depth 1; \
		else \
			echo "  --> $$name @ $$version ($$repo)"; \
			git clone --recursive --depth 1 --branch "$$version" "$$repo" "$$dest"; \
		fi; \
	done; \
	echo; \
	echo "==> Stripping .git and .github from cloned modules"; \
	find "$$work/modules" -name '.git' -prune -exec rm -rf {} + 2>/dev/null || true; \
	find "$$work/modules" -type d -name '.github' -prune -exec rm -rf {} + 2>/dev/null || true; \
	find "$$work/modules" -name '.gitmodules' -delete 2>/dev/null || true; \
	echo "==> Marking modules pre-prepared (so consumer 'make' skips clone step)"; \
	for name in $(AVAILABLE_MODULES); do \
		touch "$$work/modules/$$name/src/.prepared"; \
	done; \
	if [ -d "$$work/modules/redisearch/src" ]; then \
		echo "==> Re-creating empty .git marker for redisearch (its build.rs walks up to find one)"; \
		mkdir -p "$$work/modules/redisearch/src/.git"; \
	fi; \
	echo; \
	echo "==> Producing reproducible tarball at $$out"; \
	mtime=$$(git log -1 --format=%ct "$$tag"); \
	rm -f "$$out"; \
	(cd "$$staging" && "$(TAR)" \
		--sort=name \
		--mtime="@$$mtime" \
		--owner=0 --group=0 --numeric-owner \
		--use-compress-program='gzip -n' \
		-cf "$$out" "$$prefix"); \
	echo "==> Cleaning staging $$staging"; \
	rm -rf "$$staging"; \
	echo; \
	echo "==> Tarball ready: $$out"; \
	size=$$(du -h "$$out" | awk '{print $$1}'); \
	sha=$$(shasum -a 256 "$$out" | awk '{print $$1}'); \
	echo "    size:    $$size"; \
	echo "    sha256:  $$sha"

.PHONY: install build run test setup modules modules-update modules-unshallow sync-redis-conf release-tarball
