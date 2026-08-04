.PHONY: help docs architecture whats-new devlog-update devlog-pr-body doc-automation-test pronunciation-corpus-test pronunciation-corpus-qualification pronunciation-program-report pronunciation-pack pronunciation-pack-test pronunciation-audit-pack pronunciation-audit-pack-test pronunciation-audio-judge-test test build-tests test-only hooks-test echo-cli renderer-install-test install-renderer verify-renderer promote-renderer repair-renderer

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

devlog-update: ## Update generated weekly devlog blocks from the previous calendar week
	@PYTHONPATH=Scripts python3 -m doc_automation.devlog \
		--markdown docs/guides/devlog.md \
		--html docs/devlog.html

devlog-pr-body: ## Generate the review checklist and AI-assisted draft for the weekly devlog PR
	@PYTHONPATH=Scripts python3 -m doc_automation.curate_devlog \
		--project-name Echo \
		--markdown docs/guides/devlog.md \
		--html docs/devlog.html \
		--repo-url https://github.com/dfakkeldy/Echo \
		--extra-guidance "Echo is an audiobook study player. Avoid claiming public launch status, account creation, download counts, or revenue unless present in the factual digest." \
		--extra-checklist "Verify any narration, reading, beta, or App Store claims against the linked commits before posting." \
		--out "$${DEVLOG_PR_BODY:-devlog-pr-body.md}"

doc-automation-test: ## Run the doc-automation Python unit tests
	@PYTHONPATH=Scripts python3 -m unittest discover -s Scripts/doc_automation/tests -t Scripts -v

pronunciation-corpus-test: ## Validate pronunciation corpus tests and fixture contracts
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_pronunciation_corpus.py'
	python3 Tools/Pronunciation/pronunciation_corpus.py validate-contract \
		--fixtures EchoTests/Fixtures/Pronunciation

pronunciation-corpus-qualification: ## Report independent-label corpus qualification
	python3 Tools/Pronunciation/pronunciation_corpus.py qualification-status \
		--fixtures EchoTests/Fixtures/Pronunciation

pronunciation-program-report: ## Emit deterministic pronunciation program metrics
	@python3 Tools/Pronunciation/pronunciation_corpus.py report \
		--fixtures EchoTests/Fixtures/Pronunciation \
		--pack EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json

pronunciation-pack: ## Regenerate the pinned supplemental pronunciation pack
	python3 Tools/Pronunciation/build_pronunciation_pack.py build \
		--lock Tools/Pronunciation/cmudict.lock.json \
		--gold EchoCore/Services/Narration/MisakiResources/us_gold.json \
		--silver EchoCore/Services/Narration/MisakiResources/us_silver.json \
		--vocab EchoCore/Services/Narration/_kokoro_vocab.json \
		--output EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json

pronunciation-pack-test: ## Test and deterministically verify the pronunciation pack
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_build_pronunciation_pack.py'
	python3 Tools/Pronunciation/build_pronunciation_pack.py check \
		--lock Tools/Pronunciation/cmudict.lock.json \
		--gold EchoCore/Services/Narration/MisakiResources/us_gold.json \
		--silver EchoCore/Services/Narration/MisakiResources/us_silver.json \
		--vocab EchoCore/Services/Narration/_kokoro_vocab.json \
		--expected EchoCore/Services/Narration/PronunciationResources/us_pronunciation_pack.json

pronunciation-audit-pack: ## Regenerate the pinned audit-only pronunciation disagreement pack
	python3 Tools/Pronunciation/build_pronunciation_audit_pack.py build \
		--lock Tools/Pronunciation/cmudict.lock.json \
		--gold EchoCore/Services/Narration/MisakiResources/us_gold.json \
		--silver EchoCore/Services/Narration/MisakiResources/us_silver.json \
		--vocab EchoCore/Services/Narration/_kokoro_vocab.json \
		--output EchoCore/Services/Narration/PronunciationResources/us_pronunciation_audit_pack.json

pronunciation-audit-pack-test: ## Test and deterministically verify the audit-only pronunciation disagreement pack
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_build_pronunciation_audit_pack.py'
	python3 Tools/Pronunciation/build_pronunciation_audit_pack.py check \
		--lock Tools/Pronunciation/cmudict.lock.json \
		--gold EchoCore/Services/Narration/MisakiResources/us_gold.json \
		--silver EchoCore/Services/Narration/MisakiResources/us_silver.json \
		--vocab EchoCore/Services/Narration/_kokoro_vocab.json \
		--expected EchoCore/Services/Narration/PronunciationResources/us_pronunciation_audit_pack.json

pronunciation-audio-judge-test: ## Test the development-only public/synthetic audio judge
	python3 -m unittest discover -s Tools/Pronunciation/tests -p 'test_audio_judge.py'

SIM_DEST = platform=iOS Simulator,name=iPhone 17

# Simulator builds aren't signature-enforced, so we disable code signing for the
# test action. This sidesteps Xcode's embedded-framework CodeSign step choking on
# onnxruntime.framework / onnxruntime_extensions.framework: those are static libs
# already linked into the app binary, and the "Strip statically-linked onnxruntime
# frameworks (ITMS-90208)" run-script phase rm -rf's their embedded copies, leaving
# a codeless bundle that codesign rejects on Xcode 26.5. The strip phase is still
# required for App Store archives, so this flag is scoped to the simulator test
# targets only and does not touch the release/archive signing path.
CODESIGN_OFF = CODE_SIGNING_ALLOWED=NO

test: ## Run unit tests (RAM-friendly: serial sim, capped compile jobs)
	set -o pipefail; xcodebuild test -scheme Echo \
	  -destination '$(SIM_DEST)' \
	  -only-testing:EchoTests \
	  -parallel-testing-enabled NO \
	  -jobs 5 $(CODESIGN_OFF) 2>&1 | grep -E "Test case|TEST (SUCCEEDED|FAILED)|error:"

build-tests: ## Build test products once after a code change
	xcodebuild build-for-testing -scheme Echo -destination '$(SIM_DEST)' -jobs 5 $(CODESIGN_OFF)

test-only: ## Re-run without rebuilding: make test-only FILTER=EchoTests/TOCTreeBuilderTests
	xcodebuild test-without-building -scheme Echo -destination '$(SIM_DEST)' \
	  -only-testing:$(or $(FILTER),EchoTests) -parallel-testing-enabled NO $(CODESIGN_OFF)

hooks-test: ## Run the Claude Code hook test suites (xcodebuild guard + swift-format)
	@bash .claude/hooks/test-guard-xcodebuild.sh
	@bash .claude/hooks/test-swift-format-on-edit.sh

# Release is non-negotiable here: the scheme's default (Debug/-Onone) is
# ~26% slower on inference-bound narrate and far slower on Swift-heavy
# qa/deck/sidecar paths, and overnight agents have shipped whole books through
# it. SWIFT_COMPILATION_MODE=incremental is equally non-negotiable: Release's
# default wholemodule optimization miscompiles an async continuation in the
# narration chain on macOS 26 (Swift 6.2 toolchain) and the binary hangs
# forever at the first synthesize — incremental keeps full -O per function and
# dodges it. A dedicated derivedDataPath gives agents one stable binary path
# instead of rediscovering DerivedData each session.
echo-cli: ## Build Release echo-cli → .build/cli/Build/Products/Release/echo-cli
	set -o pipefail; xcodebuild build -scheme echo-cli \
	  -destination 'platform=macOS' -configuration Release \
	  SWIFT_COMPILATION_MODE=incremental \
	  -derivedDataPath .build/cli -jobs 5 $(CODESIGN_OFF) -quiet
	@echo "echo-cli (Release) ready at: .build/cli/Build/Products/Release/echo-cli"

# Renderer install/verify/promote/repair variables. The two "APPROVED_" SHAs
# are the attested identities the leased renderer transaction checks against
# -- they are inputs the caller supplies, never inferred from the working
# tree. ECHO_RENDERER_SOURCE is the worktree holding the approved
# pronunciation-fix source (APPROVED_ECHO_PRONUNCIATION_SHA is its commit);
# $(CURDIR), this repo, is always the installer worktree. ECHO_RENDERER_ROOT
# and ECHO_BUILD_GATE override the CLI's own defaults and are only appended
# to the command when set.
APPROVED_ECHO_INSTALLER_SHA ?=
APPROVED_ECHO_PRONUNCIATION_SHA ?=
ECHO_RENDERER_SOURCE ?=
ECHO_RENDERER_MANIFEST_SHA ?=
ECHO_RENDERER_ROOT ?=
ECHO_BUILD_GATE ?=

renderer-install-test: ## Run the echo_renderer Python unit tests (store, lease, CLI)
	@PYTHONPATH=Scripts python3 -m unittest discover -s Scripts/echo_renderer/tests -t Scripts -v

install-renderer: ## Build, stage, verify, and publish one approved renderer package
	@PYTHONPATH=Scripts python3 -m echo_renderer.cli install \
	  --installer-worktree "$(CURDIR)" \
	  --installer-sha "$(APPROVED_ECHO_INSTALLER_SHA)" \
	  --source-worktree "$(ECHO_RENDERER_SOURCE)" \
	  --source-sha "$(APPROVED_ECHO_PRONUNCIATION_SHA)" \
	  $(if $(ECHO_RENDERER_ROOT),--renderer-root "$(ECHO_RENDERER_ROOT)") \
	  $(if $(ECHO_BUILD_GATE),--build-gate "$(ECHO_BUILD_GATE)")

verify-renderer: ## Strictly re-verify one published renderer package
	@PYTHONPATH=Scripts python3 -m echo_renderer.cli verify \
	  --source-sha "$(APPROVED_ECHO_PRONUNCIATION_SHA)" \
	  --manifest-sha "$(ECHO_RENDERER_MANIFEST_SHA)" \
	  $(if $(ECHO_RENDERER_ROOT),--renderer-root "$(ECHO_RENDERER_ROOT)")

promote-renderer: ## Point the renderer selector at one verified package
	@PYTHONPATH=Scripts python3 -m echo_renderer.cli promote \
	  --source-sha "$(APPROVED_ECHO_PRONUNCIATION_SHA)" \
	  --manifest-sha "$(ECHO_RENDERER_MANIFEST_SHA)" \
	  $(if $(ECHO_RENDERER_ROOT),--renderer-root "$(ECHO_RENDERER_ROOT)")

repair-renderer: ## Quarantine and rebuild one renderer package identity
	@PYTHONPATH=Scripts python3 -m echo_renderer.cli repair \
	  --installer-worktree "$(CURDIR)" \
	  --installer-sha "$(APPROVED_ECHO_INSTALLER_SHA)" \
	  --source-worktree "$(ECHO_RENDERER_SOURCE)" \
	  --source-sha "$(APPROVED_ECHO_PRONUNCIATION_SHA)" \
	  --manifest-sha "$(ECHO_RENDERER_MANIFEST_SHA)" \
	  $(if $(ECHO_RENDERER_ROOT),--renderer-root "$(ECHO_RENDERER_ROOT)") \
	  $(if $(ECHO_BUILD_GATE),--build-gate "$(ECHO_BUILD_GATE)")
