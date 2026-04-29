SRC_DIR = src
MODULE_VERSION = v8.7.90
# Optional: pin to an exact commit SHA (takes precedence over MODULE_VERSION
# when non-empty). Leave empty to use MODULE_VERSION.
MODULE_COMMIT =
MODULE_REPO = https://github.com/redisjson/redisjson
TARGET_MODULE = $(SRC_DIR)/bin/$(FULL_VARIANT)/rejson.so

include ../common.mk

$(SRC_DIR)/.cargo_fetched:
	cd $(SRC_DIR) && cargo fetch

get_source: $(SRC_DIR)/.cargo_fetched
