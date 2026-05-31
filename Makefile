.PHONY: help docs architecture

help: ## List available targets
	@echo "Echo: Audiobook Study Player — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

docs: ## Generate DocC documentation
	xcodebuild docbuild \
		-scheme "Echo: Audiobook Study Player" \
		-destination 'generic/platform=iOS' \
		DOCC_HOSTING_BASE_PATH="/orbit_audiobooks"
	@echo "Documentation successfully built in derived data."

architecture: ## Generate ARCHITECTURE.md from source tree
	Scripts/generate_architecture.sh
