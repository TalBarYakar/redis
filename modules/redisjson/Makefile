SRC_DIR = src
# Pin (repo / version / commit) lives in ../../modules.yaml.
TARGET_MODULE = $(SRC_DIR)/bin/$(FULL_VARIANT)/rejson.so

include ../common.mk

$(SRC_DIR)/.cargo_fetched:
	cd $(SRC_DIR) && cargo fetch

get_source: $(SRC_DIR)/.cargo_fetched
