SHELL := /bin/bash

ACTIONLINT_VERSION := v1.7.11
GHALINT_VERSION    := v1.5.5
RENOVATE_VERSION   := 43.56.0

BIN_DIR := bin
OS      := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH    := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

ACTIONLINT := $(BIN_DIR)/actionlint
GHALINT    := $(BIN_DIR)/ghalint

.PHONY: lint lint-actionlint lint-ghalint lint-renovate clean

lint: lint-actionlint lint-ghalint lint-renovate

lint-actionlint: $(BIN_DIR)/.actionlint-$(ACTIONLINT_VERSION)
	$(ACTIONLINT) -color

lint-ghalint: $(BIN_DIR)/.ghalint-$(GHALINT_VERSION)
	$(GHALINT) run

lint-renovate:
	bunx --package=renovate@$(RENOVATE_VERSION) renovate-config-validator --strict default.json .github/renovate.json

$(BIN_DIR)/.actionlint-$(ACTIONLINT_VERSION): | $(BIN_DIR)
	@rm -f $(ACTIONLINT) $(BIN_DIR)/.actionlint-*
	cd $(BIN_DIR) && bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/refs/tags/$(ACTIONLINT_VERSION)/scripts/download-actionlint.bash)
	@touch $@

$(BIN_DIR)/.ghalint-$(GHALINT_VERSION): | $(BIN_DIR)
	@rm -f $(GHALINT) $(BIN_DIR)/.ghalint-*
	@asset="ghalint_$(GHALINT_VERSION:v%=%)_$(OS)_$(ARCH).tar.gz"; \
	gh release download "$(GHALINT_VERSION)" \
	  -R suzuki-shunsuke/ghalint \
	  -p "$$asset" \
	  -D $(BIN_DIR); \
	tar xzf "$(BIN_DIR)/$$asset" -C $(BIN_DIR) ghalint; \
	rm "$(BIN_DIR)/$$asset"
	@touch $@

$(BIN_DIR):
	@mkdir -p $@

clean:
	rm -rf $(BIN_DIR)
