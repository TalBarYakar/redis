# modules/sync-redis-conf.mk — repo-root-only target that rewrites the
# auto-managed modules block in redis.conf based on modules.yaml.
#
# This file is deliberately separate from modules/manifest.mk so that
# modules/common.mk (which only needs the manifest *parser*) can include
# manifest.mk without dragging the `sync-redis-conf` target into per-module
# Make scope. Per-module builds (`make -C modules/<name>`) have no business
# touching the repo-root redis.conf, so this target should not even be
# visible there.
#
# Include order:
#   - top-level Makefile: include modules/manifest.mk, then this file
#   - modules/common.mk:  include modules/manifest.mk only
#
# Behavior:
#   For every module listed in modules.yaml, emits either:
#     - active `loadmodule <so>` + `include modules/<name>/src/module.conf`
#       pair if `modules/<name>/src/.prepared` exists, or
#     - commented-out placeholders otherwise.
#
#   Block boundaries are the markers
#     "# >>> BEGIN auto-managed modules section <<<"
#     "# <<< END auto-managed modules section <<<"
#   in redis.conf. Anything outside the markers is preserved as-is.
#
# Usually invoked automatically by `make modules-update`; can also be run
# standalone after manually adding/removing `modules/<name>/src/.prepared`.
#
# REDIS_CONF defaults to `redis.conf` (relative to the current working
# directory, matching the convention used by every other path in our
# Makefile — invoke from the repo root).
#
# Requires manifest.mk to have been included first (uses AVAILABLE_MODULES,
# MANIFEST_FIELD_AWK, MODULES_MANIFEST_FILE).

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
			if [ -f "$$so" ]; then \
				echo "loadmodule $$so"; \
				echo "include modules/$$name/src/module.conf"; \
			else \
				echo "# $$name .so not built at $$so (run 'make build $$name' to enable)"; \
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
	built=""; not_built=""; \
	for name in $(AVAILABLE_MODULES); do \
		so=$$(awk -v want="$$name" -v field=loadmodule '$(MANIFEST_FIELD_AWK)' $(MODULES_MANIFEST_FILE)); \
		if [ -n "$$so" ] && [ -f "$$so" ]; then built="$$built $$name"; \
		else not_built="$$not_built $$name"; fi; \
	done; \
	built=$$(echo $$built); not_built=$$(echo $$not_built); \
	echo "    enabled in $(REDIS_CONF): $${built:-<none>}"; \
	echo "    commented out:           $${not_built:-<none>}"

.PHONY: sync-redis-conf
