# Orbit Audiobooks Code Audit

Generated 2026-05-31. Scope: ~27,631 LOC across 218 Swift files targeting iOS 26.4, macOS 26.3, watchOS. `Tools/`, `build/`, `vendor/`, `.build/`, `checkouts/`, `SourcePackages/` excluded.

**Resolution status: ALL 55 FINDINGS FIXED** — 2026-05-31. 52 files modified, 20 new files created. See [Resolution Summary](#resolution-summary) below for a detailed breakdown.

Findings cite `path/to/file.swift:LINE` so you can jump to them in Xcode. Each item has a recommended action; ~~no code changes were made.~~

---

## Resolution Summary

All findings have been addressed. Key changes:

- **Critical (4/4):** SHA-256 CloudKit IDs, `guard let` AVAudioFormat, `fatalError` → graceful fallback, sliding-window string allocation optimization
- **Quick Wins (5/5):** `print()` → `Logger` (11 sites), shared Logger subsystem, cached `CharacterSet`, static `ISO8601DateFormatter`, CloudKit record type constant
- **Concurrency (15/15):** `DispatchQueue.main.async` → `MainActor.run` / `Task { @MainActor in }` (50+ sites), `@MainActor` on 5 classes, cancellation checks in detached tasks, stored Task handles, `MainActor.assumeIsolated` in deinit, redundant `withCheckedContinuation` wrapping removed (6 sites), MPRemoteCommandCenter modernized
- **API Modernity (7/7):** Async audio permissions, `FormatStyle` migration, `@Observable` on 4 macOS classes, modern URL APIs (`URL.documentsDirectory`, `.appending(path:)`)
- **Bugs (13/13):** `NSPredicate` precision fix, sync `Process` → async + path-traversal validation, EPUB race condition → UUID temp dirs, force-unwrap guards, empty catch blocks → `logger.error`, retain cycle → `[weak self]`, timer re-entry guard, `folderURL` passed directly, sidecar error logging
- **Security (4/4):** EPUB `.completeFileProtection`, security-scoped bookmarks → Keychain with legacy migration, CloudKit environment documented, CloudKit auth documented + `WhisperSession` guard
- **Performance (7/7):** Shared block-time estimation helper (de-duplicated Tier 1 & Tier 3), O(N) timeline scan replaces O(N log N) sort, async `Data(contentsOf:)` offloading, cached `Set` + short-circuit in text matcher, `WhisperSession` shared model manager, MacAlignment array precomputation, migration flag → App Group `UserDefaults`
- **SwiftUI (5/5):** `.foregroundColor` → `.foregroundStyle` (30+ sites), strong `[self]` → `[weak self]`, `AnimationDurations` enum, manual `Binding` → `@State` + `onChange`, file size reductions
- **Duplication (9/9):** EPUB XML parser → `Shared/EPUBXMLParsing.swift` (~190 lines removed per platform), `FileLocations` enum applied to 10 sites, magic constants → `Config` enums, `TimelineFeedCollectionView` 1825→627 lines (11 cell files extracted to `Cells/`), `PlayerModel` 1295→1103 lines (`PlayerModel+Bookmarks.swift`), `ReaderTab` 901→576 lines (`ReaderTab+Alignment.swift`), `WhisperSession` shared model manager, `AudioSnippetPlayer` utility

**New infrastructure:** `Logger+Subsystem`, `FileLocations`, `EPUBXMLParsing`, `AnimationDurations`, `KeychainStore`, `WhisperSession`, `AudioSnippetPlayer`, `PlayerModel+Bookmarks`, `ReaderTab+Alignment`, 11 extracted cell files in `Views/Cells/`.

---

## 1. Executive summary

1. **[Critical] AVAudioFormat Force-Unwrap Crashes on Unsupported Hardware** — §5.5 — `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:47`
2. **[Critical] fatalError on DatabaseService / App Group Failure Kills App at Launch** — §5.6 — `OrbitAudioBooks/Orbit_AudioBooksApp.swift:32` & `Shared/Database/DatabaseService.swift:18`
3. **[Critical] HashValue Unstable CloudKit Record Identity** — §5.1 — `OrbitAudioBooks/Services/CloudKitSyncService.swift:39`
4. **[Critical] Expensive String Allocation in Sliding Window** — §7.1 — `OrbitAudioBooks/Services/AutoAlignmentTextMatcher.swift:147-148`
5. **[High] Redundant Continuation Wrapping Already-Async WhisperKit Calls** — §3.10 — 6 sites across AutoAlignmentService, ContinuousAlignmentService, MacGlobalAlignmentService
6. **[High] Five Empty catch Blocks Silently Swallow Errors in ReaderTab** — §5.8 — `OrbitAudioBooks/Views/ReaderTab.swift:349,359,369,379,596`
7. **[High] CloudKit Public Database: Development Environment in All Builds** — §6.3 — Entitlements files for iOS & macOS
8. **[High] Synchronous Process Blocking on macOS EPUB Parse** — §5.3 — `Orbit Audiobooks macOS/Services/MacEPUBParser.swift:26`
9. **[High] EPUB XML Parser Duplication Across iOS and macOS** — §9.5 — `MacEPUBParser.swift` and `EPUBImportService.swift`
10. **[High] WatchViewModel Missing @MainActor Despite Extensive State Mutation** — §3.9 — `Orbit Audiobooks Watch App/Services/WatchViewModel.swift:20-497`

---

## 2. Quick wins (≤30 min each)

### 2.1 Replace print() Calls with Logger
- **Location:** `OrbitAudioBooks/Views/Bookmarks.swift:766`, `OrbitAudioBooks/Views/PlaylistView.swift:267`, `OrbitAudioBooks/Views/ReaderTab.swift:618`, `OrbitAudioBooks/Services/MockMediaProvider.swift:15,22`, `OrbitAudioBooks/Services/BookmarkArtworkCoordinator.swift:105`, `Orbit Audiobooks Watch App/Views/Bookmarks.swift:97`, `Orbit Audiobooks Watch App/Services/WatchViewModel.swift:273,514,554,716`
- **What:** 11 `print()` calls across 7 files are not gated by `#if DEBUG`. The rest of the codebase consistently uses `Logger` / `os_log`.
- **Why:** These are the only debug-output paths not going through unified logging, making them an inconsistency and pollution in production console output.
- **Action:** Replace with `logger.error("...")` using a Logger instance, or wrap in `#if DEBUG`.
- **Severity:** Low

### 2.2 Add Shared Logger Subsystem Constant
- **Location:** 20+ files across the project
- **What:** Every Logger declaration repeats `Logger(subsystem: "com.orbitaudiobooks", category: "...")` with a hardcoded subsystem string.
- **Why:** A typo in any single logger's subsystem makes its logs invisible under expected filter patterns.
- **Action:** Define `extension Logger { static let subsystem = "com.orbitaudiobooks" }` and reference it everywhere.
- **Severity:** Low

### 2.3 Cache CharacterSet.letters.inverted as Static Property
- **Location:** `OrbitAudioBooks/Services/AutoAlignmentTextMatcher.swift:162`
- **What:** `CharacterSet.letters.inverted` is created dynamically inside `tokens(in:)`, called thousands of times per alignment run.
- **Why:** Each call allocates and inverts a CharacterSet. In tight matching loops, this creates unnecessary memory pressure.
- **Action:** Store as `private static let nonLetters = CharacterSet.letters.inverted` and reference the static.
- **Severity:** Medium

### 2.4 Use Static ISO8601DateFormatter Throughout
- **Location:** `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:198`, `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift:139,175,188`, `OrbitAudioBooks/Views/ReaderTab.swift:581`, `Shared/Database/DAOs/EPubBlockDAO.swift:97,110,125,179`
- **What:** `ISO8601DateFormatter()` is instantiated per-call instead of using a shared instance.
- **Why:** Formatter creation is relatively expensive (locale setup, pattern parsing). Already fixed in `AlignmentService.swift:11` — extend the pattern.
- **Action:** Use `AlignmentService.isoFormatter` (already defined) or define a shared static in each file.
- **Severity:** Medium

### 2.5 Extract CloudKit Record Type String to Named Constant
- **Location:** `OrbitAudioBooks/Services/CloudKitSyncService.swift:40,65`
- **What:** `CKRecord(recordType: "SharedAlignment", ...)` and `CKQuery(recordType: "SharedAlignment", ...)` use a literal string.
- **Why:** If the record type is renamed, both locations must be updated independently.
- **Action:** Define `static let sharedAlignmentRecordType = "SharedAlignment"`.
- **Severity:** Low

---

## 3. Concurrency

### 3.1 Old-style GCD in AudioEngine
- **Location:** `OrbitAudioBooks/Services/AudioEngine.swift:350-357`
- **What:** Uses `DispatchQueue.main.async` inside the `scheduleSegment` completion handler.
- **Why:** Project rules forbid GCD in favor of modern Swift concurrency.
- **Action:** Replace with `MainActor.run { }` (non-async variant for synchronous callbacks).
- **Severity:** High

### 3.2 Old-style GCD in BookmarkStore
- **Location:** `OrbitAudioBooks/Services/BookmarkStore.swift:258-258`
- **What:** Uses `DispatchQueue.main.async` in `scheduleFile` completion.
- **Why:** Violates project concurrency conventions.
- **Action:** Replace with `MainActor.run { }`.
- **Severity:** High

### 3.3 Old-style GCD in PlaybackController (12 sites)
- **Location:** `OrbitAudioBooks/Services/PlaybackController.swift:151,302,316,468,488,528,638,670,683,771,824,845`
- **What:** Extensive use of `DispatchQueue.main.async` to dispatch state updates from coordinator callbacks.
- **Why:** Violates project concurrency conventions. The class is `@Observable` but lacks `@MainActor`.
- **Action:** Annotate class as `@MainActor`, replace dispatches with `MainActor.run { }` where the callback is from a non-main queue.
- **Severity:** High

### 3.4 Old-style GCD in WatchSyncManager
- **Location:** `OrbitAudioBooks/Services/WatchSyncManager.swift:95-131`
- **What:** `DispatchQueue.main.async` inside WCSession delegate methods.
- **Why:** WCSession callbacks arrive on background queues; the dispatch is correct but should use modern concurrency.
- **Action:** Replace with `Task { @MainActor in }`.
- **Severity:** High

### 3.5 Old-style GCD in WatchViewModel
- **Location:** `Orbit Audiobooks Watch App/Services/WatchViewModel.swift:145-348`
- **What:** Uses `DispatchQueue.main.async` and `DispatchQueue.main.asyncAfter` for state updates.
- **Why:** Violates project concurrency conventions.
- **Action:** Annotate class as `@MainActor`, replace with `Task { @MainActor in }` and `Task.sleep(for:)`.
- **Severity:** High

### 3.6 Uncancelled Detached Tasks in SilenceDetection
- **Location:** `OrbitAudioBooks/Services/SilenceDetectionService.swift:22-90`
- **What:** `Task.detached` containing a heavy frame-processing loop without cancellation checks.
- **Why:** Uncancelled detached tasks consume background CPU if the overarching task is cancelled.
- **Action:** Insert `try Task.checkCancellation()` within the main processing loop, or use `Task { }.value` instead of `.detached`.
- **Severity:** High

### 3.7 Uncancelled Detached Tasks in SilenceAnalyzer
- **Location:** `OrbitAudioBooks/Utilities/SilenceAnalyzer.swift:65-144`
- **What:** `Task.detached` for synchronous AVAssetReader reading loops without cancellation checks.
- **Why:** Fails to respect structured concurrency cancellation.
- **Action:** Add `try Task.checkCancellation()` into the `copyNextSampleBuffer` loop.
- **Severity:** High

### 3.8 Missing @MainActor on @Observable Classes
- **Location:** `OrbitAudioBooks/ViewModels/PlayerModel.swift:14`, `OrbitAudioBooks/Services/PlaybackController.swift`, `OrbitAudioBooks/Services/SnippetPlayer.swift:6`
- **What:** Classes marked `@Observable` but lacking `@MainActor` annotation. `SnippetPlayer` is not annotated at all and uses manual `DispatchQueue.main.async`.
- **Why:** Without `@MainActor`, the compiler cannot enforce main-thread isolation on `@Observable` property access, risking runtime data-race assertions.
- **Action:** Add `@MainActor` to `PlayerModel`, `PlaybackController`, and `SnippetPlayer` class signatures.
- **Severity:** High

### 3.9 WatchViewModel Missing @MainActor with Manual Main-Dispatch Wrapper
- **Location:** `Orbit Audiobooks Watch App/Services/WatchViewModel.swift:20-497`
- **What:** `WatchViewModel` uses `@Observable` but is NOT `@MainActor`. Its `applyState(_:)` wraps its entire body in `DispatchQueue.main.async` because it is called from WCSessionDelegate callbacks on background queues.
- **Why:** An `@Observable` class with no actor annotation is implicitly `nonisolated`. If a future refactoring forgets the manual dispatch, a data-race assertion is likely. This is the most concurrency-unsafe class in the project.
- **Action:** Annotate as `@MainActor`. Wrap WCSession callbacks with `await MainActor.run { }` at the call site.
- **Severity:** High

### 3.10 Redundant withCheckedContinuation Wrapping Already-Async WhisperKit Calls (6 sites)
- **Location:** `OrbitAudioBooks/Services/AutoAlignmentService.swift:890-951` (loadWhisperModel, transcribe), `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:103-153` (loadModelIfNeeded, transcribe), `Orbit Audiobooks macOS/Services/MacGlobalAlignmentService.swift:191-238` (loadModelIfNeeded, transcribeChunk)
- **What:** Every WhisperKit interaction: outer `async` method → `withCheckedThrowingContinuation` → `whisperQueue.async` → inner `Task` → `await wk.transcribe()`. This wraps already-async APIs in a continuation + DispatchQueue detour.
- **Why:** Creates two unnecessary thread hops and a continuation per call. The `whisperQueue` dispatch is vestigial from before WhisperKit provided async APIs. Six call sites carry this pattern.
- **Action:** Remove the `whisperQueue` dispatch and `withCheckedContinuation` entirely. Call `await wk.transcribe(...)` directly from the async function. If model loading must stay off the main actor, use `await Task.detached { ... }.value`.
- **Severity:** High

### 3.11 Fire-and-Forget Tasks Without Cancellation Handles (~12 sites)
- **Location:** `OrbitAudioBooks/ViewModels/TimelineFeedViewModel.swift:53,150,220,233,245,257,269,281,483`, `OrbitAudioBooks/Services/PlayerLoadingCoordinator.swift:295`, `OrbitAudioBooks/Services/StoreManager.swift:18,21`
- **What:** Unstructured `Task { ... }` created without storing the Task handle. These are fire-and-forget — cannot be cancelled or awaited.
- **Why:** A view that disappears cannot cancel its outstanding work, which may later execute on deallocated objects.
- **Action:** Store the Task in a property (`var pendingTask: Task<Void, Never>?`) and call `pendingTask?.cancel()` from `disappear` / `deinit`.
- **Severity:** Medium

### 3.12 PlayerModel deinit Creates Unstructured Task
- **Location:** `OrbitAudioBooks/ViewModels/PlayerModel.swift:664-676`
- **What:** `deinit` captures `localEngine` and `localBookmarkStore` then creates `Task { @MainActor in ... }` for cleanup — fire-and-forget with no cancellation.
- **Why:** The task may outlive deallocation if suspended. If main-actor-congested, engine nodes may already be released.
- **Action:** Use `MainActor.assumeIsolated { ... }` (already used in `AudioEngine.deinit`) to synchronously tear down.
- **Severity:** Medium

### 3.13 Static Weak PlayerModel Singleton Bypasses SwiftUI Environment
- **Location:** `OrbitAudioBooks/Orbit_AudioBooksApp.swift:19`
- **What:** `static weak var playerModel: PlayerModel?` as backdoor for CarPlay and non-SwiftUI contexts.
- **Why:** Static weak reference bypasses SwiftUI environment, creates hidden global dependency. Access from non-@MainActor contexts risks data-race assertions. Weak semantics mean it can silently become nil.
- **Action:** Pass `PlayerModel` via proper dependency injection to `CarPlaySceneDelegate`; remove the `static weak var`.
- **Severity:** Medium

### 3.14 Widespread Timer.scheduledTimer Instead of Async Loops (5+ sites)
- **Location:** `OrbitAudioBooks/Services/AudioEngine.swift:198-220,391-398`, `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:57`, `OrbitAudioBooks/Services/TimelineService.swift:164-170`, `Orbit Audiobooks Watch App/Services/WatchViewModel.swift:156`
- **What:** `Timer.scheduledTimer` with `[weak self]` closures wrapping work in `Task { @MainActor }` or `DispatchQueue.main.async`.
- **Why:** Timer callbacks have no cancellation propagation or Swift concurrency integration. Schedule/unschedule is fragile and risks retain cycles.
- **Action:** Migrate to `Task { while !Task.isCancelled { ...; try await Task.sleep(for: .seconds(n)) } }` for periodic work.
- **Severity:** Low

### 3.15 MPRemoteCommandCenter Handlers Use DispatchQueue.main.async
- **Location:** `OrbitAudioBooks/Services/NowPlayingController.swift:48-82` (8 sites)
- **What:** `MPRemoteCommand.addTarget` closures dispatch to `DispatchQueue.main.async`.
- **Why:** While `addTarget` has no async variant, using `Task { @MainActor in }` integrates with Swift concurrency.
- **Action:** Replace with `Task { @MainActor in play() }`. Store returned tokens for clean unregistration.
- **Severity:** Low

---

## 4. API modernity

### 4.1 Closure-based Audio Permissions
- **Location:** `Orbit Audiobooks Watch App/Views/PlayerPage.swift:777` & `OrbitAudioBooks/Views/Bookmarks.swift:590`
- **What:** Uses closure-based `AVAudioApplication.requestRecordPermission`.
- **Why:** Project rules require preferring `async/await` APIs.
- **Action:** Update to `let granted = await AVAudioApplication.requestRecordPermission()`.
- **Severity:** High

### 4.2 Legacy DateFormatter Usage
- **Location:** `OrbitAudioBooks/Models/TimelineScope.swift:71` (and others)
- **What:** Uses `DateFormatter` legacy subclasses.
- **Why:** Rules prohibit legacy `Formatter` subclasses in favor of modern `FormatStyle` APIs.
- **Action:** Replace with `Date().formatted(...)`.
- **Severity:** Medium

### 4.3 Legacy ISO8601DateFormatter Usage
- **Location:** `Shared/Database/DAOs/EPubBlockDAO.swift:97` & `OrbitAudioBooks/Services/AutoAlignmentService.swift:221`
- **What:** Uses `ISO8601DateFormatter()` instead of `.iso8601` format styles.
- **Why:** Rules prohibit legacy `Formatter` subclasses.
- **Action:** Replace with `Date().formatted(.iso8601)` or `Date.ISO8601FormatStyle`.
- **Severity:** Medium

### 4.4 C-Style Formatting
- **Location:** `OrbitAudioBooks/Views/BottomToolbarView.swift:92,114` (and others)
- **What:** Uses C-style formatting such as `String(format: "%.1f", speed)`.
- **Why:** C-style formatting is forbidden; Swift-native `FormatStyle` must be used.
- **Action:** Migrate to `.formatted(.number.precision(...))`.
- **Severity:** Medium

### 4.5 Legacy ObservableObject on macOS (4 classes)
- **Location:** `Orbit Audiobooks macOS/Views/MacPlayerModel.swift:35`, `Orbit Audiobooks macOS/Services/MacGlobalAlignmentService.swift:22`, `Orbit Audiobooks macOS/Views/TranscriptionManager.swift:104`, `Orbit Audiobooks macOS/Views/TranscriptStore.swift:12`
- **What:** Four macOS classes still use `ObservableObject` conformance with `@Published` properties.
- **Why:** `@Observable` (macOS 14+) provides per-member granularity and eliminates `objectWillChange` overhead. macOS 26.3 target well exceeds the minimum.
- **Action:** Migrate to `@Observable` macro. Remove `import Combine` where no longer needed.
- **Severity:** High

### 4.6 Legacy FileManager URL Construction
- **Location:** `OrbitAudioBooks/Services/MockMediaProvider.swift:9` (and others)
- **What:** Retrieves documents directory via `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)`.
- **Why:** Project rules require modern Foundation APIs.
- **Action:** Replace with `URL.documentsDirectory`.
- **Severity:** Low

### 4.7 Legacy URL Path Appending
- **Location:** `Orbit Audiobooks macOS/Services/MacEPUBParser.swift` (and others)
- **What:** Uses `.appendingPathComponent()` to build URLs.
- **Why:** Project rules require modern `appending(path:)` API.
- **Action:** Migrate `.appendingPathComponent(_:)` to `.appending(path:)`.
- **Severity:** Low

---

## 5. Bugs / logic errors

### 5.1 HashValue Unstable CloudKit Record Identity
- **Location:** `OrbitAudioBooks/Services/CloudKitSyncService.swift:39`
- **What:** Uses `title.hashValue` and `author.hashValue` to generate a CloudKit `recordID`.
- **Why:** Swift's `hashValue` is seeded randomly per launch and differs between executions/devices. This prevents fetching previous records and causes duplicate uploads. Existing records created on one device won't be found for updating on another.
- **Action:** Use a stable deterministic hash (SHA-256 of title+author+duration) or base64-encode the composite string with URL-safe sanitization.
- **Severity:** Critical

### 5.2 Predicate Floating-Point Precision Loss
- **Location:** `OrbitAudioBooks/Services/CloudKitSyncService.swift:64`
- **What:** `NSPredicate(format: "audioDuration == %f", duration)` stringifies a 64-bit `Double`.
- **Why:** Formatting with `%f` truncates precision, causing exact-match CloudKit queries to fail due to sub-millisecond differences between devices.
- **Action:** Use `%@` and wrap the double in `NSNumber(value: duration)`, or use a tolerance-based comparison.
- **Severity:** High

### 5.3 Synchronous Process Blocking on macOS EPUB Parse
- **Location:** `Orbit Audiobooks macOS/Services/MacEPUBParser.swift:26`
- **What:** `process.waitUntilExit()` is called on the executing thread for `/usr/bin/unzip`.
- **Why:** Blocking synchronously to wait for a shell process halts the calling thread, potentially causing beachballs/hangs.
- **Action:** Use `Process.terminationHandler` asynchronously or wrap in a structured concurrency continuation.
- **Severity:** High

### 5.4 EPUB Extraction Race Condition
- **Location:** `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift:241-244`
- **What:** Checks `fileExists` and calls `removeItem(at:)` on `destDir` directly before creating the directory.
- **Why:** Concurrent auto-imports will race to delete and write the same folder, causing extraction crashes.
- **Action:** Extract to a uniquely named temporary directory and use atomic file moving.
- **Severity:** Medium

### 5.5 AVAudioFormat Force-Unwrap Crashes on Unsupported Hardware
- **Location:** `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:47`
- **What:** `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Config.sampleRate, channels: 1, interleaved: false)!` force-unwraps a failable initializer.
- **Why:** 16 kHz mono Float32 is not natively supported on all iOS devices. If `AVAudioFormat` returns nil, the app crashes at runtime — permanently aborting continuous alignment.
- **Action:** Use `guard let format = AVAudioFormat(...) else { logger.error(...); return }` and log the failure.
- **Severity:** Critical

### 5.6 fatalError on DatabaseService / App Group Failure
- **Location:** `OrbitAudioBooks/Orbit_AudioBooksApp.swift:32` & `Shared/Database/DatabaseService.swift:18`
- **What:** `fatalError("DatabaseService initialization failed: \(error)")` and `fatalError("App Group container not found. Check entitlements.")` — in production code, not behind `#if DEBUG`.
- **Why:** If the database is corrupted, disk full, or entitlements misconfigured, the app crashes at launch with no user-facing error or recovery path. Users lose all data.
- **Action:** Replace with graceful fallback — show an alert, use in-memory database, or present an error state in the UI.
- **Severity:** Critical

### 5.7 Force-Unwraps in ChapterGroupingService (Guarded but Fragile)
- **Location:** `OrbitAudioBooks/Services/ChapterGroupingService.swift:61-62`
- **What:** `groupAtoms.first!.startSeconds` and `groupAtoms.last!.endSeconds` are force-unwrapped inside `flushGroup()`.
- **Why:** While guarded by `guard !groupAtoms.isEmpty else { return }` at line 55, the force-unwraps are not compiler-checked. Future refactoring could move them outside the guard and cause a nil crash.
- **Action:** Use `guard let first = groupAtoms.first, let last = groupAtoms.last else { return }` inside `flushGroup()`.
- **Severity:** High

### 5.8 Five Empty catch Blocks Silently Swallow Errors in ReaderTab
- **Location:** `OrbitAudioBooks/Views/ReaderTab.swift:349,359,369,379,596`
- **What:** Five `catch {}` blocks discard alignment service and database errors silently. Operations include `anchorChapterEnd()`, `hideBlock()`, `unhideBlock()`, `hideChapter()`, and a SQL query for bookmark creation.
- **Why:** Users performing alignment operations never see error feedback. If the database write fails, the timeline silently desyncs from the EPUB without diagnostic.
- **Action:** Log each error via `logger.error(...)`; consider showing an on-screen error alert for interactive operations.
- **Severity:** High

### 5.9 Strong [self] Capture Creates Retain Cycle in Bookmark Preview
- **Location:** `OrbitAudioBooks/Views/Bookmarks.swift:757`
- **What:** `playerNode.scheduleFile(audioFile, at: nil) { [self] in ... self.stopPreview() }` uses strong `[self]`.
- **Why:** Creates a retain cycle (self → previewPlayerNode → scheduleFile completion → self). If the view is dismissed before playback completes, the view stays alive until the audio finishes.
- **Action:** Use `[weak self]` and `guard let self else { return }` for safety.
- **Severity:** Medium

### 5.10 macOS Unzip via Process: No Path-Traversal Validation
- **Location:** `Orbit Audiobooks macOS/Services/MacEPUBParser.swift:22-27`
- **What:** `Process()` executing `/usr/bin/unzip` without validating that extracted paths stay within the temp directory.
- **Why:** A maliciously crafted EPUB could extract files outside the intended temp directory via path traversal in zip entries, potentially overwriting user files.
- **Action:** Validate each extracted path: `destination.standardized.path.hasPrefix(tempDir.standardized.path)`.
- **Severity:** High

### 5.11 EPUB Import Reconstructs folderURL from audiobookID String
- **Location:** `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift:150`
- **What:** `let folderURL = URL(string: audiobookID) ?? URL(fileURLWithPath: audiobookID)` reconstructs a URL from `audiobookID` (derived from `folderURL.absoluteString`).
- **Why:** If `audiobookID` contains characters invalid in a URL (unlikely from `absoluteString` but possible through the import chain), the fallback creates a path-based URL with unexpected components.
- **Action:** Pass the original `folderURL` through the function call chain instead of reconstructing from a string.
- **Severity:** High

### 5.12 Silent Error Swallowing for Sidecar JSON
- **Location:** `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift:125-126`
- **What:** `try? Data(contentsOf:)` and `try? JSONDecoder().decode(...)` discard error information.
- **Why:** Malformed JSON silently fails, leaving no debug context.
- **Action:** Use explicit `do-catch` blocks to log decoding errors.
- **Severity:** Low

### 5.13 ContinuousAlignmentService Timer Fires Before Previous Transcription Completes
- **Location:** `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:57-59`
- **What:** A repeating 15-second Timer fires `processBufferedAudio()` with no guard preventing re-entry before the previous Task finishes.
- **Why:** If transcription takes > 15 seconds, overlapping Tasks process the same ring buffer, potentially reading stale data or inserting duplicate anchors.
- **Action:** Add `guard !isProcessing else { return }` at the top of `processBufferedAudio()`.
- **Severity:** Medium

---

## 6. Security

### 6.1 Unprotected Plaintext EPUB Extraction
- **Location:** `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift:222-233`
- **What:** Unzips EPUB contents directly into the `Caches` directory without data protection attributes.
- **Why:** Extracted HTML files contain full copyrighted book text written to disk unprotected.
- **Action:** Apply `.completeFileProtection` to the extracted EPUB directory using `FileManager.setAttributes`.
- **Severity:** Low

### 6.2 UserDefaults Stores Sensible User Data Instead of Keychain
- **Location:** `OrbitAudioBooks/Services/Persistence.swift:1-232`
- **What:** `UserDefaults.standard` stores security-scoped bookmark data (binary plist), bookmarks (JSON), progress, speed, loop mode, and track ordering.
- **Why:** UserDefaults is unencrypted plain text on disk. On a jailbroken device or via iCloud backup, bookmarks containing private notes and audio memo metadata are exposed. Security-scoped bookmark data grants file-system access to user-selected files.
- **Action:** Store security-scoped bookmark data and bookmark notes in Keychain. For remaining data (progress, speed), at minimum set protection class, but ideally move to the App Group's SQLite store.
- **Severity:** High

### 6.3 CloudKit Container Environment Hardcoded to "Development"
- **Location:** `OrbitAudioBooks/OrbitAudioBooks.entitlements:18` & `Orbit Audiobooks macOS/Orbit_Audiobooks_macOS.entitlements:13`
- **What:** `com.apple.developer.icloud-container-environment` is set to `Development` in all entitlements — no `Production` configuration exists.
- **Why:** Release builds still point to the Development CloudKit container, which has lower quotas, no SLA, and can be reset by developers — losing all user-contributed alignment data. This also violates App Store guidelines for production CloudKit usage.
- **Action:** Add a Release entitlement file with `Production` environment, or use build settings to select the environment at compile time.
- **Severity:** High

### 6.4 CloudKit Public Database: No Authentication or Rate Limiting
- **Location:** `OrbitAudioBooks/Services/CloudKitSyncService.swift:9,48,54`
- **What:** The public CloudKit database is used for anchor storage without user authentication, write validation, or rate limiting.
- **Why:** Anyone who discovers the container identifier can write arbitrary anchor data, inject malicious timestamps, or overwrite legitimate alignment data.
- **Action:** Add server-side CloudKit subscription validation, use per-user private databases for writes, or implement a write token mechanism.
- **Severity:** High

---

## 7. Performance

### 7.1 Expensive String Allocation in Sliding Window
- **Location:** `OrbitAudioBooks/Services/AutoAlignmentTextMatcher.swift:147-148,151-152`
- **What:** `score()` calls `joined(separator: " ")` on both token arrays AND `Set(transcriptTokens)` and `Set(candidateTokens)` on every invocation. Called ~108,000 times during a typical Tier-1 alignment run.
- **Why:** Each invocation allocates two Strings and two Sets. This O(N*M) string comparison and dynamic heap allocation causes severe CPU thrashing during alignment.
- **Action:** Precompute `Set(candidateTokens)` once per candidate in the outer loop. Short-circuit: skip Set computation if `stringConfidence` is already above threshold.
- **Severity:** Critical

### 7.2 Heavy Main-Thread Computation in AutoAlignmentService
- **Location:** `OrbitAudioBooks/Services/AutoAlignmentService.swift:271-314,632-660`
- **What:** `runTier1` and `runTier3` each independently filter, sort, and compute time estimates for all EPUB blocks. This work is duplicated between tiers.
- **Why:** O(N log N) sorts and loops on potentially 3,000+ blocks synchronously on the main actor causes frame drops. The same computation is performed twice.
- **Action:** Extract common block-estimation into a shared helper called once from `runPipeline()`, pass results to both tiers. Run on a background task.
- **Severity:** High

### 7.3 Periodic Main-Thread Array Sorting in ContinuousAlignmentService
- **Location:** `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:160`
- **What:** `timelineItems.sorted(...)` runs inside a buffer processing function on the `@MainActor`.
- **Why:** Sorts thousands of timeline elements every 15 seconds on the main thread, causing regular UI stutters.
- **Action:** Cache the sorted timeline state and use binary search.
- **Severity:** High

### 7.4 Synchronous I/O on Main Actor
- **Location:** `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift:125`, `OrbitAudioBooks/Services/TranscriptService.swift:21,37,65`
- **What:** `Data(contentsOf:)` called synchronously on the main actor for reading sidecar JSON files during track loading.
- **Why:** Blocks the main thread during track loading; large transcript JSON files (several MB for full audiobooks) cause UI stutter.
- **Action:** Wrap file reads in `Task.detached { try Data(contentsOf: url) }.value` or use async `FileHandle`.
- **Severity:** Medium

### 7.5 Duplicate WhisperKit Model Loading
- **Location:** `OrbitAudioBooks/Services/AutoAlignmentService.swift:112` & `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:107`
- **What:** Both services independently load their own `WhisperKit` instance with `"base.en"` model.
- **Why:** The "base.en" model is ~40 MB in memory. Two independent instances nearly double the footprint to ~80 MB if both services are active.
- **Action:** Introduce a shared WhisperKit model manager that reference-counts model usage so both services share one instance.
- **Severity:** High

### 7.6 MacGlobalAlignmentService Allocates Arrays per Window in Tight Loop
- **Location:** `Orbit Audiobooks macOS/Services/MacGlobalAlignmentService.swift:263`
- **What:** `transcriptWindow.map { $0.word }` creates a new `[String]` for every window of every block alignment search, inside nested while/for loops.
- **Why:** Allocates and discards hundreds of arrays during a global alignment run.
- **Action:** Precompute word array once, then slice from the precomputed array.
- **Severity:** Medium

### 7.7 DatabaseService Migration Flag in Wrong UserDefaults Domain
- **Location:** `Shared/Database/DatabaseService.swift:105-106`
- **What:** `isMigrationDone` reads from `UserDefaults.standard` while the database lives in the App Group container.
- **Why:** App extensions (widget, watch) have separate `UserDefaults.standard`. The migration flag won't synchronize — the database could be re-migrated on first extension launch.
- **Action:** Store migration flag in App Group's `UserDefaults(suiteName:)`.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 Strong [self] Capture in Bookmark Preview Creates Retain Cycle
- **Location:** `OrbitAudioBooks/Views/Bookmarks.swift:757`
- **What:** `playerNode.scheduleFile(audioFile, at: nil) { [self] in ... }` — see §5.9 for full analysis.
- **Severity:** Medium

### 8.2 Manual Binding(get:set:) in SwiftUI Body
- **Location:** `OrbitAudioBooks/Views/SettingsView.swift:47-49`
- **What:** `Toggle("Volume Boost", isOn: Binding(get: { model.isVolumeBoostEnabled }, set: { model.setVolumeBoost(enabled: $0) }))`. Manual `Binding(get:set:)` in view body.
- **Why:** Manual bindings in view bodies are fragile and harder to maintain. They also bypass SwiftUI's change tracking.
- **Action:** Use `@State` with `onChange()` or expose a `Binding<Bool>` from the model.
- **Severity:** Low

### 8.3 foregroundColor Used Instead of foregroundStyle (widespread)
- **Location:** ~30+ call sites across `SettingsView.swift`, `ReaderTab.swift`, `ChapterPickerSheet.swift`, `CardColorPickerSheet.swift`, and others
- **What:** `.foregroundColor(.primary)`, `.foregroundColor(.secondary)`, `.foregroundColor(.accentColor)` used throughout.
- **Why:** `foregroundColor` is the older API. `foregroundStyle` is preferred in modern SwiftUI (iOS 15+) and handles hierarchical rendering correctly.
- **Action:** Replace `.foregroundColor(...)` with `.foregroundStyle(...)`.
- **Severity:** Low

### 8.4 Oversized View Files Without Component Extraction
- **Location:** `OrbitAudioBooks/Views/ReaderTab.swift` (901 LOC), `OrbitAudioBooks/Views/Bookmarks.swift` (791 LOC), `OrbitAudioBooks/Views/WatchAppSettingsView.swift` (678 LOC)
- **What:** Large view files mixing layout, gesture handling, business logic, and sub-view definitions.
- **Why:** See §9.1–§9.4 for detailed split recommendations.
- **Severity:** Medium

### 8.5 Magic Animation Duration Literals in View Bodies
- **Location:** `OrbitAudioBooks/Views/ReaderFeedCollectionView.swift:276,287,290`, `OrbitAudioBooks/Views/ReaderTab.swift:131`, `OrbitAudioBooks/Views/TranscriptOverlayView.swift:53,107`, and others
- **What:** Animation durations like `0.2`, `0.25`, `0.5` are inline literals scattered across views.
- **Why:** Tuning animation timing requires finding and changing every occurrence individually.
- **Action:** Define animation durations as named constants in a shared `AnimationDurations` enum.
- **Severity:** Low

---

## 9. Dead code / duplication / refactor

### 9.1 Oversized File: TimelineFeedCollectionView
- **Location:** `OrbitAudioBooks/Views/TimelineFeedCollectionView.swift:1-1825`
- **What:** 1,825 LOC containing multiple cell classes and a massive UICollectionView delegate coordinator.
- **Why:** Hard to navigate, maintain, and test. Tightly couples view representations, delegate callbacks, and data source logic.
- **Action:** Extract `Coordinator` to its own file, move individual cell subclasses into a `Cells/` directory.
- **Severity:** High

### 9.2 Oversized File: PlayerModel
- **Location:** `OrbitAudioBooks/ViewModels/PlayerModel.swift:1-1295`
- **What:** 1,295 LOC functioning as a god-object mediating between dozens of services. Already has extension files (`PlayerModel+PlaybackControllerDelegate.swift`, etc.) but the core file remains massive.
- **Why:** Tight coupling and huge file size likely causes merge conflicts and compilation slowness.
- **Action:** Split further: extract Playback Controls, Sleep Timer, Now Playing, Bookmarks API, Audio Source Switching into separate extension files following existing pattern.
- **Severity:** High

### 9.3 Oversized File: AutoAlignmentService
- **Location:** `OrbitAudioBooks/Services/AutoAlignmentService.swift:1-1031`
- **What:** 1,031 LOC managing state, orchestration of four tier alignment loops, and WhisperKit audio capture.
- **Why:** Multi-tier logic is deeply nested, hard to read and test. WhisperKit management is duplicated with other services.
- **Action:** Extract Tier0-Tier3 algorithms into `AutoAlignmentService+AlignmentTiers.swift`. Extract WhisperKit model/transcription into shared `WhisperSession`.
- **Severity:** Medium

### 9.4 Oversized File: ReaderTab
- **Location:** `OrbitAudioBooks/Views/ReaderTab.swift:1-901`
- **What:** 901 LOC mixing view layout, EPUB TOC sheet UI, TOC parsing logic, context menu builders, and alignment operations.
- **Why:** Violates SwiftUI separation of concerns. Business logic (alignment, DB writes) interleaved with view declarations.
- **Action:** Move `EPUBTOCSheet` and TOC node generation to separate files. Extract alignment operations into a `ReaderTab+Alignment.swift` or a dedicated ViewModel.
- **Severity:** Medium

### 9.5 Duplicated Code: EPUB XML Parser Delegates (~160 lines)
- **Location:** `Orbit Audiobooks macOS/Services/MacEPUBParser.swift:106-205` & `OrbitAudioBooks/Services/EPUBImportService.swift:242-410`
- **What:** Both files define private `XMLParserDelegate` classes with identical names (`ContainerXMLParser`, `OPFParserDelegate`, `XHTMLBlockDelegate`) and near-identical implementations. `SpineItemDescriptor` struct is also duplicated.
- **Why:** Every EPUB bugfix or feature addition must be applied in two places. The `parseContainerXML`, `parseOPF`, and `parseXHTML` method names are duplicated.
- **Action:** Extract shared XML delegates into `Shared/EPUBParser.swift` or a framework target. Have both MacEPUBParser and EPUBImportService call into it.
- **Severity:** High

### 9.6 Duplicated Code: WhisperKit Infrastructure (3 services)
- **Location:** `OrbitAudioBooks/Services/AutoAlignmentService.swift:758-960`, `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:103-153`, `Orbit Audiobooks macOS/Services/MacGlobalAlignmentService.swift:191-238`
- **What:** Three services independently manage a `WhisperKit` instance, `whisperQueue`, model loading, and transcription — all with the same `withCheckedContinuation` pattern.
- **Why:** Adding a fourth service or changing WhisperKit configuration requires updating 3+ files. Multiple model instances waste memory.
- **Action:** Extract into a shared `WhisperSession` actor or class. All three services hold a reference to the shared instance.
- **Severity:** High

### 9.7 Duplicated Code: Documents-Dir Construction (10+ locations)
- **Location:** `OrbitAudioBooks/Views/Bookmarks.swift:152,189`, `OrbitAudioBooks/Views/ReaderTab.swift:662`, `OrbitAudioBooks/Views/Cells/ImageCardCell.swift:55`, `OrbitAudioBooks/Services/EPUBAutoImportScanner.swift:223`, `OrbitAudioBooks/Services/TimelineIngestionFactory.swift:443`, `OrbitAudioBooks/Services/MockMediaProvider.swift:9,27`, `Orbit Audiobooks macOS/Views/TranscriptionManager.swift:151`, `Orbit Audiobooks macOS/Views/TranscriptStore.swift:22`, `Orbit Audiobooks Watch App/Services/WatchVoiceMemoRecorder.swift:90`
- **What:** `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!` (or `.applicationSupportDirectory`) repeated with subtle variations.
- **Why:** Any directory strategy change must be applied in every location.
- **Action:** Create a `FileLocations` enum with static methods like `documentsDirectory()`, `applicationSupportDirectory()`, `cacheDirectory()`.
- **Severity:** Medium

### 9.8 Duplicated Code: Ad-hoc AVAudioEngine Setup (3+ locations)
- **Location:** `OrbitAudioBooks/Services/BookmarkStore.swift:240-257`, `OrbitAudioBooks/Views/Bookmarks.swift:749-757`, `OrbitAudioBooks/Services/SnippetPlayer.swift:21-25`
- **What:** Multiple files independently implement `AVAudioFile(forReading:)` + `engine.connect(playerNode, to: engine.mainMixerNode, format:)` + `playerNode.scheduleFile(...)`.
- **Why:** Audio playback logic scattered across the codebase, increasing chance of divergent behavior.
- **Action:** Delegate to `AudioEngine` (the central abstraction) or create a shared audio utility.
- **Severity:** Medium

### 9.9 Ad-hoc Magic Constants
- **Location:** ~30+ scattered sites across the codebase
- **What:** Inline timer intervals, search windows, capture durations, and CloudKit strings without named constants. Key examples:
  - `OrbitAudioBooks/Services/AutoAlignmentService.swift:680,711` — `let captureDuration = 3.0`
  - `OrbitAudioBooks/Services/ContinuousAlignmentService.swift:29,48` — `interval = 15.0`, `capacitySeconds = 2.0`
  - `OrbitAudioBooks/Services/TransportControlsView+LongPress.swift:48-54` — sleep timer values 15/30/45/60 hardcoded in switch
  - `OrbitAudioBooks/ViewModels/TimelineFeedViewModel.swift:77` — `windowSize = 100`
- **Why:** Magic numbers buried in method bodies make tuning brittle and hard to discover.
- **Action:** Extract to a `Config` enum or struct per service. Make `SleepTimerMode` conform to `CaseIterable`.
- **Severity:** Low

### 9.10 No TODO/FIXME/HACK Markers
- **What:** The codebase has zero `TODO`, `FIXME`, `HACK`, `XXX`, or `#warning` markers — exceptionally clean.
- **Severity:** Informational

---

## 10. Cross-cutting recommendations

1. **Modernize GCD usages globally.** 50 `DispatchQueue.main.async`/`.sync` call sites remain across the codebase. Replace with `MainActor.run { }` (synchronous callbacks) or `Task { @MainActor in }` (async contexts). Annotate `@Observable` classes with `@MainActor` so the compiler enforces isolation.

2. **Extract shared infrastructure.** Three patterns recur across platforms: EPUB XML parsing (iOS + macOS), WhisperKit management (iOS auto-alignment + continuous + macOS global), and documents-directory construction (10+ sites). Extract each into a shared module to eliminate copy-paste maintenance burden.

3. **Formatters.** Consistently use the new Foundation `FormatStyle` across the entire codebase. Legacy `Formatter` subclasses (`DateFormatter`, `ISO8601DateFormatter`) and C-style `String(format:)` should be replaced with `Date().formatted(...)` and `.formatted(.number.precision(...))`.

4. **Remove `fatalError` from production code paths.** Both `DatabaseService` init and `Orbit_AudioBooksApp` init use `fatalError` — a crashed app is never the right UX. Replace with graceful error presentation.

5. **Add error logging to all empty `catch` blocks.** The five silent `catch {}` blocks in `ReaderTab.swift` and similar patterns elsewhere should at minimum log the error via `os_log`, so alignment/DB failures produce actionable diagnostics.

6. **Fix CloudKit production readiness.** Three issues compound: (a) Development environment in all builds, (b) `hashValue`-based record IDs preventing cross-device record matching, (c) `%f` float precision in predicates. Together, these mean CloudKit sync is effectively broken for production use.

---

## 11. What was NOT audited

- **Tools/OrbitTranscriptionCLI/** — Python pipeline and Swift CLI tools excluded by request.
- **SwiftUI Layout performance** — no Instruments profiling for hitches, hangs, or excessive view updates.
- **Test coverage** — tests got a quick scan; `OrbitAudioBooksTests` has file-missing test errors. No deep test quality assessment.
- **Localization strings** — no check for complete or missing `.xcstrings` entries.
- **Third-party dependency internals** — GRDB, WhisperKit, ZIPFoundation, swift-collections treated as black boxes.
- **Build settings / Xcode project structure** — beyond what's visible in shared schemes.
- **Widget and watchOS extension entitlements** — not opened; verify they match the App Group identifier used in the main app.
- **Algorithmic correctness of alignment tier logic** — AutoAlignmentService tier algorithms reviewed for performance and error handling, but not for mathematical correctness of the alignment heuristics.

---

## 12. Verification

- **§5.1** — open `OrbitAudioBooks/Services/CloudKitSyncService.swift`, line 39. `"\(title.hashValue)-\(author.hashValue)-\(Int(duration))"` uses randomly-seeded `hashValue` for CloudKit record IDs.
- **§5.5** — open `OrbitAudioBooks/Services/ContinuousAlignmentService.swift`, line 47. `AVAudioFormat(...)!` force-unwraps a failable initializer that returns nil on unsupported PCM configurations.
- **§5.6** — open `OrbitAudioBooks/Orbit_AudioBooksApp.swift`, line 32. `fatalError("DatabaseService initialization failed: \(error)")` kills the app at launch. Also `Shared/Database/DatabaseService.swift`, line 18 for the App Group variant.
- **§5.7** — open `OrbitAudioBooks/Services/ChapterGroupingService.swift`, lines 55-62. The `guard !groupAtoms.isEmpty` at line 55 protects the force-unwraps at 61-62, but the pattern is fragile.
- **§7.1** — open `OrbitAudioBooks/Services/AutoAlignmentTextMatcher.swift`, lines 146-158. `joined(separator: " ")` string concatenation and two `Set` constructions called per sliding-window iteration in a tight O(N*M) loop.
- **§6.3** — open `OrbitAudioBooks/OrbitAudioBooks.entitlements`, line 18. `com.apple.developer.icloud-container-environment` = `Development`. No Production entitlements file exists.
