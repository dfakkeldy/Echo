.PHONY: help docs architecture test build-tests test-only

help: ## List available targets
	@echo "Echo: Audiobook Study Player — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

docs: ## Generate DocC documentation
	xcodebuild docbuild \
		-scheme "Echo" \
		-destination 'generic/platform=iOS' \
		DOCC_HOSTING_BASE_PATH="/echo"
	@echo "Documentation successfully built in derived data."

architecture: ## Generate ARCHITECTURE.md from source tree
	Scripts/generate_architecture.sh

SIM_DEST = platform=iOS Simulator,name=iPhone 17

test: ## Run unit tests (RAM-friendly: serial sim, capped compile jobs)
	set -o pipefail; xcodebuild test -scheme Echo \
	  -destination '$(SIM_DEST)' \
	  -only-testing:EchoTests \
	  -parallel-testing-enabled NO \
	  -jobs 5 2>&1 | grep -E "Test case|TEST (SUCCEEDED|FAILED)|error:"

build-tests: ## Build test products once after a code change
	xcodebuild build-for-testing -scheme Echo -destination '$(SIM_DEST)' -jobs 5

test-only: ## Re-run without rebuilding: make test-only FILTER=EchoTests/TOCTreeBuilderTests
	xcodebuild test-without-building -scheme Echo -destination '$(SIM_DEST)' \
	  -only-testing:$(or $(FILTER),EchoTests) -parallel-testing-enabled NO
