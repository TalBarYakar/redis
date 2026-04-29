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

# Note: this file intentionally defines NO targets.
#
# Both the top-level Makefile and modules/common.mk (via every per-module
# Makefile) include manifest.mk to read the manifest. If we declared a
# target here, it would become the default goal of any per-module
# `make -C modules/<name>` invocation (since GNU Make uses the first
# non-pattern target it sees). The companion file `sync-redis-conf.mk`
# carries the `sync-redis-conf` recipe and is included only by the
# top-level Makefile.
