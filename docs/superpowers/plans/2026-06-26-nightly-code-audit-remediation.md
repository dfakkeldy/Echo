# Nightly Code Audit Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` for independent slices, or `superpowers:executing-plans` for single-agent execution. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remediate the June 26 nightly audit findings from `CODE_AUDIT.md` while preserving the current release ladder (`feature/* -> nightly -> weekly -> main`) and current deployment targets unless the deployment-target decision task explicitly changes them.

**Audit Baseline:** `origin/nightly` at `d18af0394b0ca9d61ca56c7b3bd0e8c0fdd1ca36`, audited in `codex/nightly-code-audit-20260626`.

**Tech Stack:** Swift 6, SwiftUI, GRDB, Swift Testing/XCTest, Xcode project targets for iOS/macOS/watchOS/widget/CLI, GitHub Actions, Fastlane.

## Global Constraints

- Open implementation PRs against `nightly`, not `main`.
- Preserve current deployment targets until Task 1.5 is explicitly decided: iOS 18.0, macOS 15.0, watchOS 11.0.
- Preserve current Swift settings: `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- Do not introduce third-party frameworks.
- Do not run concurrent `xcodebuild` jobs. Use `-parallel-testing-enabled NO` and bounded `-jobs`.
- Prefer tests before code changes for data integrity, import behavior, and export ID allocation.
- For UI/accessibility work, verify Dynamic Type, VoiceOver/custom actions, and keyboard/Switch Control reachability where feasible.
- Keep unrelated refactors out of remediation PRs.

---

## Phase 0: Verification and Dependency Determinism

### Task 0.1: Repair the local build/test gate

**Findings:** V1, V2

**Files:** none expected unless Makefile destinations need updating after environment repair.

- [ ] Install or repair the Xcode/macOS simulator components so CoreSimulator matches Xcode 26.6 (`1051.55.0` or newer).
- [x] Install the Metal Toolchain locally with `xcodebuild -downloadComponent MetalToolchain`, or document that local Metal compilation is intentionally CI-only.
- [ ] Verify a valid iOS simulator destination exists for the Makefile's configured `IOS_DESTINATION`.
- [ ] Run `make build-tests`.
- [ ] Run `make test`.
- [x] Run generic iOS build:

```bash
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -jobs 5
```

**Acceptance criteria:** simulator test build and test commands no longer fail because of host toolchain mismatch; any remaining failures are actionable source/test failures.

### Task 0.2: Track SwiftPM dependency resolution

**Finding:** H8

**Files:**
- Modify: `.gitignore`
- Add: `Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release-trains.yml`

- [x] Replace the blanket `.gitignore` rule for `Package.resolved` with a scoped exception for the Xcode workspace lockfile.
- [x] Resolve packages once with Xcode 26.6 and commit the generated workspace `Package.resolved`.
- [x] Confirm `git check-ignore` no longer ignores the committed lockfile.
- [x] Consider adding `-onlyUsePackageVersionsFromResolvedFile` to CI/release package resolution after the lockfile is tracked.

**Verification:**

```bash
git check-ignore -v Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -resolvePackageDependencies -project Echo.xcodeproj -scheme Echo
```

**Acceptance criteria:** package versions used in local, CI, and release trains are reproducible from source control.

---

## Phase 1: Release, Signing, and App Store Metadata

### Task 1.1: Add macOS privacy manifest coverage

**Finding:** H6

**Files:**
- Add: `Echo macOS/PrivacyInfo.xcprivacy`
- Modify: `Echo.xcodeproj/project.pbxproj` if target membership is not automatic through synchronized groups
- Modify: `EchoTests/PrivacyManifestTests.swift`

- [x] Add a macOS privacy manifest declaring `NSPrivacyAccessedAPICategoryUserDefaults` with reasons matching standard/app-group usage.
- [x] Ensure the file is included in the `Echo macOS` target.
- [x] Extend privacy-manifest tests so every shipping target with required-reason API use is enumerated.
- [x] Add a test assertion that the macOS manifest exists and declares UserDefaults reasons.

**Verification:** `make test` or targeted privacy manifest tests after Phase 0 is unblocked.

**Acceptance criteria:** iOS, macOS, watch, and widget manifests are present and tested.

### Task 1.2: Fix release-train signing readiness

**Finding:** H9

**Files:**
- Modify: `.github/workflows/release-trains.yml`
- Review: `fastlane/Matchfile`

- [x] Require `MATCH_GIT_SSH_KEY` in the `ready=true` gate when `Matchfile` uses SSH.
- [x] Update the skipped-upload notice to list all missing signing inputs.
- [x] Keep the deploy-key load conditional aligned with the readiness output.
- [x] Keep SSH match auth; no `Matchfile` HTTPS/token switch is needed.

**Acceptance criteria:** scheduled runs without the deploy key compile only and do not start a doomed Fastlane upload.

### Task 1.3: Mirror capped CI build flags in release trains

**Finding:** M16

**Files:**
- Modify: `.github/workflows/release-trains.yml`
- Modify: `fastlane/Fastfile`

- [x] Add `-parallel-testing-enabled NO` and `-jobs 5` to the release-train `xcodebuild build-for-testing` command.
- [x] Keep flags consistent with `.github/workflows/ci.yml`.
- [x] Pass `-jobs 5` through Fastlane archive `build_app` invocations used by credentialed release-train uploads.

**Acceptance criteria:** scheduled release-train build behavior matches PR build-gate resource limits.

### Task 1.4: Resolve CarPlay entitlement and metadata mismatch

**Finding:** H7

**Files if enabling CarPlay:**
- Modify: `EchoCore/EchoCore.entitlements`
- Update provisioning/App ID outside repo
- Verify: `EchoCore/Info.plist`, `EchoCore/CarPlay/*`, `fastlane/metadata/en-US/keywords.txt`, `fastlane/testflight/what_to_test.txt`, `EchoCore/Views/HelpContent.swift`

**Files if deferring CarPlay:**
- Modify: `EchoCore/Info.plist`
- Modify: `fastlane/metadata/en-US/keywords.txt`
- Modify: `fastlane/testflight/what_to_test.txt`
- Modify: `EchoCore/Views/HelpContent.swift`
- Optionally conditionally compile or remove exposed CarPlay scene code

- [ ] Decide whether CarPlay ships in the next nightly/weekly train.
- [ ] If shipping, enable entitlement and regenerate profiles before merging metadata that advertises CarPlay.
- [ ] If deferring, remove the scene declaration and all user/tester marketing claims until entitlement approval exists.
- [ ] Add a release checklist item that validates CarPlay entitlement/profile state against metadata.

**Acceptance criteria:** plist, entitlements, provisioning, help, keywords, and TestFlight copy all describe the same shipped feature set.

### Task 1.5: Decide deployment-target source of truth

**Finding:** M11

**Files:**
- Modify one side of the mismatch:
  - Project/package targets: `Echo.xcodeproj/project.pbxproj`, `ThirdParty/MisakiSwift/Package.swift`
  - Or docs/guidance: `AGENTS.md`, `README.md`, `ARCHITECTURE.md` if applicable

- [ ] Make an explicit product call: keep iOS 18/macOS 15/watchOS 11 or raise to iOS 19/macOS 16/watchOS 12.
- [ ] If raising targets, update every app/test/package target together and run full build/test gates.
- [ ] If preserving current targets, correct README badges and agent guidance so contributors do not use newer APIs accidentally.

**Acceptance criteria:** project settings and docs agree on supported OS floors.

### Task 1.6: Fix `echo-cli` Cocoa framework SDK reference

**Finding:** M12

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj`
- Consider: `.github/workflows/ci.yml`

- [x] Replace the `MacOSX15.0.sdk` hardcoded framework path with an SDKROOT-relative Cocoa framework reference, or remove the link if unused.
- [x] Build the `echo-cli` scheme locally.
- [x] If `echo-cli` is supported, add it to CI as a serial build job.

**Verification:**

```bash
xcodebuild build -project Echo.xcodeproj -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -jobs 5
```

**Acceptance criteria:** `echo-cli` builds under Xcode 26.6 without stale SDK paths.

---

## Phase 2: Data Integrity and Persistence Correctness

### Task 2.1: Replace track delete/reinsert refresh

**Finding:** H2

**Files:**
- Modify: `EchoCore/Services/TimelineIngestionService.swift`
- Modify: `Shared/Database/DAOs/TrackDAO.swift`
- Possibly add migration: `Shared/Database/Migrations/Schema_V27.swift`
- Modify migration registry as needed
- Add/modify tests under `EchoTests`

- [ ] Write a regression test that creates an audiobook with tracks, a bookmark with `track_id`, and a playback event with `track_id`, then refreshes/reingests the book.
- [ ] Replace `deleteAll(for:)` before insert with transactional upsert-by-track-ID.
- [ ] Delete obsolete tracks only after dependents are remapped or nulled.
- [ ] If schema change is chosen, migrate `bookmark.track_id` and `playback_event.track_id` to `ON DELETE SET NULL` safely.
- [ ] Ensure failed refresh cannot leave metadata updated while tracks remain stale.

**Acceptance criteria:** reingesting a book after bookmarks/playback events succeeds without FK failure and preserves dependent history.

### Task 2.2: Port APKG monotonic ID allocation to macOS

**Finding:** H1

**Files:**
- Modify: `Echo macOS/Services/MacApkgExportService.swift`
- Add/modify tests under `EchoTests` or a macOS-capable test target

- [x] Extract or mirror the iOS monotonic ID allocation used in `ApkgExportService`.
- [x] Remove `hashValue % 1000` and wall-clock-per-card ID derivation from macOS export.
- [x] Add a regression test that exports enough cards to exercise same-millisecond allocation.
- [x] Confirm note IDs and card IDs are unique and non-overlapping.

**Acceptance criteria:** macOS APKG export never derives note/card IDs from randomized hash fragments.

### Task 2.3: Preserve diagnostics for DB JSON/Codable failures

**Finding:** M9

**Files:**
- Modify: `Shared/Database/EPubBlockRecord.swift`
- Modify: `Shared/Database/BookmarkRecord.swift`
- Add/modify tests under `EchoTests`

- [ ] Add tests for malformed marker/format JSON and malformed PDF bookmark state.
- [ ] Introduce throwing decode helpers or structured diagnostics that include row context.
- [ ] Return empty arrays only for absent optional values, not corrupt persisted values.
- [ ] Log privacy-safe corruption details and avoid silently replacing identity/state with empty defaults.

**Acceptance criteria:** corrupt persisted JSON is observable in logs/tests and not treated as intentionally empty data.

### Task 2.4: Tighten security-scoped bookmark persistence

**Finding:** M3

**Files:**
- Modify: `EchoCore/Services/Persistence.swift`
- Add/modify tests around Keychain failure behavior

- [ ] Remove release-build fallback that writes security-scoped bookmark data to `UserDefaults`.
- [ ] On Keychain save failure, fail closed and surface a reselect-folder requirement.
- [ ] During legacy migration, delete plaintext bookmark data only after successful Keychain write.
- [ ] If migration fails, do not continue using plaintext legacy bookmark data indefinitely.

**Acceptance criteria:** security-scoped bookmark grants are not newly written to plaintext defaults and legacy plaintext data has a bounded migration path.

---

## Phase 3: Concurrency and Performance Isolation

### Task 3.1: Move auto-alignment tokenization/DTW off MainActor

**Finding:** H3

**Files:**
- Modify: `EchoCore/Services/AutoAlignmentService.swift`
- Modify: `EchoCore/Services/TokenDTW.swift`
- Review: `EchoCore/Services/WordTimingMaterializer.swift` or related pure helpers
- Add/modify tests under `EchoTests`

- [ ] Identify pure value types used by DTW/tokenization and mark them `nonisolated` where appropriate.
- [ ] Make DTOs crossing isolation boundaries conform to `Sendable`.
- [ ] Extract per-chapter tokenization and DTW into a background worker boundary.
- [ ] Keep UI progress updates, model state, and DB commits on MainActor.
- [ ] Add cancellation checks around long-running per-chapter work.
- [ ] Add signposts or a long-chapter performance test to confirm MainActor remains responsive.

**Acceptance criteria:** long auto-alignment work no longer runs under MainActor isolation, and strict concurrency remains clean.

### Task 3.2: Tie PDF loading to SwiftUI task lifetime

**Finding:** M10

**Files:**
- Modify: `EchoCore/Views/PDFDocumentView.swift`

- [x] Replace `Task.detached` launched from `makeUIView` with `.task(id: folderURL)` from the SwiftUI owner, or store/cancel an owned task in the representable coordinator.
- [x] Do background file discovery using Sendable values.
- [x] Construct and assign `PDFDocument` on MainActor unless PDFKit sendability is documented and validated.
- [x] Prevent stale folder loads from overwriting current state.

**Acceptance criteria:** PDF loading cancels or becomes stale-safe when `folderURL` or view identity changes.

### Task 3.3: Replace legacy sleeps and non-cancellable GCD delays

**Findings:** Low concurrency findings

**Files:**
- Modify: `Echo macOS/Services/MacAlignmentService.swift`
- Modify: `EchoCore/Services/DefaultChimePlayer.swift`
- Modify: `EchoCore/Views/ReaderTab+Alignment.swift`

- [x] Replace `Task.sleep(nanoseconds:)` with `Task.sleep(for:)`.
- [x] Replace `DispatchQueue.main.asyncAfter` pulse reset with an owned cancellable `Task`.
- [x] Ensure view/model lifetime cancels delayed work where appropriate.

**Acceptance criteria:** no production `Task.sleep(nanoseconds:)` remains, and manual alignment pulse reset is structured/cancellable.

---

## Phase 4: Accessibility, UX Feedback, and Localization

### Task 4.1: Make reader body text Dynamic Type compliant

**Finding:** H4

**Files:**
- Modify: `Shared/ReaderSettings.swift`
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift`
- Modify: `EchoCore/Views/Cells/ParagraphCardCell.swift`
- Review: `EchoCore/Views/Cells/HeadingCardCell.swift`

- [ ] Scale reader fonts through `UIFontMetrics(forTextStyle:)`.
- [ ] Enable `adjustsFontForContentSizeCategory` for paragraph labels.
- [ ] Rebuild attributed text when content-size category changes.
- [ ] Verify line spacing and attributed bold/highlight runs preserve scaled base fonts.
- [ ] Test at accessibility Dynamic Type sizes and ensure reader cells do not clip body text.

**Acceptance criteria:** reader body and heading text scale with system Larger Text without clipping core content.

### Task 4.2: Surface EPUB/PDF import loading and errors

**Finding:** H5

**Files:**
- Modify: `EchoCore/Views/RootTabView.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Bookmarks.swift`
- Modify: `EchoCore/Services/EPUBImportCoordinator.swift`
- Modify: `EchoCore/Services/PDFImportCoordinator.swift`
- Add/modify tests under `EchoTests`

- [ ] Make import coordinators return a typed success/failure result or throw typed errors.
- [ ] Preserve the underlying cause for permission, copy, parse, and scanner failures.
- [ ] Add loading and error presentation in `RootTabView`.
- [ ] Refresh reader state only after successful import.
- [ ] Add tests for failed coordinator paths and unsupported/denied file imports.

**Acceptance criteria:** users get visible feedback for document import progress and failure.

### Task 4.3: Add accessible alternatives for PDF, transport, and scrubber actions

**Findings:** M5, M6, M7

**Files:**
- Modify: `EchoCore/Views/PDFDocumentView.swift`
- Modify: `EchoCore/Views/TransportControlsView+LongPress.swift`
- Modify: `EchoCore/Views/ScrubberJoystick.swift`

- [ ] Add visible toolbar/menu actions for PDF align/bookmark operations.
- [ ] Add `UIAccessibilityCustomAction` or SwiftUI `.accessibilityAction` equivalents for PDF operations.
- [ ] Add named accessibility actions for transport secondary actions.
- [ ] Add `.accessibilityAdjustableAction` and named step actions for the scrubber joystick.
- [ ] Verify VoiceOver can discover and perform every action without custom gestures.

**Acceptance criteria:** no primary reader/PDF/transport/alignment action is available only through long press or drag.

### Task 4.4: Replace gesture-only selectable rows with semantic controls

**Finding:** M8

**Files:**
- Modify: `EchoCore/Views/SoundscapePickerView.swift`
- Modify: `EchoCore/Views/ChimeSettingsView.swift`
- Modify: `Echo macOS/Views/MacTOCTreeView.swift`
- Modify: `Echo macOS/Views/MacReaderFeedView.swift`

- [ ] Convert row taps to `Button`, `NavigationLink`, or selection controls.
- [ ] Use plain styles to preserve visual design without losing semantics.
- [ ] Add keyboard shortcuts/focus behavior where macOS usage warrants it.

**Acceptance criteria:** selectable rows are announced as actionable controls and remain keyboard reachable.

### Task 4.5: Fix watch primary action semantics

**Finding:** Low watch accessibility

**Files:**
- Modify: `Echo Watch App/Views/PlayerPage.swift`

- [x] Replace the hidden blank `Button("")` primary-action bridge with a visible/tappable primary action where possible.
- [x] If a hidden bridge is unavoidable, give it a proper accessibility label or hide it from accessibility while preserving Double Tap behavior.
- [x] Ensure there is only one `handGestureShortcut(.primaryAction)` per watch surface.

**Acceptance criteria:** Double Tap remains an accelerator, not the only path, and VoiceOver does not encounter a blank hidden button.

### Task 4.6: Localize action/error strings and modernize formatting

**Findings:** M17, M18

**Files:**
- Modify: `Localizable.xcstrings` if present in the target structure
- Modify: `EchoCore/Views/ReaderTab+Alignment.swift`
- Modify: `EchoCore/Views/PDFDocumentView.swift`
- Modify: `EchoCore/Views/ABSConnectionsSettingsView.swift`
- Modify: `EchoCore/Models/SpeedSuggestion.swift`
- Modify: `EchoCore/Views/SessionsListView.swift`
- Modify: `EchoCore/Views/SessionDetailFeedView.swift`
- Modify: `EchoCore/Views/ReaderSettingsSheet.swift`

- [ ] Add catalog keys for user-visible UIKit/accessibility action names and ABS errors.
- [ ] Use `String(localized:)` or generated symbol keys for non-SwiftUI strings.
- [ ] Replace `DateFormatter`, `String(format:)`, and ad hoc measurement strings with `FormatStyle` and localized placeholders/plurals.
- [ ] Test with a non-US locale.

**Acceptance criteria:** user-visible action/error/formatting strings are localizable and locale-aware.

---

## Phase 5: ABS Security, Privacy, and CloudKit Trust

### Task 5.1: Make plaintext ABS connections explicit and safer

**Finding:** M1

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift`
- Modify: `EchoCore/Views/ABSConnectionsSettingsView.swift`
- Review: `EchoCore/Info.plist`, `Echo macOS/Info.plist`, `ARCHITECTURE.md`

- [ ] Default bare hosts to HTTPS or require the user to choose HTTP explicitly.
- [ ] Add an explicit confirmation before sending credentials over HTTP.
- [ ] Show persistent insecure-server state after connection.
- [ ] Keep self-signed HTTPS trust-on-first-use as the recommended local path.
- [ ] Document the ATS exception rationale and App Review notes.

**Acceptance criteria:** the app no longer silently sends ABS credentials over plaintext because a user omitted the scheme.

### Task 5.2: Remove token-bearing ABS URLs where headers can be used

**Finding:** M2

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift`
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Modify cover/image UI that currently needs self-contained URLs

- [ ] Build an authenticated image/download loader that uses `Authorization` headers.
- [ ] Stop app-owned downloads from using `?token=` URLs.
- [ ] Keep query-token support only behind a narrow helper for ABS endpoints that cannot accept headers.
- [ ] Ensure token-bearing URLs are not logged or cached.

**Acceptance criteria:** access tokens are not embedded in URLs for normal app-owned cover/download flows.

### Task 5.3: Make ABS token lifecycle failure states explicit

**Finding:** M4

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`
- Add/modify tests around failed connect and sign-out

- [ ] Roll back tokens on any server-record save failure, not only when a cert pin exists.
- [ ] Differentiate local token clearing from remote refresh-token revoke failure.
- [ ] Add retry/backoff or a user-visible "remote sign-out failed" state.
- [ ] Add privacy-safe logging for sync/auth health.

**Acceptance criteria:** UI state and Keychain/server token state cannot diverge silently after failed connect/sign-out.

### Task 5.4: Decide and harden CloudKit anchor trust model

**Finding:** M15

**Files:**
- Modify: `EchoCore/Services/CloudKitSyncService.swift`
- Modify docs/architecture as needed
- Add/modify CloudKit-related tests where feasible

- [ ] Decide whether shared anchors remain in public DB or move to private/shared DB.
- [ ] If public remains, add author attribution, payload size limits, upload rate limits, and abuse recovery.
- [ ] Keep local block-ID validation and synthesized-anchor filtering.
- [ ] Document the chosen trust model in `ARCHITECTURE.md`.

**Acceptance criteria:** CloudKit anchor sync has an explicit abuse/control model, not only local merge validation.

### Task 5.5: Verify file metadata privacy-manifest category

**Finding:** M14

**Files:**
- Modify: `EchoCore/Services/Narration/OnnxKokoroEngine.swift` or manifests/tests depending on decision
- Modify: `EchoCore/PrivacyInfo.xcprivacy`
- Modify: `EchoTests/PrivacyManifestTests.swift`

- [ ] Produce an archive privacy report under Xcode 26.6.
- [x] Determine whether `attributesOfItem(atPath:)` for `.size` triggers a required-reason API category.
- [x] Prefer replacing it with a non-flagged length read if practical.
- [x] Because the broad API was replaced, add regression coverage that prevents reintroducing it.

**Acceptance criteria:** privacy manifest coverage matches Xcode archive validation, not only hand-maintained expectations.

---

## Phase 6: CI, Release Automation, and Coverage Expansion

### Task 6.1: Add watch test coverage to CI or document manual status

**Finding:** M13

**Files:**
- Modify: `.github/workflows/ci.yml`
- Possibly modify: `README.md`

- [x] Defer a serial watchOS unit-test job for `Echo Watch AppTests` until a pinned watch destination is reliable on GitHub runners.
- [x] Keep UI tests manual unless simulator reliability and runtime cost are acceptable.
- [x] If not adding CI coverage, update README/release checklist to state watch tests are manual and list the command.

**Acceptance criteria:** watch test status is no longer ambiguous.

### Task 6.2: Decide whether macOS archive failure should block beta lane

**Finding:** Low release finding

**Files:**
- Modify: `fastlane/Fastfile`

- [ ] Decide whether weekly/release trains must block on macOS archive failures.
- [ ] If yes, remove or scope the rescue wrapper so nightly can continue only when intended but weekly/release fails.
- [ ] If no, emit a GitHub warning/summary that is visible in required checks.

**Acceptance criteria:** macOS release failures are either blocking or clearly visible by release channel.

### Task 6.3: Make screenshot completeness observable

**Finding:** Low screenshot finding

**Files:**
- Modify: `fastlane/Snapfile`
- Modify: `EchoUITests/EchoScreenshots.swift`
- Modify: `fastlane/screenshots/en-US/README_SCREENSHOTS.md`
- Add sanitized fixture or generated sample if approved

- [ ] Add an assertion/report that expected screenshot categories are present.
- [ ] Provide a small sanitized/generated fixture path for repeatable screenshots if permitted.
- [ ] Track Watch/Mac/manual shots explicitly in the release checklist.

**Acceptance criteria:** screenshot automation cannot silently pass with a materially incomplete marketing set.

### Task 6.4: Clean stale Fastlane metadata/config TODOs

**Finding:** Low config finding

**Files:**
- Modify: `fastlane/Fastfile`
- Modify: `fastlane/Appfile`
- Review: `fastlane/metadata/*`

- [x] Remove stale `com.orbit.*` TODOs if all bundle IDs are already `com.echo.*`.
- [x] Remove or document empty `apple_id("")` in version-controlled Fastlane config.
- [x] Confirm no secret values are introduced.

**Acceptance criteria:** release automation comments/config no longer imply unfinished rebrand or secret-management work that is already resolved.

---

## Cross-Phase Final Verification

Run after each implementation PR if the phase touches source/build config, and after all phases before promotion:

```bash
git diff --check
make build-tests
make test
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme Echo \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -jobs 5
xcodebuild build \
  -project Echo.xcodeproj \
  -scheme "Echo macOS" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -jobs 5
```

Additional targeted checks by phase:

- Privacy: archive privacy report and `EchoTests/PrivacyManifestTests`.
- Accessibility: VoiceOver pass, Dynamic Type at accessibility sizes, keyboard/Switch Control reachability for changed controls.
- Release: dry-run or compile-only scheduled workflow path with missing signing secrets and with all signing secrets.
- ABS: HTTP warning flow, self-signed HTTPS trust flow, token refresh/sign-out failure tests.
- Data: migration tests and regression tests for track refresh, APKG export IDs, and corrupt JSON.

## Stop Conditions

- Do not raise deployment targets as a side effect of unrelated fixes.
- Do not merge CarPlay marketing/plist changes unless entitlement/provisioning state matches.
- Do not claim Larger Text, VoiceOver, or Reduced Motion App Store accessibility labels until those paths are tested.
- Do not proceed with release upload if signing readiness is incomplete.
