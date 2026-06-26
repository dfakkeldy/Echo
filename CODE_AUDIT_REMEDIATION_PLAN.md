# CODE_AUDIT.md Remediation Plan

Generated: 2026-06-26
Source audit: `CODE_AUDIT.md`
Branch audited: `origin/nightly` at `d18af0394b0ca9d61ca56c7b3bd0e8c0fdd1ca36`
Implementation plan: `docs/superpowers/plans/2026-06-26-nightly-code-audit-remediation.md`

This file is the stable top-level pointer to the current remediation plan. The dated plan contains the full task-by-task checklist, files, acceptance criteria, and verification commands.

## Priority Order

1. **Unblock deterministic verification:** install/repair local CoreSimulator and Metal Toolchain, then rerun `make build-tests`, `make test`, and generic iOS build.
2. **Fix release determinism:** track `Package.resolved`, require `MATCH_GIT_SSH_KEY` for upload readiness, mirror capped build flags in release trains, and add the missing macOS privacy manifest.
3. **Resolve entitlement/metadata mismatch:** decide whether CarPlay ships now; align plist, entitlements, provisioning, help, metadata, and TestFlight copy.
4. **Fix data integrity:** replace delete/reinsert track refresh, port the APKG ID allocator to macOS, and stop collapsing persisted JSON corruption into empty/default data.
5. **Move heavy work off MainActor:** isolate pure DTW/tokenization helpers and make auto-alignment compute work run outside MainActor while keeping UI progress and DB writes isolated.
6. **Close accessibility reachability gaps:** Dynamic Type for reader text, import loading/error states, accessible PDF/transport/scrubber actions, gesture-only rows, and watch primary-action semantics.
7. **Reduce security/privacy risk:** prefer HTTPS for ABS, eliminate token query URLs where possible, fail closed for security-scoped bookmark Keychain failures, and verify privacy-manifest categories with an archive report.
8. **Expand CI coverage:** add watch tests or document manual coverage, include `echo-cli` if supported, strengthen privacy-manifest tests, and make screenshot completeness observable.

## Verification Baseline

- `xcodebuild -version`: Xcode 26.6 (`17F113`).
- `xcodebuild -list -project Echo.xcodeproj`: lists schemes but reports CoreSimulator `1051.54.0` is older than Xcode's required `1051.55.0`.
- `make build-tests`: blocked by simulator component mismatch and missing `iPhone 17` destination.
- Generic iOS build: reaches compilation, then fails because the local Metal Toolchain is not installed.
- Documentation-only PR verification: run `git diff --check`.

## Full Plan

Use `docs/superpowers/plans/2026-06-26-nightly-code-audit-remediation.md` for implementation. It is written as an agent-ready checklist with bounded slices and disjoint ownership:

- Phase 0: verification and dependency determinism
- Phase 1: release/signing/privacy manifest alignment
- Phase 2: data integrity and persistence correctness
- Phase 3: concurrency and performance isolation
- Phase 4: accessibility, UX feedback, localization
- Phase 5: ABS security/privacy and CloudKit trust model
- Phase 6: CI, release automation, and coverage expansion

Each phase should end with the relevant tests plus a full build gate once V1/V2 are fixed.
