# Echo Code Audit

Generated: 2026-06-26
Branch audited: `origin/nightly` at `d18af0394b0ca9d61ca56c7b3bd0e8c0fdd1ca36`
Audit worktree: `codex/nightly-code-audit-20260626`
Toolchain observed locally: Xcode 26.6 (`17F113`)

Scope: production Swift, SwiftUI, database, security/privacy, CI, release, localization, accessibility, and project configuration across iOS, macOS, watchOS, widget, CarPlay, `Shared`, and `echo-cli`. Tests and release automation were inspected for coverage gaps. The local dirty developer worktree was not touched.

Method: four focused read-only audit agents covered security/privacy/release, Swift/concurrency/data, SwiftUI/UX/accessibility/localization, and build/test/CI/project configuration. I then verified representative evidence in the clean nightly worktree, read the applicable release and accessibility guidance, and attempted local build/test gates. No code was changed by the audit.

Summary: no Critical findings. The current nightly branch is materially more modern than the June 20 audit: Swift 6 settings are explicit, strict concurrency is enabled, several previous narration/playback findings have been fixed, and secrets hygiene is good. Remaining risk clusters are release determinism, data integrity, accessibility reachability, HTTP/token handling for self-hosted Audiobookshelf, and local/CI verification coverage.

## Severity Summary

| Severity | Count | Notes |
| --- | ---: | --- |
| Critical | 0 | No immediate crash/data-loss finding with broad certainty. |
| High | 9 | Should be fixed before widening nightly/weekly promotion. |
| Medium | 18 | Important correctness, security, accessibility, or release-quality work. |
| Low | 7 | Quick wins and polish that reduce future drift. |
| Verification blockers | 2 | Local simulator stack and Metal toolchain prevent a full local gate. |

## High Findings

### H1. macOS `.apkg` export can still generate colliding note/card IDs

Evidence: iOS export was fixed in `EchoCore/Services/ApkgExportService.swift:241-245` with a monotonic `baseID + index * 2` allocator. The macOS exporter still derives note IDs from wall-clock milliseconds plus randomized hash fragments in `Echo macOS/Services/MacApkgExportService.swift:245`.

Impact: multiple cards exported within the same millisecond can collide, causing APKG primary-key failures or corrupted exports on macOS. `hashValue` is also process-randomized, so the IDs are not deterministic.

Remediation: port the iOS monotonic allocator to `MacApkgExportService`, add macOS export regression tests for many cards generated in one export, and keep note/card ID sequences non-overlapping.

### H2. Track refresh can fail after bookmarks or playback events exist

Evidence: `bookmark.track_id` and `playback_event.track_id` reference `track` without `ON DELETE SET NULL` in `Shared/Database/Schema_V1.swift:59` and `Shared/Database/Schema_V1.swift:139`. Foreign keys are enabled in `Shared/Database/DatabaseService.swift:42`. `TimelineIngestionService` deletes all tracks before reinserting in `EchoCore/Services/TimelineIngestionService.swift:51`, via `Shared/Database/DAOs/TrackDAO.swift:34`. Bookmarks and playback events store track IDs in `EchoCore/ViewModels/PlayerModel+Bookmarks.swift:52` and `EchoCore/Services/PlaybackSessionRecorder.swift:170`.

Impact: reloading or refreshing an audiobook after user activity can hit a foreign-key constraint. The ingestion catch logs and leaves metadata/tracks partially stale.

Remediation: stop delete-all/reinsert for tracks. Use a transaction that upserts by stable track ID, remaps dependents, and deletes obsolete tracks only after dependent rows are nulled or migrated. Add a regression test that creates a bookmark/playback event and then refreshes the same book.

### H3. Auto-alignment CPU work remains MainActor-isolated

Evidence: `AutoAlignmentService` is `@MainActor` in `EchoCore/Services/AutoAlignmentService.swift:35`. `startAutoAlignment` creates its task from that isolation at `AutoAlignmentService.swift:114`. The DTW path builds token arrays and calls `TokenDTW.alignWithBisection` / `wordMatchesWithBisection` from `AutoAlignmentService.swift:441-471`. `TokenDTW` is a plain type in `EchoCore/Services/TokenDTW.swift:4`, and its direction-matrix work is in `TokenDTW.swift:175`.

Impact: long books can still hitch the UI during tokenization and DTW despite the surrounding `async` surface. Main Actor default isolation makes this easy to miss in code review.

Remediation: mark pure helper types and values as `nonisolated`/`Sendable` where appropriate, move tokenization and DTW onto an explicit background isolation boundary, and keep only progress/state mutation and database commits on MainActor. Add a performance regression test or signpost-based manual check for long chapters.

### H4. Main reader text does not honor system Dynamic Type

Evidence: `Shared/ReaderSettings.swift:30` creates fonts from custom point-size math; `ReaderFeedCollectionView` applies those fonts to headings/body text at `EchoCore/Views/ReaderFeedCollectionView.swift:381` and `EchoCore/Views/ReaderFeedCollectionView.swift:431`. `ParagraphCardCell` configures attributed body text but does not enable `adjustsFontForContentSizeCategory`; see `EchoCore/Views/Cells/ParagraphCardCell.swift:92-142`. Heading cells already opt in at `EchoCore/Views/Cells/HeadingCardCell.swift:11-12`.

Impact: the core reading surface can stay too small for users relying on Larger Text, and the app should not claim Larger Text support until this is fixed and tested.

Remediation: scale custom reader fonts through `UIFontMetrics(forTextStyle:)`, set `adjustsFontForContentSizeCategory = true` on reader text labels, rebuild attributed text on content-size-category changes, and verify at accessibility Dynamic Type sizes.

### H5. Root EPUB/PDF import can silently fail

Evidence: the root file importer discards picker failures with `try?` in `EchoCore/Views/RootTabView.swift:248`. `PlayerModel.importEPUB` and `importPDF` do not receive success/failure from their coordinators at `EchoCore/ViewModels/PlayerModel+Bookmarks.swift:140` and `EchoCore/ViewModels/PlayerModel+Bookmarks.swift:165`. `EPUBImportCoordinator` and `PDFImportCoordinator` log and return on failures at `EchoCore/Services/EPUBImportCoordinator.swift:68-80` and `EchoCore/Services/PDFImportCoordinator.swift:65-75`.

Impact: "Add Document" can appear to do nothing from an empty reader state. The user gets no loading, success, or failure feedback for a primary task.

Remediation: make import coordinators return or throw structured results, surface loading/error state in `RootTabView`, refresh only after success, and add tests for denied file access, unsupported files, and failed copy/extraction.

### H6. macOS target is missing a privacy manifest

Evidence: tracked manifests exist for `EchoCore`, `Echo Watch App`, and `Echo Widget`, but not `Echo macOS`. The macOS target directly uses `UserDefaults` in `Echo macOS/Views/MacPlayerModel.swift:95` and `Echo macOS/Views/MacPlayerModel.swift:98`.

Impact: Mac App Store/TestFlight submission can fail required-reason API validation.

Remediation: add `Echo macOS/PrivacyInfo.xcprivacy` to the macOS target with `NSPrivacyAccessedAPICategoryUserDefaults` reasons matching the app/app-group use, and extend `EchoTests/PrivacyManifestTests.swift` so all shipping targets are checked.

### H7. CarPlay is declared and advertised, but the CarPlay entitlement is disabled

Evidence: `EchoCore/Info.plist:44-50` declares a CarPlay scene. `EchoCore/EchoCore.entitlements:10-14` only comments the `com.apple.developer.carplay-audio` entitlement. Metadata includes `carplay` in `fastlane/metadata/en-US/keywords.txt:1`, TestFlight copy mentions CarPlay in `fastlane/testflight/what_to_test.txt:42`, and in-app help describes it in `EchoCore/Views/HelpContent.swift:236-241`.

Impact: App Store/TestFlight builds can advertise a feature that does not work without entitlement approval and matching provisioning.

Remediation: make a product/release decision. Either enable approved CarPlay Audio entitlement and regenerate signing profiles, or remove the scene declaration plus marketing/tester copy until entitlement approval exists.

### H8. `Package.resolved` is ignored and untracked

Evidence: `.gitignore:39` ignores every `Package.resolved`. `git check-ignore` confirms `Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is ignored, and no lockfile is tracked. The Xcode project uses minimum-version package requirements at `Echo.xcodeproj/project.pbxproj:2021`, `:2029`, `:2037`, and `:2045`, while CI hashes `**/Package.resolved` in `.github/workflows/ci.yml:44`.

Impact: fresh CI and release builds can resolve newer dependency versions than local testing, so dependency drift can break nightly without a meaningful source diff.

Remediation: unignore and commit the workspace `Package.resolved`, then consider `-onlyUsePackageVersionsFromResolvedFile` for CI/release gates once the lockfile is present.

### H9. Release train upload readiness omits the match SSH key

Evidence: `.github/workflows/release-trains.yml:20-21` documents `MATCH_GIT_SSH_KEY` as required for the signing repo. `fastlane/Matchfile:1` uses an SSH repository. The release readiness gate only checks `ASC_API_KEY_JSON` and `MATCH_PASSWORD` at `.github/workflows/release-trains.yml:165`; loading the deploy key is optional at `.github/workflows/release-trains.yml:173`.

Impact: a scheduled runner with App Store Connect JSON and match password but no SSH key will mark itself upload-ready, then fail during signing instead of degrading to compile-only.

Remediation: include `MATCH_GIT_SSH_KEY` in the readiness gate, or migrate match to an HTTPS/token auth path and update docs accordingly.

## Medium Findings

### M1. Audiobookshelf credentials default to plaintext HTTP under broad ATS exceptions

Evidence: scheme-less input becomes `http://` in `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:17`; the connection UI placeholder suggests `http://host:13378` in `EchoCore/Views/ABSConnectionsSettingsView.swift:35`; login posts credentials to `endpoints.login()` in `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift:35-46`. iOS and macOS plists allow arbitrary loads in `EchoCore/Info.plist:22` and `Echo macOS/Info.plist:15`.

Impact: same-network observers can capture credentials and refresh-token traffic outside trusted overlays. The architecture doc justifies local HTTP for self-hosted LAN/Tailscale use, so this is a product/security tradeoff, not an accidental bug.

Remediation: prefer HTTPS for bare hosts, require explicit confirmation for HTTP, show persistent insecure-server state, document the App Review justification for ATS, and keep self-signed HTTPS trust-on-first-use prominent.

### M2. ABS access tokens are embedded in URL query strings

Evidence: cover and download URLs append `?token=` in `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:45-58`. `AudiobookshelfService.downloadItemZip` also sends `Authorization: Bearer` at `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift:221`.

Impact: live tokens can leak through server logs, proxies, URL caches, screenshots, diagnostics, or crash reports more readily than headers.

Remediation: replace `AsyncImage`/self-contained URLs with authenticated loaders that use headers, avoid token-bearing URLs for app-owned downloads, and use query tokens only for endpoints that cannot support headers.

### M3. Security-scoped bookmark data can still fall back to UserDefaults

Evidence: `Persistence` documents that security-scoped bookmark data grants file-system access and should not live in plaintext defaults at `EchoCore/Services/Persistence.swift:188-201`, but stores it in `UserDefaults` when Keychain save fails at `Persistence.swift:201-202`. Restore accepts legacy defaults and continues if migration back to Keychain fails at `Persistence.swift:214-216`.

Impact: sandbox file-access grants can persist in plaintext app storage/backups.

Remediation: remove release-build fallback to UserDefaults. On Keychain failure, fail closed, clear plaintext legacy data when safe, and ask the user to reselect the folder.

### M4. ABS failed-connect and sign-out paths can strand credentials

Evidence: login stores tokens before the server record is saved in `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift:43-46`. `PlayerModel+Audiobookshelf` only clears tokens on a failed DAO save when a cert pin exists around `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift:47-50`. Sign-out clears local tokens even if remote logout fails in `AudiobookshelfService.swift:73-80`.

Impact: local orphaned Keychain tokens or still-valid server refresh tokens can remain after the UI says the account is disconnected.

Remediation: always roll back tokens on persistence failure, and distinguish local clearing from remote revoke failure with retry/backoff or a visible degraded state.

### M5. PDF alignment/bookmark actions are long-press-only

Evidence: `PDFDocumentView` exposes PDF state through a long-press path at `EchoCore/Views/PDFDocumentView.swift:27`, backed by `UILongPressGestureRecognizer` in `PDFDocumentView.swift:141` and `PDFDocumentView.swift:200-202`.

Impact: VoiceOver, Switch Control, keyboard, and Voice Control users may not be able to align or bookmark PDFs.

Remediation: add visible toolbar/menu actions and `UIAccessibilityCustomAction`s for align, align-to-current-time, and bookmark.

### M6. Secondary transport actions lack accessibility equivalents

Evidence: `EchoCore/Views/TransportControlsView+LongPress.swift:117-122` implements secondary behavior through tap/long-press gestures without named accessibility actions.

Impact: long-press-only transport actions are hidden from assistive technologies.

Remediation: add named `.accessibilityAction` entries, labels, hints, and values for secondary actions.

### M7. Scrubber joystick is drag-only

Evidence: `EchoCore/Views/ScrubberJoystick.swift:24` uses `DragGesture`; no `accessibilityAdjustableAction` was found for that control.

Impact: manual alignment scrubbing is difficult or unavailable for Switch Control and many VoiceOver users.

Remediation: add `.accessibilityAdjustableAction` plus named small/large step actions for forward/backward movement.

### M8. Several selectable rows are gesture-only

Evidence: gesture-only row selection appears in `EchoCore/Views/SoundscapePickerView.swift:79`, `EchoCore/Views/ChimeSettingsView.swift:33`, `Echo macOS/Views/MacTOCTreeView.swift:44`, and `Echo macOS/Views/MacReaderFeedView.swift:391`.

Impact: these rows may not be announced as controls and are weaker for keyboard, Voice Control, and Switch Control.

Remediation: replace with `Button`, `NavigationLink`, or selection controls using plain styles where needed.

### M9. DB-backed JSON/Codable failures are collapsed to empty/default data

Evidence: EPUB markers/formats use `try?` and return `nil` or `[]` in `Shared/Database/EPubBlockRecord.swift:72-93`. PDF bookmark state encodes failed values as empty `Data()` and decodes with `try?` in `Shared/Database/BookmarkRecord.swift:69` and `Shared/Database/BookmarkRecord.swift:89`.

Impact: corrupt or version-skewed persisted metadata becomes indistinguishable from intentionally empty metadata, so inline markers, formatting, and PDF state can silently disappear.

Remediation: expose throwing decode paths or structured diagnostics with row IDs. Return empty only for truly absent optional columns.

### M10. `PDFDocumentView` uses an unowned detached task that captures the SwiftUI view

Evidence: `EchoCore/Views/PDFDocumentView.swift:76` starts `Task.detached`, enumerates files and creates a `PDFDocument` off-main, then assigns captured SwiftUI state back on MainActor.

Impact: work is not tied to view lifetime or `folderURL`; stale loads can win after identity changes, and PDFKit object sendability is not established.

Remediation: use `.task(id: folderURL)` or an owned cancellable task, return only a Sendable URL/result from background discovery, and construct/assign `PDFDocument` on MainActor unless PDFKit sendability is proven safe.

### M11. Deployment-target policy is inconsistent

Evidence: `AGENTS.md:17` and README badges advertise iOS 19, macOS 16, and watchOS 12. The project still targets iOS 18, macOS 15, and watchOS 11 in `Echo.xcodeproj/project.pbxproj:1194`, `:1349`, and `:1537`, and `ThirdParty/MisakiSwift/Package.swift:33` declares iOS 18/macOS 15.

Impact: contributors may use APIs based on the documented floor while shipping targets still promise older OS support.

Remediation: choose the source of truth. Either raise every app/test/package target together, or correct docs and agent guidance to preserve iOS 18/macOS 15/watchOS 11.

### M12. `echo-cli` hard-codes a removed macOS SDK framework path

Evidence: `Echo.xcodeproj/project.pbxproj:139` references `MacOSX15.0.sdk/System/Library/Frameworks/Cocoa.framework`; installed Xcode 26.6 SDKs are current `MacOSX.sdk`/`MacOSX26*.sdk`.

Impact: `echo-cli` can fail under current Xcode if the stale SDK path is resolved literally.

Remediation: change the framework reference to SDKROOT-relative `System/Library/Frameworks/Cocoa.framework`, remove it if unused, and add `echo-cli` to CI if supported.

### M13. Watch tests exist but are not run by CI

Evidence: the shared Watch scheme includes `Echo Watch AppTests` and `Echo Watch AppUITests` in `Echo.xcodeproj/xcshareddata/xcschemes/Echo Watch App.xcscheme:53-65`. CI runs only `EchoTests` with `-only-testing:EchoTests` in `.github/workflows/ci.yml:108-112`.

Impact: watch-specific regressions can merge to nightly.

Remediation: add a serial watchOS unit-test job on a pinned destination, or explicitly document watch tests as manual until CI capacity exists.

### M14. Privacy manifest may miss a file metadata required-reason API family

Evidence: `EchoCore/PrivacyInfo.xcprivacy:15` declares only UserDefaults. Shipping code calls `FileManager.default.attributesOfItem(atPath:)` for a model size check in `EchoCore/Services/Narration/OnnxKokoroEngine.swift:120`. Current privacy tests enumerate manifest files but do not scan Swift source for required-reason API usage in `EchoTests/PrivacyManifestTests.swift:99-108`.

Impact: archive/upload privacy checks may flag file metadata usage, even if only size is read.

Remediation: verify with an Xcode archive privacy report. Prefer a non-flagged length read if possible, or add the correct required-reason category if justified.

### M15. CloudKit public database remains an explicit trust/abuse decision

Evidence: current code validates downloaded anchor block IDs and excludes synthesized anchors, but the architecture still uses public CloudKit database semantics for shared anchor payloads.

Impact: public-db writes need abuse/rate-limit and attribution controls before broad release.

Remediation: decide whether anchors belong in private/shared CloudKit instead. If public remains intentional, add rate limits, author attribution, payload size checks, and an abuse recovery path.

### M16. Release train build gate does not use the capped CI test flags

Evidence: normal CI uses `-parallel-testing-enabled NO` and `-jobs 5` in `.github/workflows/ci.yml:96-101`. The release-train build gate at `.github/workflows/release-trains.yml:154-160` does not.

Impact: scheduled builds can behave differently from PR builds and increase memory-pressure failures.

Remediation: mirror the serial/capped flags from `ci.yml` in release trains.

### M17. Reader/PDF action strings bypass localization catalog

Evidence: hardcoded UIKit/accessibility strings remain in `EchoCore/Views/ReaderTab+Alignment.swift`, `EchoCore/Views/PDFDocumentView.swift`, and ABS connection error handling.

Impact: important menus, VoiceOver actions, and errors remain English in localized builds.

Remediation: add manual keys to `Localizable.xcstrings`, then use generated symbols for SwiftUI and `String(localized:)` for UIKit/error strings.

### M18. User-visible formatting is not fully locale/plural safe

Evidence: legacy `DateFormatter` and `String(format:)` remain in `EchoCore/Models/SpeedSuggestion.swift:21-36`, `EchoCore/Views/SessionsListView.swift:15-66`, `EchoCore/Views/SessionDetailFeedView.swift:80`, and `EchoCore/Views/ReaderSettingsSheet.swift:32`.

Impact: dates, decimals, measurements, and plurals can be wrong outside US English.

Remediation: replace with `FormatStyle`, `Measurement.FormatStyle`, and localized strings with placeholders/plurals.

## Low Findings

- `Task.sleep(nanoseconds:)` remains in `Echo macOS/Services/MacAlignmentService.swift:73` and `EchoCore/Services/DefaultChimePlayer.swift:41`.
- `ReaderTab+Alignment.swift:27` still uses `DispatchQueue.main.asyncAfter` for a non-cancellable pulse reset.
- ABS progress-sync errors are swallowed with `try?` in `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`.
- The beta Fastlane lane rescue-wraps macOS archive failures and still uploads the iOS IPA in `fastlane/Fastfile:167-202`.
- Screenshot automation can pass with incomplete marketing coverage; the desired Watch/privacy shots are documented but not enforced.
- `Echo Watch App/Views/PlayerPage.swift:647` has a hidden blank button for `handGestureShortcut(.primaryAction)` that should be explicit or hidden from accessibility.
- Fastlane docs/config still include stale TODOs around bundle ID and `apple_id("")`.

## Verification Blockers

### V1. Local simulator build/test commands are blocked

`make build-tests` failed before compilation because CoreSimulator `1051.54.0` is older than Xcode 26.6's required `1051.55.0`, and the requested `iPhone 17` simulator destination was unavailable. `xcodebuild -list -project Echo.xcodeproj` reports the same CoreSimulator mismatch while still listing schemes.

Required follow-up: update/reinstall matching macOS/Xcode simulator components, restart CoreSimulator services, then rerun `make build-tests` and `make test`.

### V2. Generic iOS build reaches Metal compilation, then fails without Metal Toolchain

`xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -jobs 5` reached compilation and failed on `EchoCore/Views/Visualizer/VisualizerShaders.metal` because the local Xcode install lacks the Metal Toolchain. CI already downloads it with `xcodebuild -downloadComponent MetalToolchain`.

Required follow-up: install Metal Toolchain locally or rely on CI for this gate, then rerun the generic build.

## Strengths Observed

- Echo-owned targets are explicitly on Swift 6 with complete strict concurrency and Main Actor default isolation (`Echo.xcodeproj/project.pbxproj:1198-1202` and repeated target settings).
- No app-code `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, or `@EnvironmentObject` usage was found in the scoped scan.
- GRDB setup is centralized, WAL-backed, and enables foreign keys.
- Secrets hygiene is good: no tracked private keys, App Store API keys, provisioning profiles, `.env`, `.p12`, `.cer`, `.pem`, or secret-shaped tokens were found; `.gitignore` excludes `fastlane/api_key.json`.
- ABS refresh tokens are intended for Keychain storage, and `KeychainStore` uses device-only accessibility.
- Self-signed HTTPS has an explicit fingerprint trust prompt for Audiobookshelf.
- macOS sandbox, network client, user-selected file access, app-scope bookmarks, and hardened runtime are present.
- Reader cells already expose several custom accessibility actions; the main accessibility gaps are Dynamic Type scaling, gesture parity, and localization.

## Remediation Plan

The full dated remediation plan is in `docs/superpowers/plans/2026-06-26-nightly-code-audit-remediation.md`. The canonical summary is `CODE_AUDIT_REMEDIATION_PLAN.md`.
