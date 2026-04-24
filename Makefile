SHELL := /bin/bash

ACTIONLINT_VERSION := v1.7.12
GHALINT_VERSION    := v1.5.5
RENOVATE_VERSION   := 43.138.3
SHFMT_VERSION      := v3.13.1
SHELLCHECK_VERSION := v0.11.0

BIN_DIR := bin
OS      := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH    := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

SHELLCHECK_ARCH := $(shell echo $(ARCH) | sed 's/amd64/x86_64/;s/arm64/aarch64/')
SH_SCRIPTS      := setup.sh scripts/sync-actions-settings.sh scripts/place-template-files.sh scripts/generate-hashes.sh

ACTIONLINT := $(BIN_DIR)/actionlint
GHALINT    := $(BIN_DIR)/ghalint
SHFMT      := $(BIN_DIR)/shfmt
SHELLCHECK := $(BIN_DIR)/shellcheck

.PHONY: generate format format-shfmt lint lint-actionlint lint-ghalint lint-renovate lint-shfmt lint-shellcheck clean

generate:
	bash scripts/generate-hashes.sh

format: format-shfmt

format-shfmt: $(BIN_DIR)/.shfmt-$(SHFMT_VERSION)
	$(SHFMT) -w $(SH_SCRIPTS)

lint: lint-actionlint lint-ghalint lint-renovate lint-shfmt lint-shellcheck

lint-actionlint: $(BIN_DIR)/.actionlint-$(ACTIONLINT_VERSION)
	$(ACTIONLINT) -color

lint-ghalint: $(BIN_DIR)/.ghalint-$(GHALINT_VERSION)
	$(GHALINT) run

lint-renovate: export BUN_CONFIG_REGISTRY = https://npm.flatt.tech/
lint-renovate:
	bunx --package=renovate@$(RENOVATE_VERSION) renovate-config-validator --strict default.json .github/renovate.json

lint-shfmt: $(BIN_DIR)/.shfmt-$(SHFMT_VERSION)
	$(SHFMT) -d $(SH_SCRIPTS)

lint-shellcheck: $(BIN_DIR)/.shellcheck-$(SHELLCHECK_VERSION)
	$(SHELLCHECK) -o all $(SH_SCRIPTS)

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

$(BIN_DIR)/.shfmt-$(SHFMT_VERSION): | $(BIN_DIR)
	@rm -f $(SHFMT) $(BIN_DIR)/.shfmt-*
	@asset="shfmt_$(SHFMT_VERSION)_$(OS)_$(ARCH)"; \
	gh release download "$(SHFMT_VERSION)" \
	  -R mvdan/sh \
	  -p "$$asset" \
	  -O $(SHFMT); \
	chmod +x $(SHFMT)
	@touch $@

$(BIN_DIR)/.shellcheck-$(SHELLCHECK_VERSION): | $(BIN_DIR)
	@rm -f $(SHELLCHECK) $(BIN_DIR)/.shellcheck-*
	@asset="shellcheck-$(SHELLCHECK_VERSION).$(OS).$(SHELLCHECK_ARCH).tar.gz"; \
	gh release download "$(SHELLCHECK_VERSION)" \
	  -R koalaman/shellcheck \
	  -p "$$asset" \
	  -D $(BIN_DIR); \
	tar xzf "$(BIN_DIR)/$$asset" -C $(BIN_DIR) --strip-components=1 "shellcheck-$(SHELLCHECK_VERSION)/shellcheck"; \
	rm "$(BIN_DIR)/$$asset"
	@touch $@

$(BIN_DIR):
	@mkdir -p $@

clean:
	rm -rf $(BIN_DIR)
