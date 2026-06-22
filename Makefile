.PHONY: help docs architecture whats-new doc-automation-test test build-tests test-only hooks-test

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

whats-new: ## Draft nightly "What to Test" from commits since last weekly (stdout)
	@PYTHONPATH=Scripts python3 -m doc_automation.whats_new \
		--template fastlane/testflight/what_to_test.template.txt --out -

doc-automation-test: ## Run the doc-automation Python unit tests
	@PYTHONPATH=Scripts python3 -m unittest discover -s Scripts/doc_automation/tests -t Scripts -v

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

hooks-test: ## Run the Claude Code hook test suites (xcodebuild guard + swift-format)
	@bash .claude/hooks/test-guard-xcodebuild.sh
	@bash .claude/hooks/test-swift-format-on-edit.sh
