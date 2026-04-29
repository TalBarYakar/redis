# modules/manifest.mk — read fields out of modules.yaml from inside Make.
#
# Included by both the top-level Makefile and modules/common.mk so both
# have a single, manifest-driven view of the bundled modules without
# pulling in a shell helper, yq, or python.
#
# What it provides:
#   MODULES_MANIFEST_FILE  - path to the YAML manifest, resolved from this
#                            file's location so callers don't have to set it.
#   AVAILABLE_MODULES      - sorted, space-separated list of module names.
#   $(call manifest-field,<field>,<name>)
#                          - returns the trimmed value of a field for a
#                            module (empty if the field is empty; empty if
#                            the module is unknown).
#   MANIFEST_NAMES_AWK     - awk program text (Make variable). Use as
#                              awk '$(MANIFEST_NAMES_AWK)' $(MODULES_MANIFEST_FILE)
#   MANIFEST_FIELD_AWK     - awk program text. Use as
#                              awk -v want=<name> -v field=<field> \
#                                  '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)
#
# Implementation notes:
#   - Both awk programs are single-line on purpose: they get inlined into
#     `$(shell ...)` calls and into recipe shells, and embedded newlines
#     would break the latter (Make ends a recipe line at every unescaped
#     newline).
#   - Variables are immediate (`:=`) so `$$` collapses to a literal `$` at
#     parse time. Subsequent `$(MANIFEST_*_AWK)` references just substitute
#     the stored text, with no further expansion — that's what lets the
#     awk source contain `$0`, `$/`, etc. without Make/shell interpreting
#     them.
#   - Single-quoted in the shell (`awk '$(...)'`) so the shell doesn't
#     re-interpret any `$` characters inside the awk program either.
#
# YAML format the awk parser accepts (kept deliberately narrow): a
# top-level `modules:` key followed by list items shaped as
#
#     - name: <module>
#       repo: <url>
#       version: <ref>
#       commit: <sha-or-empty>
#
# No nested structures, no inline comments after values, no quoted strings.

# Locate the manifest file relative to this .mk file. `$(lastword
# MAKEFILE_LIST)` is set to this file's path at the moment Make is
# processing it, so the resulting MODULES_MANIFEST_FILE works regardless
# of which include chain pulled us in (top-level Makefile, common.mk via
# a per-module Makefile, etc.).
MANIFEST_MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
MODULES_MANIFEST_FILE ?= $(MANIFEST_MK_DIR)../modules.yaml

# Awk program: print one module name per line, in manifest order.
# `sub()` and `length()` default to operating on $0, so the program text
# itself doesn't need to mention $0 — fewer surprises through Make+shell.
MANIFEST_NAMES_AWK := /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, ""); sub(/[[:space:]]+$$/, ""); if (length() > 0) print }

# Awk program: print the value of `field` for the module named `want`
# (both passed via `-v`). Prints an empty line if the field is present but
# empty; prints nothing if the module is missing.
MANIFEST_FIELD_AWK := BEGIN { cur = "" } /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ { line = $$0; sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line); sub(/[[:space:]]+$$/, "", line); cur = line; next } cur == want { pat = "^[[:space:]]+" field ":"; if ($$0 ~ pat) { v = $$0; sub("^[[:space:]]+" field ":[[:space:]]*", "", v); sub(/[[:space:]]+$$/, "", v); print v; exit } }

# Make-time helper: $(call manifest-field,<field>,<name>).
# Re-runs awk on every reference (it's `=`, not `:=`) which is fine — the
# manifest is small and this is only invoked at parse time, not in hot loops.
manifest-field = $(shell awk -v want="$2" -v field="$1" '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE) 2>/dev/null)

# Sorted list of every module known to the manifest. Computed once at parse
# time. Empty if the manifest is missing or unreadable; downstream targets
# already handle that case.
AVAILABLE_MODULES := $(sort $(shell awk '$(MANIFEST_NAMES_AWK)' $(MODULES_MANIFEST_FILE) 2>/dev/null))

# ----------------------------------------------------------------------------
# `make sync-redis-conf` — rewrite the auto-managed modules block in redis.conf
#
# For every module listed in modules.yaml, emits either:
#   - active `loadmodule <so>` + `include modules/<name>/src/module.conf`
#     pair if `modules/<name>/src/.prepared` exists, or
#   - commented-out placeholders otherwise.
#
# Block boundaries are the markers
#   "# >>> BEGIN auto-managed modules section <<<"
#   "# <<< END auto-managed modules section <<<"
# in redis.conf. Anything outside the markers is preserved as-is.
#
# Usually invoked automatically by `make modules-update`; can also be run
# standalone after manually adding/removing `modules/<name>/src/.prepared`.
#
# REDIS_CONF defaults to `redis.conf` (relative to the current working
# directory, matching the convention used by every other path in our
# Makefile — invoke from the repo root).
# ----------------------------------------------------------------------------
REDIS_CONF ?= redis.conf

sync-redis-conf:
	@if [ ! -f "$(REDIS_CONF)" ]; then \
		echo "ERROR: $(REDIS_CONF) not found"; exit 1; \
	fi; \
	if ! grep -q '^# >>> BEGIN auto-managed modules section <<<$$' "$(REDIS_CONF)"; then \
		echo "ERROR: BEGIN marker not found in $(REDIS_CONF)"; \
		echo "       Expected line: '# >>> BEGIN auto-managed modules section <<<'"; \
		exit 1; \
	fi; \
	if ! grep -q '^# <<< END auto-managed modules section <<<$$' "$(REDIS_CONF)"; then \
		echo "ERROR: END marker not found in $(REDIS_CONF)"; \
		echo "       Expected line: '# <<< END auto-managed modules section <<<'"; \
		exit 1; \
	fi; \
	block=$$(mktemp -t redis-conf-block.XXXXXX); \
	trap 'rm -f "$$block" "$(REDIS_CONF).tmp"' EXIT; \
	{ \
		echo "# (Anything between this and the matching END marker is rewritten by"; \
		echo "#  \`make modules-update\`. Edits inside this block will be lost.)"; \
		echo; \
		first=1; \
		for name in $(AVAILABLE_MODULES); do \
			so=$$(awk -v want="$$name" -v field=loadmodule '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
			if [ -z "$$so" ]; then \
				echo "WARNING: 'loadmodule' field missing for '$$name' in modules.yaml" >&2; \
				continue; \
			fi; \
			[ "$$first" = "1" ] || echo; \
			first=0; \
			if [ -f "modules/$$name/src/.prepared" ]; then \
				echo "loadmodule $$so"; \
				echo "include modules/$$name/src/module.conf"; \
			else \
				echo "# $$name not cloned (run 'make modules-update $$name' to enable)"; \
				echo "# loadmodule $$so"; \
				echo "# include modules/$$name/src/module.conf"; \
			fi; \
		done; \
		echo; \
	} > "$$block"; \
	awk -v block="$$block" '\
		/^# >>> BEGIN auto-managed modules section <<<$$/ { \
			print; \
			while ((getline line < block) > 0) print line; \
			skip=1; next; \
		} \
		/^# <<< END auto-managed modules section <<<$$/ { skip=0 } \
		!skip { print } \
	' "$(REDIS_CONF)" > "$(REDIS_CONF).tmp"; \
	mv "$(REDIS_CONF).tmp" "$(REDIS_CONF)"; \
	cloned=""; not_cloned=""; \
	for name in $(AVAILABLE_MODULES); do \
		if [ -f "modules/$$name/src/.prepared" ]; then cloned="$$cloned $$name"; \
		else not_cloned="$$not_cloned $$name"; fi; \
	done; \
	cloned=$$(echo $$cloned); not_cloned=$$(echo $$not_cloned); \
	echo "    enabled in $(REDIS_CONF): $${cloned:-<none>}"; \
	echo "    commented out:           $${not_cloned:-<none>}"

.PHONY: sync-redis-conf
