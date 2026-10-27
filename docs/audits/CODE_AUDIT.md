# Echo Code Audit

Generated: 2026-07-02
Branch audited: `origin/nightly` at `2df6d205d32c`
Audit worktree: `/Users/dfakkeldy/.codex/worktrees/echo-code-audit-20260702`
Toolchain observed locally: Xcode 26.6 (`17F113`), Apple Swift 6.3.3, Swift language mode 6.0.

Scope: production Swift, SwiftUI/UIKit bridge surfaces, GRDB persistence, import/alignment flows, AI provider configuration, release/CI configuration, tests, privacy manifests, macOS/watch/widget/CLI entry points, and high-change reader/library/narration areas. This report replaces the prior top-level `CODE_AUDIT.md`; source comments that cite old audit section numbers should be treated as historical breadcrumbs, not stable identifiers.

Method: clean worktree cut from freshly fetched `origin/nightly`, repo docs and build settings inspected, package/project targets enumerated, `xcodebuild build-for-testing` run, targeted `rg` passes for concurrency, security, formatting, SwiftUI API drift, oversized files, direct database access, secrets, TODO/FIXME markers, and manual verification of each high/medium claim against current source.

Summary: no Critical findings. Current nightly builds for testing locally and is substantially hardened compared with the older audit report in the repo: privacy manifests exist for shipping targets, the release train checks all signing secrets, the companion document importer surfaces errors, CarPlay entitlement/plist drift has been reduced, and reader Dynamic Type support has improved. The remaining risk clusters are MainActor-bound data work, document alignment data integrity, custom AI endpoint transport, reader-feed scaling, sensitive bookmark storage, and audit/process drift.

## 1. Executive Summary

### 1.1 Severity summary

| Severity | Count | Notes |
| --- | ---: | --- |
| Critical | 0 | No confirmed broad crash, credential leak, or guaranteed data-loss path. |
| High | 5 | Fix before widening TestFlight use of the affected features. |
| Medium | 10 | Important correctness, privacy, performance, or maintainability issues. |
| Low | 12 | Quick wins, warnings, style cleanup, and process hygiene. |

### 1.2 Top risks

1. Library rescans still do recursive filesystem discovery, metadata work, cover writes, and per-book GRDB writes from `@MainActor` UI flows.
2. Document import finalization can delete human alignment anchors in non-sidecar paths and can report success after swallowing anchor/timeline persistence failures.
3. AI provider settings promise HTTPS, but custom base URLs only require "some scheme"; book text and API tokens can be sent over plain HTTP.
4. Reader feed reload rebuilds the whole book, timeline, word timings, notes, and memos synchronously on the main actor, including after adding one note or voice memo.
5. User-created bookmark JSON, including private notes and voice memo metadata, remains in unencrypted `UserDefaults` despite a local security note calling this out.
6. Direct sync GRDB access remains easy from main-actor services because `DatabaseService.writer` and sync read/write wrappers are public to the app.
7. Several build warnings are test-only today, but they prove the gate still tolerates warning drift.
8. Formatting/localization enforcement covers only seven hand-picked files while user-visible `String(format:)` and formatter usage remains elsewhere.
9. Audit section numbers have leaked into source comments, so replacing `CODE_AUDIT.md` can make those references misleading.
10. The largest app models/views remain over 1,000 lines and concentrate playback, reader, watch, and macOS responsibilities in files that are hard to audit incrementally.

### 1.3 Positive findings

- The current branch has explicit Swift 6 settings, strict concurrency, approachable concurrency, and MainActor default isolation in the Xcode project (`Echo.xcodeproj/project.pbxproj:1621-1635`, `1666-1680`, and analogous target settings).
- Privacy manifests now exist for iOS, macOS, watch, and widget targets (`EchoCore/PrivacyInfo.xcprivacy`, `Echo macOS/PrivacyInfo.xcprivacy`, `Echo Watch App/PrivacyInfo.xcprivacy`, `Echo Widget/PrivacyInfo.xcprivacy`).
- The release-train workflow now checks all three upload secrets, including `MATCH_GIT_SSH_KEY`, before attempting upload (`.github/workflows/release-trains.yml:184-197`).
- The companion document importer now has loading and error UI instead of swallowing picker/import errors (`EchoCore/Views/RootTabView.swift:465-486`, `606-647`).
- Reader text cells now use `UIFontMetrics`, `adjustsFontForContentSizeCategory`, and trait-change rebuilds (`Shared/ReaderSettings.swift:77-87`, `EchoCore/Views/Cells/ParagraphCardCell.swift:19`, `90-94`).

## 2. Quick Wins

### 2.1 Remove the remaining compiler warning in `StandaloneTranscriptionServiceTests`

Severity: Low

Evidence: local `xcodebuild build-for-testing` warns that `EchoTests/StandaloneTranscriptionServiceTests.swift:253` has no async work inside an `await`; the line is `try await TranscriptMaterializer.materialize(...)` (`EchoTests/StandaloneTranscriptionServiceTests.swift:246-253`).

Impact: warning-only, but this erodes the signal from the build gate.

Remediation: remove the redundant `await` if the callee is synchronous, or make the callee genuinely async if that was intended. Add a warning-free expectation to CI if practical.

### 2.2 Replace deprecated trait override API in reader accessibility tests

Severity: Low

Evidence: local build warns that `setOverrideTraitCollection(_:forChild:)` is deprecated; the test uses it at `EchoTests/ReaderFeedAccessibilityTests.swift:192` and clears it at `EchoTests/ReaderFeedAccessibilityTests.swift:202`.

Impact: warning-only now, but this test is exactly where Dynamic Type/layout regression signal matters.

Remediation: switch the test harness to `traitOverrides` on the child view controller and keep the same measurement assertions.

### 2.3 Update the obvious SwiftUI modifier drift

Severity: Low

Evidence: `SpeedCardView` formats speed with `String(format:)` and uses `.fontWeight(.bold)` (`EchoCore/Views/SpeedCardView.swift:18-20`). Horizontal scroll views still use `showsIndicators: false` in `EchoCore/Views/ReaderTab.swift:657` and `EchoCore/Views/DashboardShelf.swift:34`.

Impact: not a functional bug, but it conflicts with the repo's SwiftUI guidance and keeps producing small review churn.

Remediation: use `Text(model.speed, format: .number.precision(.fractionLength(2)))`, `.bold()` where the exact weight is not required, and `.scrollIndicators(.hidden)`.

### 2.4 Stop using audit section numbers as durable code-comment references

Severity: Low

Evidence: production and CI comments reference mutable `CODE_AUDIT.md` sections, for example `EchoCore/ViewModels/PlayerModel.swift:1035`, `EchoCore/Services/AutoAlignmentService.swift:95`, `EchoCore/CarPlay/CarPlayManager.swift:141`, and `.github/workflows/ci.yml:125`.

Impact: this report supersedes the old top-level audit, so those references can become wrong even when the surrounding code remains correct.

Remediation: replace section-number references with issue IDs, PR numbers, dated audit filenames, or short inline explanations.

### 2.5 Keep formatter/localization guardrails from staying opt-in

Severity: Low

Evidence: `LocalizationFormattingTests` checks only seven explicitly listed files (`EchoTests/LocalizationFormattingTests.swift:7-21`) even though app/watch/macOS surfaces still contain `String(format:)`, `DateFormatter`, and `ISO8601DateFormatter` usage.

Impact: the test gives a false sense that the repo is broadly protected against locale-unaware formatting.

Remediation: turn the test into an allowlist/denylist scan by target area. Start with user-facing SwiftUI views and exclude hashes, protocol formats, and test fixture timestamps intentionally.

## 3. Concurrency

### 3.1 Library rescans run blocking filesystem and database work from MainActor flows

Severity: High

Evidence: `LibraryService` is `@MainActor` (`EchoCore/Services/Library/LibraryService.swift:70-71`). The sync rescan does recursive discovery and per-book DAO reads/writes from that isolation (`LibraryService.swift:136-143`, `150-180`). The metadata rescan creates cover directories, discovers books, reads metadata, writes covers, and saves each book in the same main-actor service (`LibraryService.swift:212-223`, `251-271`). The scanner uses synchronous recursive `FileManager` enumeration (`EchoCore/Services/Library/LibraryScanner.swift:25-43`) and synchronous folder listing for artwork (`LibraryScanner.swift:127-154`). UI view models call this path directly while presenting scanning state (`EchoCore/ViewModels/LibraryViewModel.swift:109-118`, `EchoCore/ViewModels/LibraryRootsViewModel.swift:39-51`, `EchoCore/ViewModels/PlayerModel.swift:1210-1218`).

Impact: adding or rescanning a large library can freeze the UI, delay gestures, and make cancellation ineffective. The inline `FIXME(M3)` already identifies the same root problem (`LibraryService.swift:142`, `220`).

Remediation: move discovery, metadata reads, cover writes, and upsert planning behind a non-main worker or actor. Return a `Sendable` rescan delta, then apply batched DB writes through `writeAsync` in transactions. Keep security-scope lifetime explicit, add cancellation checks between books, and add a stress test with hundreds/thousands of fake discovered books.

### 3.2 `DatabaseService` still makes synchronous main-actor database access the path of least resistance

Severity: Medium

Evidence: `DatabaseService` is `@MainActor @Observable` and exposes `let writer: DatabaseWriter` (`Shared/Database/DatabaseService.swift:18-21`). It provides sync `read`/`write` wrappers (`DatabaseService.swift:97-111`) alongside async wrappers (`DatabaseService.swift:104-117`). Main-actor callers bypass the async wrappers through direct `db.writer.read` or sync `db.read`, for example `LibraryService.books` (`EchoCore/Services/Library/LibraryService.swift:338-345`), `LibraryService.statusMap` (`LibraryService.swift:423-461`), and `ReaderFeedViewModel.reload` (`EchoCore/ViewModels/ReaderFeedViewModel.swift:420-431`).

Impact: individual call sites look harmless, but the service API does not encode the rule "large reads/writes must not block MainActor." As features grow, this pattern keeps reappearing in UI-owned models.

Remediation: narrow direct writer exposure, name sync APIs as explicitly blocking, and add nonisolated async DAO surfaces for app code. Do not rewrite all DAOs at once; start with library rescan and reader reload, then codify the convention with tests or lint-like source checks.

### 3.3 CarPlay still reaches app state through a static weak `PlayerModel`

Severity: Medium

Evidence: `EchoCoreApp` exposes `@MainActor static weak var playerModel: PlayerModel?` for non-SwiftUI contexts, with a `REFACTOR-TODO` to replace it (`EchoCore/EchoCoreApp.swift:21-29`). `CarPlayManager` reads that global from library, chapter, and bookmark paths (`EchoCore/CarPlay/CarPlayManager.swift:132-139`, `219-224`, `273-280`).

Impact: single-scene assumptions are encoded globally. If iPad/macOS multi-window support expands, or if lifecycle timing changes, CarPlay can see a nil/stale/wrong model without compile-time help.

Remediation: introduce a tiny `@MainActor` playback registry or app coordinator keyed by scene/session, inject it into the CarPlay scene delegate, and keep `PlayerModel` lookup explicit. This does not need a broad PlayerModel rewrite.

### 3.4 Warning drift is still allowed into tests

Severity: Low

Evidence: the local build emitted two test-source warnings: the redundant `await` in `StandaloneTranscriptionServiceTests` and the deprecated trait override calls in `ReaderFeedAccessibilityTests`.

Impact: warnings are not release blockers, but they make it harder to notice new Swift 6 or SDK migration warnings.

Remediation: clear the current warnings and consider making CI fail on warnings for `EchoTests` once the existing baseline is zero.

## 4. API Modernity

### 4.1 Locale-aware formatting enforcement is narrower than the app surface

Severity: Medium

Evidence: `LocalizationFormattingTests` scans only seven files (`EchoTests/LocalizationFormattingTests.swift:7-21`). User-visible or near-user-visible formatting still appears elsewhere: `SpeedCardView` uses `String(format: "%.2f×", model.speed)` (`EchoCore/Views/SpeedCardView.swift:18`), the daily planner formats speed with C-style strings (`EchoCore/DailyPlanner/RealTimeProjectionService.swift:103`), and watch player time formatting uses `String(format:)` (`Echo Watch App/Views/PlayerPage.swift:333-337`).

Impact: Dutch/non-US locale support can regress outside the protected reader files, especially in dashboard/watch/planner surfaces.

Remediation: convert user-facing values to `FormatStyle`/`Duration`/`Measurement` APIs and make the test scan target-specific globs with explicit exemptions for hashes, filenames, and protocol wire formats.

### 4.2 Test code still uses a deprecated iOS 17 API

Severity: Low

Evidence: `ReaderFeedAccessibilityTests` uses `setOverrideTraitCollection(_:forChild:)` at `EchoTests/ReaderFeedAccessibilityTests.swift:192` and `202`, which the Xcode 26.6 build reports as deprecated.

Impact: low functional risk, but the test exercises a high-value accessibility path and should remain aligned with current UIKit behavior.

Remediation: update the harness to use `traitOverrides`.

### 4.3 `AnyView` remains in a shared styling helper

Severity: Low

Evidence: `EchoCore/Utilities/ViewModifiers.swift:29-31` uses `AnyView` to switch between font styles.

Impact: this is probably harmless, but it is a visible exception to the repo's SwiftUI guidance and can hide type-level layout differences from the compiler.

Remediation: replace the helper with a concrete `ViewModifier` or split the style cases into concrete branches at call sites when next touched.

## 5. Bugs / Logic Errors

### 5.1 CloudKit/fallback import finalization can delete human alignment anchors

Severity: High

Evidence: the sidecar import branch explicitly preserves user-placed/human anchors by deleting only non-human sources (`EchoCore/Services/DocumentImportFinalizer.swift:60-71`). The CloudKit branch deletes all anchors for the book before upserting downloaded anchors (`DocumentImportFinalizer.swift:100-105`). The first/last fallback branch also deletes all anchors (`DocumentImportFinalizer.swift:134-137`).

Impact: re-importing a document without an alignment sidecar can destroy manual alignment work that the sidecar path deliberately protects. The same finalizer is also called by `finalizeExistingImportIfAlignmentSidecarPresent` after loading existing blocks (`DocumentImportFinalizer.swift:162-190`), so import/finalization reuse should be conservative about existing user work.

Remediation: centralize anchor replacement policy. Preserve human sources in all branches, prune only anchors whose block IDs no longer exist, and add regression tests for "existing human anchor + CloudKit anchors" and "existing human anchor + fallback anchors."

### 5.2 Import finalization swallows anchor and timeline persistence failures but returns success

Severity: High

Evidence: CloudKit download failure is collapsed to an empty anchor array (`DocumentImportFinalizer.swift:88-93`). CloudKit upsert and timeline recalculation use `try?` (`DocumentImportFinalizer.swift:100-105`). Fallback anchor deletion/upsert/recalculation also uses `try?` (`DocumentImportFinalizer.swift:134-147`). The method posts `.timelineItemsIngested` and returns `true` regardless (`DocumentImportFinalizer.swift:151-159`).

Impact: an import can appear successful while read-along/timeline state is missing or stale. Users see a document in the reader but alignment controls, badges, or timeline-driven features can silently fail.

Remediation: make finalization return a structured result with `anchorsImported`, `timelineRecalculated`, and recoverable warnings. Throw or surface errors when local DB mutations fail. Tests should inject failing DAOs/writers and assert that UI-visible import status is not success.

### 5.3 Bookmark sidecar write failures are hidden behind a `UserDefaults` fallback

Severity: Medium

Evidence: `Persistence.saveBookmarks` writes the sidecar when `folderURL` is present, then always stores the encoded bookmark JSON in `UserDefaults` (`EchoCore/Services/Persistence.swift:333-349`). `writeSidecar` logs and swallows write errors (`Persistence.swift:378-386`). `loadBookmarks` prefers sidecar data and migrates defaults into the sidecar if possible (`Persistence.swift:351-375`).

Impact: users can believe bookmarks are portable with the book folder while the sidecar failed to write and the only current copy lives in app defaults. This also compounds the privacy issue in section 6.2.

Remediation: return a `BookmarkPersistenceResult` or throw for sidecar failures when portability is expected. At minimum, surface a warning and avoid presenting sidecar export as complete.

## 6. Security

### 6.1 AI provider base URLs accept plain HTTP despite HTTPS consent copy

Severity: High

Evidence: the AI settings view lets users edit `Base URL` (`EchoCore/Views/AICardGenerationSettingsView.swift:44`) and tells them book text is sent over HTTPS (`AICardGenerationSettingsView.swift:89-92`). The connection-test error also says to enter an `https://` endpoint (`AICardGenerationSettingsView.swift:153-159`). The actual client builder only checks that the URL parses and has any scheme (`Shared/Networking/AnthropicMessagesClient.swift:48-50`). Requests then send the API token in an auth header and the prompt/book text in the JSON body (`AnthropicMessagesClient.swift:127-157`).

Impact: a custom provider URL like `http://host` can receive book excerpts and API tokens in plaintext, contradicting the consent copy.

Remediation: require `https` by default. If local HTTP providers are a deliberate feature, support only an explicit local/unsafe opt-in with separate copy and tests that prove default custom providers reject `http://`.

### 6.2 User bookmark notes and voice memo metadata remain in unencrypted `UserDefaults`

Severity: Medium

Evidence: `Persistence` documents that user-created bookmark JSON with private notes and audio memo metadata is still stored in `UserDefaults.standard`, unencrypted and included in backups (`EchoCore/Services/Persistence.swift:8-16`). The write path stores the encoded bookmark data in defaults (`Persistence.swift:333-349`), and the load path reads it back (`Persistence.swift:351-375`).

Impact: private notes, bookmark titles, timestamps, and voice memo metadata get weaker storage than security-scoped bookmarks and ABS/AI tokens. The risk is local-device/backup exposure, not a remote leak.

Remediation: migrate bookmark records into the App Group SQLite store or a file-protected store, keep security-scoped bookmarks in Keychain, and leave only non-sensitive playback preferences in defaults. Add a one-time migration and backup/restore test.

### 6.3 Secrets hygiene is currently clean, but test fixtures match token patterns

Severity: Low

Evidence: a secret-shape scan found no tracked private keys, App Store API key JSON, match keys, or real provider tokens. Matches are docs, workflow secret names, and test fixture keys such as `sk-XYZ` in `EchoTests/StudyDeck/AnthropicMessagesClientTests.swift`.

Impact: no current secret leak found. The caveat is that simple token scans will stay noisy because tests intentionally use realistic fake key prefixes.

Remediation: keep fake keys obviously fake where possible, and document allowlisted test fixture paths in any future secret-scan CI job.

## 7. Performance

### 7.1 Reader feed reload rebuilds whole-book state on the main actor

Severity: High

Evidence: `ReaderFeedViewModel` is `@MainActor @Observable` (`EchoCore/ViewModels/ReaderFeedViewModel.swift:39-41`). `reload()` groups all blocks and TOC entries (`ReaderFeedViewModel.swift:223-245`), repeatedly reads chapter data in the chapter loop (`ReaderFeedViewModel.swift:291-301`), fetches all timeline rows (`ReaderFeedViewModel.swift:420-431`), loads all word timings (`ReaderFeedViewModel.swift:463-471`), loads all notes and memos (`ReaderFeedViewModel.swift:520-528`), and rebuilds display sections. Adding one note or voice memo immediately calls the full reload (`ReaderFeedViewModel.swift:552-573`, `576-596`).

Impact: large books with dense word timings or many notes can stall the reader on load and on small edits. The code is correct-looking because it is synchronous and central, but it scales poorly.

Remediation: move DB reads and section construction into a non-main snapshot builder returning a `Sendable` reader snapshot. Update note/memo caches incrementally after insert, and reserve full reload for search/filter/scope changes. Add a performance test fixture with thousands of blocks and word timings.

### 7.2 Sticky chapter-title updates do snapshot and linear search work during scroll

Severity: Medium

Evidence: `ReaderFeedCollectionView.Coordinator.updateTopChapterTitle` runs from scroll callbacks (`EchoCore/Views/ReaderFeedCollectionView.swift:729-741`). `updateChapterTitle(for:)` asks the diffable data source for a fresh snapshot and then linear-searches `sections` by section ID (`ReaderFeedCollectionView.swift:743-746`). It also creates separate main-actor tasks to write three bindings (`ReaderFeedCollectionView.swift:780-793`).

Impact: this work happens while the user scrolls. On large feeds, it adds avoidable churn to the same surface already affected by section 7.1.

Remediation: precompute `sectionByID` and `sectionIDByIndex` when snapshots are applied. Update bindings directly on the main callback when already on main, and coalesce title/theme updates if values are unchanged.

### 7.3 Library shelf reload performs full fetch, grouping, and status queries synchronously

Severity: Medium

Evidence: `LibraryViewModel.reload` calls `service.sections` and `service.statusMap` synchronously (`EchoCore/ViewModels/LibraryViewModel.swift:36-45`). `LibraryService.books` fetches all rows (`EchoCore/Services/Library/LibraryService.swift:338-345`), `sections` groups them in memory (`LibraryService.swift:348-375`), and `statusMap` performs several aggregate queries plus result assembly (`LibraryService.swift:423-461`).

Impact: this is acceptable for small libraries but will be visible once Echo has hundreds or thousands of local/ABS books. It shares the same MainActor/database design pressure as rescan.

Remediation: page or limit shelf sections, cache status summaries, and move the grouping/status read into async snapshot loading. Treat this as phase two after fixing rescan.

## 8. SwiftUI / UI

### 8.1 Visible "tap to change" helper copy remains in compact control UI

Severity: Low

Evidence: `SpeedCardView` renders `Text("tap to change")` inside the button (`EchoCore/Views/SpeedCardView.swift:23-25`).

Impact: not a bug, but it is visible instructional copy inside a compact repeated control. It also duplicates button semantics already available through the control itself.

Remediation: replace with stateful value/context, a tooltip/help affordance where appropriate, or an accessibility hint. Keep any change aligned with the current dashboard design.

### 8.2 Some card-style SwiftUI still uses fixed dimensions

Severity: Low

Evidence: `SpeedCardView` fixes the card width at `100` (`EchoCore/Views/SpeedCardView.swift:27-30`) while displaying a formatted speed string.

Impact: localized labels, Dynamic Type, or wider formatted values can crowd a compact card.

Remediation: use a responsive min/max width or layout priority instead of a hard fixed width, and verify with larger Dynamic Type and Dutch strings.

### 8.3 Reader/UI modernization is uneven but no Dynamic Type blocker remains in the inspected reader cells

Severity: Low

Evidence: reader paragraph and heading cells opt into scaled fonts and trait-change rebuilds (`EchoCore/Views/Cells/ParagraphCardCell.swift:19`, `90-94`, `130-146`; `EchoCore/Views/Cells/HeadingCardCell.swift:19-20`). Smaller dashboard/watch/macOS surfaces still contain older formatting/style patterns noted in sections 2 and 4.

Impact: the core reader accessibility story is better than the older audit implied. Remaining UI work is incremental polish and coverage, not a release blocker.

Remediation: do not rewrite reader cells. Focus cleanup on the explicit small drift items and add a screenshot/accessibility fixture when changing the dashboard row.

## 9. Dead Code / Duplication / Refactor Opportunities

### 9.1 The largest files still concentrate too much ownership

Severity: Medium

Evidence: largest Swift files in the current worktree include `EchoCore/ViewModels/PlayerModel.swift` (1,775 lines), `Echo macOS/Views/MacPlayerModel.swift` (1,726), `EchoCore/Views/ReaderTab.swift` (1,288), `EchoCore/ViewModels/ReaderFeedViewModel.swift` (1,197), `Echo Watch App/Services/WatchViewModel.swift` (1,149), `EchoCore/Views/ReaderFeedCollectionView.swift` (1,126), and `EchoCore/Services/PlaybackController.swift` (1,042).

Impact: these files are where subtle bugs keep clustering: playback, reader state, watch sync, and UI/data bridging. Size alone is not a bug, but it slows review and makes isolation/cancellation rules harder to see.

Remediation: extract only along active change boundaries: reader snapshot building, library rescan planning, watch command facade, and playback persistence. Avoid a broad "split files" PR without behavior tests.

### 9.2 Historical audit references are now process debt

Severity: Medium

Evidence: production comments and workflow comments reference `CODE_AUDIT.md` section numbers rather than stable issue/PR identifiers (`EchoCore/Services/AutoAlignmentService.swift:95`, `EchoCore/ViewModels/PlayerModel.swift:1035`, `EchoCore/Services/PlaybackController.swift:99`, `.github/workflows/ci.yml:125`).

Impact: engineers following those comments can land in the wrong current section after this report is regenerated. It also makes audits harder to archive cleanly.

Remediation: when touching each file, replace section-number references with dated audit filenames, issue IDs, or concise local comments. For new remediation work, create issues/PRs and cite those instead.

### 9.3 Direct sync database access should be treated as a refactor seam, not a local cleanup

Severity: Medium

Evidence: direct `writer.read`/`writer.write` calls appear across app, macOS, and shared services. Some are already async and correct, while others are sync on UI-owned types, so a mechanical replacement is risky.

Impact: without an explicit seam, every performance fix becomes a one-off argument about GRDB isolation.

Remediation: define a database-access contract: sync reads only in tests, tiny lookups, or already-off-main contexts; async snapshots for user-facing lists/readers; transactions for import/rescan. Enforce it gradually with source checks after the hot paths are fixed.

## 10. Cross-Cutting Recommendations

### 10.1 Remediation plan

1. P0 - security/data integrity:
   Fix `AnthropicMessagesClient.clients` to reject plain HTTP by default, then add tests for custom HTTPS, default provider URLs, and rejected HTTP. In parallel, update `DocumentImportFinalizer` so all branches preserve human anchors and propagate local DB/timeline failures.

2. P1 - user-visible performance:
   Move library rescan planning off MainActor and batch writes. Then extract reader-feed snapshot loading so the main actor only publishes completed snapshots. Add fixture-driven performance tests before refactoring.

3. P2 - privacy/storage hardening:
   Migrate bookmark records with notes/voice memo metadata out of `UserDefaults`, surface bookmark sidecar write failures, and keep portable sidecars as an explicit export/sync layer rather than the only durability story.

4. P3 - database/API guardrails:
   Narrow `DatabaseService.writer` exposure, prefer async DAO/snapshot APIs for UI code, and document the allowed sync-access cases. Do this after the two hot paths prove the pattern.

5. P4 - warning/style/process cleanup:
   Clear build warnings, broaden formatting/localization scans, remove stale audit-section references, and chip away at oversized files only when related behavior is under test.

### 10.2 Adversarial review of the plan

- The library and reader fixes can accidentally create more risk than they remove if they become architecture rewrites. Keep each change behind a pure snapshot/planner seam and compare before/after output with characterization tests.
- Preserving all human anchors during import is not always correct if a new document has different block IDs. The fix must preserve only anchors whose block IDs still exist, and it should report pruned anchors rather than silently keeping stale data.
- Rejecting HTTP for AI providers could break legitimate local lab setups. If local HTTP support matters, make it a separate "unsafe local endpoint" mode with explicit copy, not the default custom-provider path.
- Migrating bookmarks out of `UserDefaults` can break existing sidecar workflows. The migration needs rollback-safe tests and should preserve sidecar import/export behavior.
- Async database APIs alone will not make work non-blocking if the heavy grouping still happens on MainActor after the read. The plan must move parsing/grouping into the snapshot worker, not just `await` the same data.
- The warning/style cleanup is intentionally last. Doing it first would consume review bandwidth without reducing the main user risks.

### 10.3 Suggested issue split

- Issue A: Enforce AI provider HTTPS or explicit unsafe-local HTTP opt-in.
- Issue B: Make document finalization anchor replacement lossless for human anchors and non-silent for DB/timeline failures.
- Issue C: Move library rescan to cancellable off-main planner plus batched writes.
- Issue D: Extract reader feed snapshot builder and incremental note/memo updates.
- Issue E: Migrate bookmark records out of unencrypted defaults and surface sidecar failures.
- Issue F: Clear warning/style/process debt.

## 11. What Was NOT Audited

### 11.1 Runtime behavior not exercised

I did not run a physical-device pass, CarPlay session, watch pairing, VoiceOver walkthrough, App Store archive/upload, ABS server integration, CloudKit container integration, AI provider calls, or long-book scrolling under Instruments.

### 11.2 Full test action not run

I ran the compile/build gate (`xcodebuild build-for-testing`) but not the full `make test`/`xcodebuild test-without-building` action for this report-only change. The build gate emitted the warnings listed above.

### 11.3 External services not validated

Secrets, TestFlight delivery, App Store Connect metadata, CloudKit production behavior, ABS server behavior, and third-party AI endpoint behavior were inspected from code/config only.

### 11.4 Old audit findings not blindly carried forward

Several old top-level audit findings appear fixed on current nightly and are not repeated as current findings: macOS privacy manifest presence, release-train deploy key gating, root document importer error surfacing, reader Dynamic Type support, and CarPlay scene/entitlement copy drift.

## 12. Verification

### 12.1 Branch and project state

- Started from `/Users/dfakkeldy/Developer/Echo`, fetched `origin/nightly`, and avoided the dirty local checkout.
- Created clean worktree `/Users/dfakkeldy/.codex/worktrees/echo-code-audit-20260702`.
- Audited branch `codex/full-code-audit-2026-07-02`, based on `origin/nightly` at `2df6d205d32c`.
- `git status --short --branch` in the audit worktree was clean before editing this report.

### 12.2 Toolchain and project settings

- `xcodebuild -version`: Xcode 26.6, build 17F113.
- `swift --version`: Apple Swift 6.3.3.
- Targets/schemes were enumerated with `xcodebuild -list -project Echo.xcodeproj`.
- Build settings show iOS 18.0, macOS 15.0, watchOS 11.0, Swift 6.0, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and `SWIFT_APPROACHABLE_CONCURRENCY = YES`.

### 12.3 Local build

Command:

```sh
xcodebuild build-for-testing -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Result: `** TEST BUILD SUCCEEDED **`.

Warnings observed:

- `EchoTests/StandaloneTranscriptionServiceTests.swift:253:13`: no async operations occur within `await`.
- `EchoTests/ReaderFeedAccessibilityTests.swift:192:16` and `202:20`: deprecated `setOverrideTraitCollection(_:forChild:)`.
- AppIntents metadata extraction warning for `EchoUITests` due no AppIntents dependency.
- The onnxruntime strip script phase is configured to run every build because dependency analysis is disabled.

### 12.4 Repo metrics

- Swift files counted: 965.
- Swift line count from `wc -l`: 134,823 total.
- Largest files are listed in section 9.1.

### 12.5 Source scans run

- Direct database access: `rg "db\\.writer\\.(read|write)|writer\\.(read|write)"`.
- Security/token patterns: provider tokens, private key headers, App Store/match secret names.
- Formatting/API drift: `DateFormatter`, `NumberFormatter`, `MeasurementFormatter`, `String(format:)`.
- SwiftUI drift: `fontWeight`, `showsIndicators: false`, `AnyView`, `foregroundColor`, `cornerRadius`, `onTapGesture`, `Task.sleep(nanoseconds:)`, `UIScreen.main.bounds`, `NavigationView`, `tabItem`.
- TODO/FIXME/audit anchors and oversized Swift files.
