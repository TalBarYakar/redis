SRC_DIR = src
# Pinned to a fork branch with a CI-aligned `setup:` target in src/Makefile.
# Switch back to a release tag (e.g. v8.7.90) once that change is merged
# upstream and tagged.
MODULE_VERSION = tal.ba/feat/make_setup_ci_aligned
# Optional: pin to an exact commit SHA (takes precedence over MODULE_VERSION
# when non-empty). Leave empty to use MODULE_VERSION.
MODULE_COMMIT =
MODULE_REPO = https://github.com/redisjson/redisjson
TARGET_MODULE = $(SRC_DIR)/bin/$(FULL_VARIANT)/rejson.so

include ../common.mk

$(SRC_DIR)/.cargo_fetched:
	cd $(SRC_DIR) && cargo fetch

get_source: $(SRC_DIR)/.cargo_fetched
