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
# `make modules [clone|update] <name> [<name> ...]`
#
# Subcommands:
#   clone   (default)  Shallow-clone the selected module(s) into
#                      $(DEPS_MODULES_DIR) (default: deps/modules).
#   update             Ensure already-cloned module(s) match the current pin
#                      and re-sync their submodules. Safe to re-run.
#
# `make modules-update <name> ...` is kept as an alias of
# `make modules update <name> ...`.
#
# Pin variables (in each modules/<name>/Makefile):
#   MODULE_REPO    - required, git URL
#   MODULE_COMMIT  - optional SHA; takes precedence over MODULE_VERSION
#                    when non-empty. Empty string is ignored.
#   MODULE_VERSION - tag or branch; used when MODULE_COMMIT is empty.
#
# Name expansion: `all`, `.`, or '*' (quote the star) clones/updates every
# module under modules/ that pins MODULE_REPO.
# ----------------------------------------------------------------------------
DEPS_MODULES_DIR ?= deps/modules
# Only modules whose Makefile pins MODULE_REPO can be cloned this way
# (e.g. vector-sets lives in-tree, so it's excluded).
AVAILABLE_MODULES := $(sort $(shell grep -l '^[[:space:]]*MODULE_REPO[[:space:]]*=' modules/*/Makefile 2>/dev/null | sed -E 's|modules/([^/]+)/Makefile|\1|'))

MODULES_GOALS := modules modules-update
MODULES_SUBCMDS := clone update
ifneq ($(filter $(MODULES_GOALS),$(firstword $(MAKECMDGOALS))),)
  MODULES_RAW := $(filter-out $(MODULES_GOALS),$(MAKECMDGOALS))
  # First word may be a subcommand (clone|update); strip it if so.
  ifneq ($(filter $(MODULES_SUBCMDS),$(firstword $(MODULES_RAW))),)
    MODULES_ACTION := $(firstword $(MODULES_RAW))
    MODULES_ARGS := $(wordlist 2,$(words $(MODULES_RAW)),$(MODULES_RAW))
  else
    MODULES_ARGS := $(MODULES_RAW)
    ifeq ($(firstword $(MAKECMDGOALS)),modules-update)
      MODULES_ACTION := update
    else
      MODULES_ACTION := clone
    endif
  endif
  # Turn the extra goals (subcommand + names) into no-op targets so .DEFAULT
  # below doesn't try to build them by recursing into $(SUBDIRS).
  $(foreach m,$(MODULES_RAW),$(eval .PHONY: $(m))$(eval $(m): ; @:))
endif

# `make run <name> [<name> ...]` captures module names the same way.
ifeq ($(firstword $(MAKECMDGOALS)),run)
  RUN_ARGS := $(filter-out run,$(MAKECMDGOALS))
  $(foreach m,$(RUN_ARGS),$(eval .PHONY: $(m))$(eval $(m): ; @:))
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
# `make build [VAR=value ...]`
#
# Build order (important):
#   1. Build the main Redis (via `$(MAKE) -C src all`). If this fails we do
#      NOT attempt any module builds.
#   2. For every cloned module under $(DEPS_MODULES_DIR), invoke `$(MAKE)` in
#      the module's root directory, passing:
#        RM_INCLUDE_DIR=$(CURDIR)/src   # our freshly built redismodule.h
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
	echo "==> Building main Redis (src/)"; \
	$(MAKE) -C src all; \
	modules=""; \
	if [ -d "$(DEPS_MODULES_DIR)" ]; then \
		for d in "$(DEPS_MODULES_DIR)"/*/; do \
			[ -d "$$d/.git" ] || continue; \
			modules="$$modules $$(basename "$$d")"; \
		done; \
	fi; \
	if [ -z "$$modules" ]; then \
		echo; \
		echo "==> No cloned modules under $(DEPS_MODULES_DIR), skipping module builds"; \
	else \
		echo; \
		echo "==> Building modules against $(CURDIR)/src (RM_INCLUDE_DIR) and $(CURDIR)/src/redis-server:"; \
		echo "   $$modules"; \
		failed=""; \
		for name in $$modules; do \
			echo; \
			echo "==> [module] $$name ($(DEPS_MODULES_DIR)/$$name)"; \
			if ! $(MAKE) -C "$(DEPS_MODULES_DIR)/$$name" \
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
			sos=$$(find "$(DEPS_MODULES_DIR)/$$name" -type f -name '*.so' 2>/dev/null); \
			if [ -n "$$sos" ]; then \
				printf "      %-20s " "$$name:"; echo "$$sos" | head -1; \
				echo "$$sos" | tail -n +2 | sed 's|^|                           |'; \
			else \
				printf "      %-20s (no .so found)\n" "$$name:"; \
			fi; \
		done; \
	fi

# ----------------------------------------------------------------------------
# `make run [<name> ...] [ARGS="<redis-server args>"]`
#
# Starts src/redis-server with selected built module(s) auto-loaded via
# `--loadmodule`. Module selection:
#   (no args)            load every cloned module under $(DEPS_MODULES_DIR)
#   all / . / '*'        same as no args
#   none                 start with no modules at all
#   <name> [<name> ...]  load only the named modules
#
# The expected .so basename per module is read from TARGET_MODULE in
# modules/<name>/Makefile (handles quirks like redisjson → rejson.so).
# The actual .so path is located via `find` under $(DEPS_MODULES_DIR)/<name>/,
# so it works on any OS/arch without hardcoded `linux-x64-release` etc.
# Release builds are preferred over debug; paths under CMakeFiles/ and
# known test dirs are excluded.
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
	if [ -d "$(DEPS_MODULES_DIR)" ]; then \
		for d in "$(DEPS_MODULES_DIR)"/*/; do \
			[ -d "$$d/.git" ] || continue; \
			cloned="$$cloned $$(basename "$$d")"; \
		done; \
	fi; \
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
					echo "ERROR: module '$$r' is not cloned under $(DEPS_MODULES_DIR)"; \
					echo "Cloned modules: $$cloned"; \
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
		name_dir="$(DEPS_MODULES_DIR)/$$name"; \
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
# `make test [all|<module> [<test_name>]] [TEST=<name>]`
#
# Dispatches test execution:
#   make test                         run Redis tests (make -C src test)
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
	if [ -d "$(DEPS_MODULES_DIR)" ]; then \
		for d in "$(DEPS_MODULES_DIR)"/*/; do \
			[ -d "$$d/.git" ] || continue; \
			cloned="$$cloned $$(basename "$$d")"; \
		done; \
	fi; \
	cloned=$$(echo $$cloned); \
	case "$$target" in \
		all|.|'*') \
			if [ $$# -gt 0 ] || [ -n "$$test_var" ]; then \
				echo "ERROR: cannot pass a test name together with '$$target'"; \
				echo "       (select a single module when running one test)"; \
				exit 1; \
			fi; \
			if [ -z "$$cloned" ]; then \
				echo "ERROR: no cloned modules under $(DEPS_MODULES_DIR)"; \
				echo "       run 'make modules all' and 'make build' first"; \
				exit 1; \
			fi; \
			echo "==> Running tests for all cloned modules: $$cloned"; \
			failed=""; \
			for name in $$cloned; do \
				echo; \
				echo "==> [test] $$name ($(DEPS_MODULES_DIR)/$$name)"; \
				if ! $(MAKE) -C "$(DEPS_MODULES_DIR)/$$name" test; then \
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
				echo "ERROR: module '$$target' is not cloned under $(DEPS_MODULES_DIR)"; \
				echo "Cloned modules: $$cloned"; \
				echo "Usage:"; \
				echo "  make test                             # run Redis tests"; \
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
				exec $(MAKE) -C "$(DEPS_MODULES_DIR)/$$target" test; \
			else \
				echo "==> Running test '$$tname' for module '$$target' (TEST=$$tname)"; \
				exec $(MAKE) -C "$(DEPS_MODULES_DIR)/$$target" test TEST="$$tname"; \
			fi \
			;; \
	esac

modules modules-update:
	@action="$(MODULES_ACTION)"; \
	available="$(AVAILABLE_MODULES)"; \
	requested="$(MODULES_ARGS)"; \
	if [ -z "$$requested" ]; then \
		echo "Usage: make modules [clone|update] <name> [<name> ...]"; \
		echo "       make modules $$action all    # or '.' or '*' (quote the star)"; \
		echo "Available modules: $$available"; \
		exit 1; \
	fi; \
	for r in $$requested; do \
		case "$$r" in \
			all|.|'*') requested="$$available"; break ;; \
		esac; \
	done; \
	if [ "$$action" = "clone" ]; then mkdir -p "$(DEPS_MODULES_DIR)"; fi; \
	for name in $$requested; do \
		mkfile="modules/$$name/Makefile"; \
		if [ ! -f "$$mkfile" ]; then \
			echo "ERROR: unknown module '$$name' (expected $$mkfile)"; \
			echo "Available modules: $$available"; \
			exit 1; \
		fi; \
		version=$$(awk -F'=' '/^[[:space:]]*MODULE_VERSION[[:space:]]*=/ {gsub(/[ \t]/,"",$$2); print $$2; exit}' "$$mkfile"); \
		commit=$$(awk -F'=' '/^[[:space:]]*MODULE_COMMIT[[:space:]]*=/ {gsub(/[ \t]/,"",$$2); print $$2; exit}' "$$mkfile"); \
		repo=$$(awk -F'=' '/^[[:space:]]*MODULE_REPO[[:space:]]*=/ {sub(/^[ \t]*/,"",$$2); sub(/[ \t]*$$/,"",$$2); print $$2; exit}' "$$mkfile"); \
		dest="$(DEPS_MODULES_DIR)/$$name"; \
		if [ "$$action" = "clone" ]; then \
			if [ -z "$$repo" ]; then \
				echo "ERROR: MODULE_REPO is not set in $$mkfile"; exit 1; \
			fi; \
			if [ -z "$$commit" ] && [ -z "$$version" ]; then \
				echo "ERROR: need either MODULE_COMMIT or MODULE_VERSION in $$mkfile"; exit 1; \
			fi; \
			if [ -d "$$dest/.git" ]; then \
				echo "==> $$name already cloned at $$dest, skipping (use 'make modules update $$name' to refresh)"; \
				continue; \
			fi; \
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
			if [ ! -d "$$dest/.git" ]; then \
				echo "ERROR: $$name is not cloned at $$dest (run 'make modules $$name' first)"; \
				exit 1; \
			fi; \
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
			elif [ -n "$$version" ]; then \
				echo "==> Ensuring $$name is at $$version"; \
				git -C "$$dest" fetch --depth 1 origin "$$version" 2>/dev/null \
					|| git -C "$$dest" fetch --depth 1 origin "refs/tags/$$version:refs/tags/$$version" 2>/dev/null \
					|| git -C "$$dest" fetch origin; \
				git -C "$$dest" checkout -f "$$version" 2>/dev/null \
					|| git -C "$$dest" reset --hard FETCH_HEAD; \
			else \
				echo "WARNING: no MODULE_COMMIT or MODULE_VERSION in $$mkfile, skipping ref update"; \
			fi; \
			echo "==> Re-syncing submodules for $$name"; \
			git -C "$$dest" submodule sync --recursive; \
			git -C "$$dest" submodule update --init --recursive --depth 1; \
		fi; \
	done

.PHONY: install build run test modules modules-update
