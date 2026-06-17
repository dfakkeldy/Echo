# Echo Code Audit

Generated 2026-06-16. Scope: ~52,209 Swift LOC across 433 files + 1 Metal file, in targets iOS, macOS, watchOS, Widget. `Dead/`, `Pods/`, `.build/`, `.git/` excluded. Previous audit archived at `docs/CODE_AUDIT_2026-06-13_session2.md`.

Findings cite `path/to/file.swift:LINE` for Xcode navigation. Each item has a recommended action; no code changes were made.

---

## 1. Executive summary

1. **[Critical] Force-unwrapped URL construction from user input** — §5.1 — `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:20,26,36-43,48`. User-provided server URL with illegal characters crashes the app on every endpoint call.
2. **[Critical] @MainActor state mutated from background Task** — §3.1 — `EchoCore/Services/PlayerLoadingCoordinator.swift:266,290`. `PlaybackState` properties written from unisolated `Task {}` — data race in core loading path.
3. **[Critical] WhisperKit model retain-count race** — §5.2 — `EchoCore/Services/ContinuousAlignmentService.swift:75-131`. Stop/start cycles leak the ~40 MB model via mismatched acquire/release.
4. **[Critical] In-memory database fallback force-try crash** — §5.3 — `Echo macOS/Echo_macOSApp.swift:239`. Double `try?`/`try!` fallback crashes when primary init already failed.
5. **[Critical/Security] CloudKit missing accountStatus + `try?` swallow** — §6.1 — `EchoCore/Services/CloudKitSyncService.swift:84,146` + `EPUBAutoImportScanner.swift:176`. Signed-out users get zero community anchors with zero feedback.
6. **[High] NarrationExportService actor/@MainActor conflict** — §3.2 — `EchoCore/Services/Narration/NarrationExportService.swift:20,96,98`. Four latent Swift 6 errors; actor executor conflicts with @MainActor-inferred APIs.
7. **[High] EPUB assets never cleaned up** — §7.1 — `EchoCore/Services/EPUBAssetStorage.swift:87-92`. Orphan asset directories accumulate indefinitely; `removeAll(for:)` defined but never called.
8. **[High] Per-book UserDefaults keys accumulate forever** — §5.4 — `EchoCore/Services/BookPreferencesService.swift:10-35`. Stale keys from removed books bloat UserDefaults plist, slowing launch.
9. **[High] String enums without unknown-case handling** — §5.5 — Six `String: Codable` enums crash on future schema additions.
10. **[High] EPUB reader cells have zero accessibility** — §8.2 — Three `UICollectionViewCell` subclasses with no VoiceOver labels. Core feature inaccessible; App Store rejection risk.

---

## 2. Quick wins (≤30 min each)

- **Add `[weak self]` + `@MainActor` to PlayerLoadingCoordinator Tasks** — `EchoCore/Services/PlayerLoadingCoordinator.swift:266,290`. Two `Task {}` blocks capture `self` strongly and mutate `@MainActor` state from background.
- **Remove `try!` from in-memory DB fallback** — `Echo macOS/Echo_macOSApp.swift:239`. Replace with `try?` + graceful fallback.
- **Add `accountStatus()` check before CloudKit ops** — `EchoCore/Services/CloudKitSyncService.swift:84,146`. Two-line guard at each entry point.
- **Replace `try?` with `do/catch`+log in CloudKit caller** — `EchoCore/Services/EPUBAutoImportScanner.swift:176`.
- **Delete unused `AnimationDurations.swift`** — `Shared/AnimationDurations.swift`. Zero usages; all animations use inline literals.
- **Cache `NSRegularExpression` in TextNormalizer** — `EchoCore/Services/Narration/TextNormalizer.swift:28-44`. Four `try!` pattern compilations per block.
- **Remove redundant double sort in AlignmentTranscript.words()** — `EchoCore/Services/AlignmentTranscript.swift:74`. One-line fix.
- **Add `deinit` to TranscriptStore** — `Echo macOS/Views/TranscriptStore.swift:27`. NotificationCenter observer never removed.
- **Remove `import SwiftUI` from non-view files** — `PlayerModel+PlaybackControllerDelegate.swift`, `MacPlayerModel.swift`, `CarPlayManager.swift`.
- **Add `@MainActor` annotation to ReaderTab+Alignment Tasks** — `EchoCore/Views/ReaderTab+Alignment.swift:34,106`.

---

## 3. Concurrency

### 3.1 @MainActor state mutated from background Task (PlayerLoadingCoordinator)
- **Location:** `EchoCore/Services/PlayerLoadingCoordinator.swift:266-284, 290-322`
- **What:** `ingestMultiM4BChapters()` and `ingestMultiTrackChapters()` create `Task {}` (no `@MainActor` annotation) that writes to `PlaybackState` properties (`m4bBooks`, `aggregatedChapters`, `chapters`). `PlaybackState` is `@MainActor @Observable`. Writing from a background context races with main-actor reads.
- **Why:** SwiftUI observation fires on the wrong actor, causing UI glitches or data corruption. The `@MainActor` isolation provides no runtime enforcement because the Task doesn't declare its actor context.
- **Action:** Change `Task {` to `Task { @MainActor in`. Also add `[weak self]` to prevent retain cycles. Add `do/catch` — both tasks perform fallible work with no error propagation.
- **Severity:** Critical

### 3.2 NarrationExportService actor/@MainActor conflict
- **Location:** `EchoCore/Services/Narration/NarrationExportService.swift:20,89,91,96,98`
- **What:** `NarrationExportService` is declared `actor`, but every method it calls is inferred `@MainActor`-isolated. The actor's executor cannot satisfy `@MainActor` isolation. Warnings now; errors in Swift 6.
- **Why:** Four latent Swift 6 compilation errors. The actor pattern is wrong here — an actor's serial executor conflicts with @MainActor APIs.
- **Action:** Convert from `actor` to `@MainActor class`. Replace `exportSession.export()` with `await` overload and `status` with `states(updateInterval:)`. Mark `AudioMarker` methods `nonisolated` if they don't need main-actor isolation.
- **Severity:** High

### 3.3 Captured var 'anchors' in @Sendable closure
- **Location:** `EchoCore/Services/Narration/NarrationService.swift:162`
- **What:** Local `var anchors` captured by-reference in `db.write {}` closure (which is `@Sendable`).
- **Why:** Mutable capture in sendable closure is a data race risk. Compiler warning today; error in Swift 6. The `var` is only appended in a preceding loop, never mutated at indices.
- **Action:** Change `var anchors` to `let anchors` on line 75.
- **Severity:** Medium

### 3.4 Main actor-isolated property captured in Sendable closure
- **Location:** `Echo macOS/Views/MacAnkiExportView.swift:172`
- **What:** `selectedDeckIDs` (main actor-isolated) referenced from `@Sendable` `Task {}` closure.
- **Why:** Swift 6 error — non-Sendable main actor-isolated properties cannot be captured by `@Sendable` closures.
- **Action:** Copy `selectedDeckIDs` into a local `let` before the `Task {}` block.
- **Severity:** Medium

### 3.5 MainActor type inference from module context
- **Location:** `NarrationFileNaming`, `AudioMarker`, `HeadingClassifier` (various files)
- **What:** Types without explicit `@MainActor` are inferred as main actor-isolated because they're in the same module as `@MainActor` types.
- **Why:** Hard-to-debug call-site errors when adding new callers from non-isolated contexts.
- **Action:** Audit each type: if it needs `@MainActor`, annotate explicitly; if not, add `nonisolated` to specific methods.
- **Severity:** Medium

### 3.6 Task.detached without cancellation propagation
- **Location:** `EchoCore/Services/InlineFlashcardTriggerController.swift:49,132`
- **What:** `Task.detached { [weak self] in }` for flashcard grading with no stored reference, so it can't be cancelled.
- **Why:** Long-running DB writes outlive the triggering view, writing stale data after session ends.
- **Action:** Store the Task and cancel in `resetForNewTrack()`.
- **Severity:** Medium

### 3.7 `nonisolated(unsafe)` has no effect on property
- **Location:** `EchoCore/Services/StandaloneTranscriptionService.swift:20`
- **What:** `nonisolated(unsafe) var currentTask` — the `(unsafe)` variant is unnecessary; plain `nonisolated` suffices.
- **Why:** Suppresses compiler checking that could catch real issues.
- **Action:** Change to `nonisolated var currentTask`. Add migration comment.
- **Severity:** Low

---

## 4. API modernity

### 4.1 AVAssetExportSession deprecated in macOS 15.0
- **Location:** `EchoCore/Services/Narration/NarrationExportService.swift:89,91`
- **What:** `exportSession.export()` and `exportSession.status` deprecated. `AVAssetExportSession` itself deprecated; replacement is `AVAssetWriter`.
- **Why:** macOS 15.0 is the deployment target — these could be removed in a future SDK.
- **Action:** Replace with async `export()` overload and `states(updateInterval:)`. Long-term: migrate to `AVAssetWriter`.
- **Severity:** Medium

### 4.2 AVAsset(url:) deprecated in macOS 15.0
- **Location:** `Echo macOS/Services/AudioExtractor.swift:25`
- **What:** `AVAsset(url:)` deprecated; use `AVURLAsset(url:)`.
- **Why:** Codebase already uses `AVURLAsset` elsewhere; this site is inconsistent.
- **Action:** Replace with `AVURLAsset(url:)`.
- **Severity:** Low

### 4.3 withCheckedContinuation for Process — async overload available
- **Location:** `TranscriptionManager.swift:245`, `MacApkgExportService.swift:159`, `MacAlignmentService.swift:136`
- **What:** Three sites bridge `Process.terminationHandler` via `withCheckedContinuation`. `Process.run() async throws` available since macOS 10.15.
- **Why:** Unnecessary continuation bridging; deployment target far exceeds availability.
- **Action:** Replace with `try await process.run()` + post-await termination status check.
- **Severity:** Low

### 4.4 @Observable migration complete
- **Observation:** Zero `ObservableObject` or `@Published` remain. All 31 `@Observable` types migrated. Strong positive finding.
- **Severity:** None (confirmed complete)

### 4.5 Task.sleep(nanoseconds:) → Task.sleep(for:)
- **Location:** 4 sites — `MacAlignmentService.swift:73`, `MacReaderFeedView.swift:200`, `DefaultChimePlayer.swift:41`, `LocationCaptureService.swift:118`
- **What:** `Task.sleep(nanoseconds:)` requires manual nanosecond conversion.
- **Action:** Mechanical replacement with `.milliseconds()`, `.seconds()`.
- **Severity:** Low

### 4.6 NotificationCenter selector-based observers
- **Location:** `TranscriptStore.swift:29` (selector), 14 `addObserver` calls
- **What:** Selector/block-based observers where async `notifications(named:object:)` AsyncSequence is available.
- **Action:** Migrate audio session and CarPlay observers to async notifications stream.
- **Severity:** Medium

---

## 5. Bugs / logic errors

### 5.1 Force-unwrapped URL construction from user input
- **Location:** `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:20,26,36-43,48,63,74,83`
- **What:** Seven `URL(string: "\(base)/...")!` calls take `base` (user-provided server URL) and force-unwrap. `baseURL(from:)` only trims whitespace — no validation or percent-encoding.
- **Why:** User typing a server address with spaces or URL-illegal characters causes fatal crash on every endpoint call. No fallback exists.
- **Action:** Replace with `URLComponents(string:)` for validation. Add encoding in `baseURL(from:)`.
- **Severity:** Critical

### 5.2 WhisperKit model retain-count race on stop/start
- **Location:** `EchoCore/Services/ContinuousAlignmentService.swift:75-87,129-131`
- **What:** `stop()` sets `whisperKit = nil` then spawns release Task. If `start()` is called between nil and release, `acquire()` fires without balancing release → model leaked. Nil assignment also destroys reference in-flight transcription may need.
- **Why:** ~40 MB model leaked permanently on each stop/start race. Frequent auto-alignment toggles cause unbounded memory growth.
- **Action:** Keep old WhisperKit reference until release Task completes. Use generation counter to invalidate old instances.
- **Severity:** Critical

### 5.3 In-memory database force-try crash fallback
- **Location:** `Echo macOS/Echo_macOSApp.swift:239`
- **What:** `(try? DatabaseService(inMemory: ())) ?? (try! DatabaseService(inMemory: ()))` — first `try?` failed, second `try!` repeats same failure and crashes.
- **Why:** First failure already indicates systemic init problem. Force-try fallback crashes with no user error.
- **Action:** Replace `try!` with `try?` + graceful fallback. Use `fatalError` only under `#if DEBUG`.
- **Severity:** Critical

### 5.4 Per-book UserDefaults keys accumulate indefinitely
- **Location:** `EchoCore/Services/BookPreferencesService.swift:10-35`, `EchoCore/Services/Persistence.swift:29-33`
- **What:** Per-book keys (`book_appFont_<audiobookID>`, progress, speed, loop, etc.) never cleaned when books removed. `audiobookID` is folder URL's `absoluteString`.
- **Why:** With 300+ books over years, UserDefaults loads 1500-3000 stale keys. Incremental launch slowdown and memory pressure.
- **Action:** Add cleanup calls on book removal, or migrate to GRDB database (which already has `audiobookID` columns).
- **Severity:** High

### 5.5 String enums without unknown-case handling crash on schema additions
- **Location:** `TimelineItemType`, `MarkerType`, `RealTimeEventType`, `FormatType`, `GranularityLevel`, `LoopMode`
- **What:** Five `String: Codable` enums decoded from database rows. Future app version adding new case → current build crashes with `DecodingError.dataCorrupted` on any read.
- **Why:** Users toggling between versions lose data access. Backward-compatility break.
- **Action:** Add `case unknown(String)` with custom `init(from:)` capturing unknown raw values.
- **Severity:** High

### 5.6 StatsRepository retention curve always empty
- **Location:** `Shared/Stats/StatsRepository.swift:348,369` vs `EchoCore/ViewModels/DailyReviewViewModel.swift:98`
- **What:** Retention curve query reads `intervalDays` from `metadata_json`, but writer only includes `cardId` and `grade` — never `intervalDays`. Query silently excludes every review.
- **Why:** `[String: Any]` JSONSerialization provides no compile-time field verification. Bug exists because reader expects field writer never includes.
- **Action:** Define typed `Codable` struct for review metadata with all fields both sides expect.
- **Severity:** High

### 5.7 SettingsManager reads watch properties before migration
- **Location:** `EchoCore/Services/SettingsManager.swift:483-527`
- **What:** Watch properties read from `appGroupDefaults` before migration from `defaults.standard` runs. First launch post-upgrade: App Group empty → all watch properties get defaults. Migration then copies values, ignored until next launch.
- **Why:** Watch settings revert to defaults for one session post-upgrade. Custom layout, crown action, progress bar modes lost.
- **Action:** Reorder init: run migration before reading watch properties.
- **Severity:** Medium

### 5.8 DeckImportService imports each card in own transaction
- **Location:** `EchoCore/Services/DeckImportService.swift:53-103`
- **What:** Loop calls `FlashcardDAO.insert()` which wraps each insert in separate `db.write {}` — N+2 transactions. Crash mid-import → partial deck.
- **Why:** Non-atomic import; multi-second times for 100+ cards.
- **Action:** Wrap entire import (deck + all cards) in single `db.write {}`.
- **Severity:** Medium

### 5.9 EPUBHeadingPickerSheet silently swallows DB errors
- **Location:** `EchoCore/Views/EPUBHeadingPickerSheet.swift:50-52`
- **What:** `loadHeadings()` catches errors with comment-only handler. User sees empty sheet with no explanation.
- **Why:** "Align to Heading" shows blank list — user doesn't know why.
- **Action:** Add error state with retry.
- **Severity:** Medium

### 5.10 ReaderTab stuck on "Loading EPUB..." if DB is nil
- **Location:** `EchoCore/Views/ReaderTab.swift:403-408`
- **What:** `loadViewModel()` silently returns if `model.databaseService` is nil. Infinite spinner, no error, no retry.
- **Why:** Users with DB init failure can never read their EPUB.
- **Action:** Add loading/error state enum with retry button.
- **Severity:** Medium

### 5.11 AudioMarker documented as stub but called in production
- **Location:** `EchoCore/Services/Narration/NarrationExportService.swift:38,96`
- **What:** Comment says `AudioMarker` is "copy-only stub" deferred post-1.0, but `writeChapters()` called in production export. If stub does nothing, exported .m4b has no chapter markers.
- **Why:** Users exporting .m4b expecting chapter navigation get flat files.
- **Action:** Implement chapter atom writing or remove export function and update docs.
- **Severity:** Medium

### 5.12 ReaderTab+Alignment constructs services in view extension
- **Location:** `EchoCore/Views/ReaderTab+Alignment.swift:14-50,106-145,300-344`
- **What:** `alignBlock()` constructs `AutoAlignmentService`/`AlignmentService` and spawns `Task` in view extension. `startAutoAlignment()` constructs DAOs and manages task lifecycle. `saveBookmark()` runs raw SQL. All untestable.
- **Why:** Business logic in view extension. If view dismisses during async op, `viewModel` becomes nil silently. `AutoAlignmentState` never wired to published state.
- **Action:** Move into `ReaderFeedViewModel` as methods.
- **Severity:** High

### 5.13 Binaural beats channel identification via pointer comparison
- **Location:** `EchoCore/Services/DefaultSoundscapeMixer.swift:213`
- **What:** `buffer.mData == ablPointer[1].mData` compares raw buffer pointers to identify right channel. `AVAudioSourceNode` doesn't guarantee consistent buffer order.
- **Why:** On cycles with different buffer assignments, both channels produce same tone — binaural beat effect broken.
- **Action:** Use frame-level channel index via `UnsafeMutableAudioBufferListPointer` enumeration.
- **Severity:** High

---

## 6. Security

### 6.1 CloudKit missing accountStatus + silent error swallowing
- **Location:** `EchoCore/Services/CloudKitSyncService.swift:84,146`, `EchoCore/Services/EPUBAutoImportScanner.swift:176`
- **What:** No `accountStatus()` check before CloudKit ops. Download uses `try?` discarding `.notAuthenticated`, `.networkUnavailable`, `.quotaExceeded`. Only `.serverRecordChanged` handled on upload.
- **Why:** Signed-out users get zero community anchors with zero indication. Upload errors show unhelpful "Upload Failed."
- **Action:** Gate both entry points with `accountStatus()`. Replace `try?` with `do/catch`+log. Handle `.quotaExceeded`, `.networkUnavailable`, `.notAuthenticated`, `.partialFailure`. Add retry with exponential backoff.
- **Severity:** Critical

### 6.2 Security-scoped bookmark fallback writes to UserDefaults
- **Location:** `EchoCore/Services/Persistence.swift:199-202`
- **What:** Keychain write failure falls back to unencrypted UserDefaults for security-scoped bookmark data.
- **Why:** UserDefaults is in iCloud backups and plaintext on disk. Compromised backup exposes filesystem access grants.
- **Action:** Remove UserDefaults fallback. Surface Keychain failure to user and retry.
- **Severity:** Medium

### 6.3 Bookmark notes and location in plaintext UserDefaults
- **Location:** `EchoCore/Services/Persistence.swift:248-263`
- **What:** Full `Bookmark` array as JSON in `UserDefaults.standard`. Contains user notes, lat/lon, place names.
- **Why:** Private notes and location in plaintext, included in iCloud backups.
- **Action:** Migrate to GRDB (BookmarkRecord table and MacPlayerModel migration pattern already exist).
- **Severity:** Medium

### 6.4 No explicit file protection on sensitive writes
- **Location:** `Persistence.swift:296`, `WatchCommandRouter.swift:213`, `Bookmarks.swift:473`
- **What:** Bookmark sidecars, voice memos, bookmark images use default `.completeUntilFirstUserAuthentication`.
- **Why:** Data accessible after first unlock rather than only when unlocked.
- **Action:** Add `.completeFileProtection` write option for sensitive content.
- **Severity:** Low

---

## 7. Performance

### 7.1 EPUB assets never cleaned up
- **Location:** `EchoCore/Services/EPUBAssetStorage.swift:87-92`
- **What:** `removeAll(for:)` defined but never called. Each EPUB import copies images to `Application Support/EPUBAssets/<safeID>/`. When books removed, old asset directories remain.
- **Why:** App container grows indefinitely — hundreds of MB of stale images. Backup size compounds. No observable symptom until low-storage.
- **Action:** Wire `removeAll(for:)` into book-removal flow, or call before `prepare(for:)` at import.
- **Severity:** High

### 7.2 All 17 timers lack tolerance
- **Location:** 17 `Timer.scheduledTimer` sites — `AudioEngine.swift:311,493`, `SleepTimerManager.swift:43`, `ContinuousAlignmentService.swift:60`, `BookmarkStore.swift:274`, `PlayerModel.swift:1297,1317`, plus watchOS sites
- **What:** Zero timers set `.tolerance`. System cannot coalesce timer fires, preventing deep CPU idle states.
- **Why:** ~3-5% battery drain/hour from unnecessary wake-ups. 20 Hz fade timer worst offender.
- **Action:** Add 10% tolerance to all repeating timers. For 0.5s timer: 0.05s. For 15s timer: 1.5s.
- **Severity:** High

### 7.3 EPUB assets lack isExcludedFromBackup
- **Location:** `EchoCore/Services/EPUBAssetStorage.swift:46-50`
- **What:** EPUB images in `Application Support/EPUBAssets/` are regenerable but `isExcludedFromBackup` never set. Narration cache correctly sets it — contrast is stark.
- **Why:** Each EPUB book with 20-50 images adds 5-15 MB to iCloud backups unnecessarily.
- **Action:** Set `isExcludedFromBackup = true` on asset directory after creation.
- **Severity:** High

### 7.4 ImageCardCell loads UIImage synchronously on main thread
- **Location:** `EchoCore/Views/Cells/ImageCardCell.swift:59`
- **What:** `UIImage(contentsOfFile:)` called synchronously in `configure(with:tint:)` — UICollectionView data source method. Large EPUB illustrations block main thread during scroll.
- **Why:** Frame drops when scrolling through EPUB image blocks.
- **Action:** Load asynchronously via `Task.detached` and cache with `NSCache`.
- **Severity:** Medium

### 7.5 Synchronous DB read in PlayerModel computed property
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:404-410`
- **What:** `hasStandaloneTranscript` performs synchronous `try? db.read { fetchCount }` in computed property read during SwiftUI body evaluation.
- **Why:** Main thread blocked on DB query during view rendering — frame drops when DB under write load.
- **Action:** Cache result against `documentIngestionTrigger` like `hasPDF` does.
- **Severity:** Medium

### 7.6 DTW direction matrix allocates up to 48 MB per alignment call
- **Location:** `EchoCore/Services/TokenDTW.swift:111`
- **What:** `[Int8](repeating: 0, count: (n+1) * (m+1))` — for ~6000 EPUB tokens × ~8000 audio tokens: 48 MB allocated, zeroed, filled, discarded. Per chapter.
- **Why:** Dominant memory cost of alignment pipeline. Memory pressure on 4 GB devices.
- **Action:** Halve `maxCells` to 24M, or use `UnsafeMutableBufferPointer` to skip zero-init.
- **Severity:** Medium

### 7.7 WordFrequencyComputer O(n²) filtering per chapter
- **Location:** `EchoCore/Utilities/WordFrequencyComputer.swift:33-43`
- **What:** For each chapter, filters entire segments array — O(chapters × segments). 50 chapters × 1000 segments = 50,000 comparisons + 50 array allocs.
- **Why:** Noticeable UI delays during track loading for large audiobooks.
- **Action:** Pre-build segment interval tree or binary-search for window boundaries.
- **Severity:** Medium

### 7.8 Missing reserveCapacity in alignment hot-path arrays
- **Location:** `AlignmentTranscript.swift:47`, `AutoAlignmentService.swift:396`, `TokenDTW.swift:155`, `AnchorSelector.swift:24`
- **What:** Multiple arrays grow via `.append()` with no capacity reservation. ~10-14 reallocations per 10K items.
- **Why:** ~20K wasted element copies for 10K items.
- **Action:** Add `.reserveCapacity(estimatedCount)` before append loops.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 Conditional HStack/VStack identity loss in PlayerScrubberView
- **Location:** `EchoCore/Views/PlayerScrubberView.swift:18-61`
- **What:** `if settings.playerLayoutStyle == "compact" { HStack } else { VStack }` destroys and recreates scrubber and time labels on toggle. `@State` variables reset.
- **Why:** User changing layout mid-scrub loses position. HIG identity violation.
- **Action:** Use `AnyLayout(HStackLayout(...))` / `AnyLayout(VStackLayout(...))`.
- **Severity:** High

### 8.2 EPUB reader cells have zero accessibility
- **Location:** `EchoCore/Views/Cells/HeadingCardCell.swift`, `ParagraphCardCell.swift`, `ImageCardCell.swift`
- **What:** Three `UICollectionViewCell` subclasses with zero `isAccessibilityElement`, `accessibilityLabel`, or `accessibilityTraits`. EPUB reader core content invisible to VoiceOver.
- **Why:** App Store rejection risk — core feature completely inaccessible.
- **Action:** Configure `isAccessibilityElement = true`, `accessibilityLabel = block.text`, `accessibilityTraits = [.staticText]` in `configure(with:)`.
- **Severity:** Critical

### 8.3 Fidget gesture-only views have no accessibility equivalents
- **Location:** `BubblePopView.swift`, `KineticSandView.swift`, `InfinityScrollView.swift`, `DoodlePadView.swift`
- **What:** All interactions are `DragGesture`/`onTapGesture` with no `accessibilityAction`. VoiceOver users can't use any fidget mode.
- **Why:** Four interaction modes completely blocked for assistive technology users.
- **Action:** Add `.accessibilityAction(.default)` to Canvas views. Convert DoodlePadView colors to accessible `Button` elements.
- **Severity:** High

### 8.4 52+ hardcoded font sizes without Dynamic Type scaling
- **Location:** 17+ files — `TransportControlsView.swift` (14), `OnboardingView.swift` (4), `PhonePlayerSettingsView.swift` (6), `WatchAppSettingsView.swift` (5), `ReaderTab.swift` (5), `PlayerPage.swift` (13 watchOS)
- **What:** `.font(.system(size: X))` without `relativeTo:` — text doesn't scale with Dynamic Type.
- **Why:** Users with larger text settings get unreadably small text. AX5 sizes cause clipped/overlapping layouts.
- **Action:** Add `.relativeTo(.body)` or switch to semantic fonts.
- **Severity:** High

### 8.5 Deep links route to placeholder views
- **Location:** `EchoCore/Models/NavigationDestinations.swift:28,30,42`
- **What:** `.settingsAppearance`, `.settingsAudio`, `.settingsProTranscripts` render `SettingsPlaceholder` ("coming soon"). Deep links from `echoaudio://` land on dead-ends.
- **Why:** Widget taps, external links arrive at non-functional screens with no content.
- **Action:** Extract real `SettingsAppearanceView` etc. from `SettingsView.swift` (they exist as private sub-views).
- **Severity:** High

### 8.6 TransportButton long-press unreachable via VoiceOver
- **Location:** `EchoCore/Views/TransportControlsView+LongPress.swift:85-132`
- **What:** `TransportPrimitiveButtonStyle` wraps in `Button(action: {})` with empty action. VoiceOver fires empty action — tap and long-press both unreachable.
- **Why:** VoiceOver users cannot activate transport buttons with configured long-press actions. Skip 30s, chapter navigation inaccessible.
- **Action:** Add `.accessibilityAction(named: "Activate")` and `.accessibilityAction(named: "Long Press")`.
- **Severity:** Critical

### 8.7 No iPad multitasking adaptation
- **Location:** Project-wide — zero `horizontalSizeClass`, `ViewThatFits`, `AnyLayout`, `containerRelativeFrame`
- **What:** iPad target but every layout assumes single portrait-iPhone width. In Split View, `minimumScrubberWidth: 210` leaves ~110pt for controls.
- **Why:** iPad users in Split View see broken, truncated layouts. HIG violation.
- **Action:** Add `@Environment(\.horizontalSizeClass)` checks. Use `ViewThatFits` for layout branching.
- **Severity:** High

### 8.8 OnboardingView is dead code
- **Location:** `EchoCore/Views/OnboardingView.swift`
- **What:** `OnboardingView` defined with `hasSeenOnboarding` AppStorage flag but never instantiated anywhere.
- **Why:** New users see blank first-launch with no orientation to the app's three core loops.
- **Action:** Present in `RootTabView.onAppear` when `hasSeenOnboarding` is false.
- **Severity:** High

### 8.9 Silent data loss on NoteEditorView/SchedulingSheet dismiss
- **Location:** `NoteEditorView.swift:49-50`, `SchedulingSheet.swift:112`
- **What:** "Cancel" calls `dismiss()` unconditionally. Typed text lost with no confirmation. SchedulingSheet `saveSession()` catches errors but dismisses anyway.
- **Why:** Minutes of typing lost on accidental Cancel. HIG data-loss anti-pattern.
- **Action:** Add `hasUnsavedChanges` state and confirmation alert. Show error alert on save failure.
- **Severity:** High

### 8.10 MacReaderFeedView duplicates iOS ReaderFeedViewModel logic inline
- **Location:** `Echo macOS/Views/MacReaderFeedView.swift:94-160`
- **What:** macOS reader duplicates ~70 lines of DB query, timeline cache building, and active-block tracking in View struct. iOS uses `ReaderFeedViewModel`.
- **Why:** Changes must be made in two places; macOS logic untestable without UI tests.
- **Action:** Share `ReaderFeedViewModel` with macOS target via `@Environment`.
- **Severity:** High

### 8.11 @State for reference-type ViewModel
- **Location:** `EchoCore/Views/ReaderTab.swift:12`, `EchoCore/Views/RootTabView.swift:22`
- **What:** `@State var viewModel: ReaderFeedViewModel?` — `@State` designed for value types; `@Observable` already provides change notification.
- **Why:** Semantic misuse; unnecessary indirection.
- **Action:** Change to plain stored property.
- **Severity:** Medium

### 8.12 Small touch targets below 44pt minimum
- **Location:** `UnifiedTopHeader.swift:23,58` (40×40), `DoodlePadView.swift:25` (28×28), `MacTriPaneView.swift:139` (28pt)
- **What:** Interactive elements below WCAG 44pt minimum.
- **Why:** Motor-impaired users have difficulty tapping small targets.
- **Action:** Use `.frame(minWidth: 44, minHeight: 44)`.
- **Severity:** Medium

---

## 9. Dead code / duplication / refactor

### 9.1 Files to delete
- `Shared/AnimationDurations.swift` — 30 lines, 9 constants, zero usages. All animations use inline literals. **Severity:** Medium.
- `docs/design-notes/NowPlayingTab_after.swift` (326 LOC), `NowPlayingTab_before.swift` (164 LOC) — stale design snapshots. Rename to `.txt` or delete. **Severity:** Low.

### 9.2 `"group.com.echo.audiobooks"` hardcoded (6 sites)
- **Locations:** `Haptic.swift:9`, `DoodlePadView.swift:65`, `SettingsManager.swift:380,385,591,594`, `FileLocations.swift:21`, `DatabaseService.swift:28`
- **Action:** Replace with `AppGroupDefaults.suiteName`. **Severity:** Medium.

### 9.3 Widget thumbnail downsampling duplicates ArtworkCache
- **Locations:** `Echo_Widget.swift:17-27`, `ArtworkCache.swift:21-28,73-82`
- **Action:** Extract shared `ImageDownsampling` utility into `Shared/`. **Severity:** Medium.

### 9.4 `resizedJPEGData` fileprivate in Bookmarks.swift
- **Location:** `EchoCore/Views/Bookmarks.swift:488-503`
- **Action:** Extract to `Shared/ImageProcessing.swift`. **Severity:** Low.

### 9.5 Oversized files (>500 LOC) — 16 files, proposed splits in report

### 9.6 One unresolved TODO: `EchoCoreApp.swift:26` — REFACTOR-TODO: replace static playerModel with @MainActor registry

### 9.7 Magic constants — ~40 animation duration literals, 3 JPEG qualities, 4 image dimensions, 3 timeout values

---

## 10. Cross-cutting recommendations

1. **Adopt `AsyncLoadState<T>` pattern** across all data-dependent views. StatsView, DeckListView, ReaderTab, EPUBHeadingPickerSheet all silently swallow errors with no retry. A consistent `.idle`/`.loading`/`.loaded(T)`/`.error(String)` enum gives users Retry buttons everywhere.

2. **Consistent `@MainActor` annotation.** Multiple types lack explicit annotation but are inferred as main-actor-isolated. Either annotate them explicitly or mark specific methods `nonisolated`.

3. **Add `deinit` to all timer-owning classes.** `WatchViewModel` (3 timers), `BookmarkStore`, `VoiceMemoRecorder`, `WatchVoiceMemoRecorder` all own repeating timers with no `deinit` invalidation.

4. **Replace `try?` with `do/catch`+log on persistence paths.** ~40 `try?` encode/decode sites silently discard errors. At minimum, log the `DecodingError`.

5. **Add unknown-case handling to all String enums decoded from stored data.** Six enums crash when future schema adds new cases. `case unknown(String)` pattern prevents backward-compatibility breaks.

6. **Set `keyDecodingStrategy = .convertFromSnakeCase` on JSONDecoders.** Zero of 29 decoder sites configure this. Any snake_case data source causes silent failures masked by `try?`.

7. **iPad adaptation.** The app declares iPad support but uses zero size-class checks. Add `ViewThatFits`, `AnyLayout`, and `@Environment(\.horizontalSizeClass)`.

---

## 11. What was NOT audited

- `Dead/` directory (intentional archive).
- Algorithmic correctness of Metal kernels / ML models (WhisperKit, Kokoro).
- Build settings / Xcode project structure beyond shared schemes.
- Third-party SPM dependency internals (GRDB, WhisperKit, FluidAudio).
- Tests — quick scan only; no deep coverage review.
- Localization and string catalogs — not assessed.
- StoreKit 2 product configuration in `.storekit` files.
- macOS app launch profiling — pending user consent for xctrace capture.
- End-to-end Audiobookshelf networking against real servers.

---

## 12. Verification

- **§5.1** — open `ABSEndpoints.swift`, lines 19-21, 25-27, 32-43. Seven `URL(string: ...)!` taking user-provided `base` without validation. `base` flows from `baseURL(from:)` which only trims whitespace (line 12).
- **§3.1** — open `PlayerLoadingCoordinator.swift`, lines 266 and 290. Both `Task {}` blocks have no `@MainActor` annotation and mutate `state` (`@MainActor @Observable PlaybackState`).
- **§5.2** — open `ContinuousAlignmentService.swift`, lines 75-87 and 129-131. `stop()` sets `whisperKit = nil` then spawns release Task. `loadModelIfNeeded()` calls `acquire()`. Race window between nil and release.
- **§6.1** — open `CloudKitSyncService.swift`, lines 84 and 146. No `accountStatus()` check before CloudKit operations. Caller at `EPUBAutoImportScanner.swift:176` uses `try?`.
- **§3.2** — open `NarrationExportService.swift`, lines 20, 96, 98. `NarrationFileNaming.chapterPrefix`, `AudioMarker()`, and `marker.writeChapters` inferred `@MainActor` but called from `actor` context.
- **§5.6** — open `StatsRepository.swift:348` vs `DailyReviewViewModel.swift:98`. Reader expects `intervalDays`; writer never includes it. Retention curve permanently empty.
- **§8.2** — open `HeadingCardCell.swift`. Zero `isAccessibilityElement`, `accessibilityLabel`, or `accessibilityTraits` in any EPUB reader cell subclass.

If any finding doesn't reproduce when you visit the line, flag it and I'll re-investigate.
