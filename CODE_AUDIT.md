# Echo Code Audit

Generated 2026-06-20. Scope: ~45,000 Swift LOC of production code across 6 targets (iOS/`EchoCore`, macOS/`Echo macOS`, watchOS/`Echo Watch App`, `Echo Widget`, `Shared`, CarPlay) — ~62k LOC / 573 files including tests. `ThirdParty/MisakiSwift` (vendored G2P), `.build/`, `.git/`, `docs/`, `Tools/` (Python), `fastlane/`, `Scripts/`, and test targets are excluded from deep review. Previous audit archived at `docs/CODE_AUDIT_2026-06-16_session4.md`.

**Method.** Eleven parallel finder agents (one per dimension/subsystem) over the full tree, then an adversarial verification pass that opened the cited lines for every Critical/High finding and was prompted to *refute* it. A clean `xcodebuild` of the iOS scheme supplied compiler ground truth (the project builds in **Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`**, so most data races are invisible to the compiler today but surface as warnings that become hard errors under Swift 6). Of 75 raw findings, 1 was dropped as a false positive and 7 High items were demoted to Medium during verification. **Net severity: 0 Critical, 7 High, ~40 Medium, ~28 Low.**

Findings cite `path/to/file.swift:LINE` for Xcode navigation. No code was changed.

---

## 1. Executive summary

Top items to address, in priority order:

1. **[High] `m4bBooks` indexed by track index, not book index** — §5.1 — `EchoCore/Services/PlaybackController.swift:195-196`. After a manual playlist reorder of a multi-`.m4b` folder, all global-time/chapter math reads the wrong book's offset → cross-book seek, rewind, and chapter-clamp errors.
2. **[High] Multi-track Audiobookshelf progress push uses the wrong duration** — §5.20 — `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift:92-94`. Book-absolute time is divided by the *current track's* duration, so every multi-track ABS book is pushed as ~100% finished on the first sync and that bad state propagates to other clients.
3. **[High] Widget/Siri "Create Bookmark" writes to a store no platform reads** — §5.28 — `Echo Widget/Models/AppIntent.swift:55-60`. Bookmarks created via Shortcut/Siri/widget land in the App-Group suite; iOS reads `UserDefaults.standard` and Mac/watch read GRDB → the bookmark is silently lost everywhere.
4. **[High] Narration export concatenates duplicate chapter audio** — §5.12 — `EchoCore/Services/Export/NarrationCacheSource.swift:13-54`. The cache listing is voice/`renderVersion`-agnostic, so a book re-rendered after a voice change or version bump exports each chapter twice back-to-back (macOS never sweeps stale files), corrupting chapter timing.
5. **[High] ONNX narration engine caches a *failed* prepare for the whole session** — §5.11 — `EchoCore/Services/Narration/OnnxKokoroEngine.swift:72-104`. One transient model-download/session-create failure permanently wedges all on-device narration until app relaunch — there is no retry.
6. **[High] `OnnxKokoroEngine` actor-isolation cluster (16 warnings)** — §3.2 — `EchoCore/Services/Narration/OnnxKokoroEngine.swift:40-147`. A non-`@MainActor` `actor` reaching into `@MainActor`-inferred helpers (`KokoroFrontEnd`, `ProgressFanOut`, `NarrationCache`) — the project's single largest Swift-6 migration blocker and a latent off-main execution hazard.
7. **[High] `WatchViewModel` WCSessionDelegate methods run off-main and touch actor state** — §3.1 — `Echo Watch App/Services/WatchViewModel.swift:317-358, 584-594`. `requestCurrentState()` reads `@MainActor` state and `WCSession` from WatchConnectivity's background delivery thread with no actor hop — a real data race the sibling `WatchSyncManager` already handles correctly.
8. **[Medium/Security] Audiobookshelf credentials sent over plaintext HTTP by default** — §6.1 — `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:17`. A scheme-less server entry defaults to `http://`, transmitting username/password and the rotating refresh token in cleartext (mitigated by the LAN/Tailscale deployment model, hence Medium).
9. **[Medium] Reader surface ignores VoiceOver curation and system Dynamic Type** — §8.1, §8.2 — `EchoCore/Views/Cells/*.swift`. Body text is still read by VoiceOver, but headings lack the `.header` trait, images carry no alt text, a debug timestamp leaks per cell, and reader text never scales with the OS accessibility text size — undercutting the app's accessibility-first positioning.
10. **[Medium] `TimelineItem` decoder crashes the whole reader feed on any unknown enum value** — §5.24 — `Shared/Database/TimelineItem.swift:5-21`. A single `timeline_item` row from a future build (new item type / out-of-range granularity) aborts every feed query for that book; no current writer emits one, so this is a forward-compat / cross-version-downgrade hazard.

---

## 2. Quick wins (≤30 min each)

Low-risk, mostly compiler-flagged; clears the warning set and removes leaked instrumentation.

- **Reset `initializationTask = nil` on failure** — `EchoCore/Services/Narration/OnnxKokoroEngine.swift:103-104`. The single change that fixes the §5.11 narration-wedge.
- **Remove unused `import Combine`** — `EchoCore/Views/AutoAlignmentProgressView.swift:2`. Dead leftover from the `@Observable` migration.
- **`AVAsset(url:)` → `AVURLAsset(url:)`** — `Echo macOS/Services/AudioExtractor.swift:25`. The lone deprecated-initializer holdout (§4.1).
- **Replace `_ = decks` / discard properly** — `EchoCore/Services/ApkgExportService.swift:75` (unused `decks` binding) and `EchoCore/Services/AlignmentService.swift:504` (unused `write` result). Verified benign — `let (_, allCards)` and a `@discardableResult` or explicit `_ =` silence them.
- **Drop dead locals** — `EchoCore/Services/DefaultSoundscapeMixer.swift:49` (`engine` unused), `EchoCore/Services/SnippetPlayer.swift:88` (`self` written-but-never-read).
- **Fix optional in log interpolation** — `EchoCore/ViewModels/PlayerModel+MarkedPassages.swift:42`. `"\(optional)"` emits a debug `Optional(…)` — make it explicit.
- **`nonisolated(unsafe)` has no effect → `nonisolated`** — `EchoCore/Services/StandaloneTranscriptionService.swift:20`.
- **Gate the per-cell anchor/timestamp overlay behind a debug flag** — `EchoCore/Views/Cells/ParagraphCardCell.swift:23-30` (and `HeadingCardCell`). Diagnostic timecodes ship to end users today (§8.4).
- **Reference `AppGroupDefaults.suiteName` instead of the raw literal** — `EchoCore/Views/Components/Haptic.swift:9`, `EchoCore/Views/Fidget/DoodlePadView.swift:65`, `EchoCore/Services/SettingsManager.swift:380,591` (§9.2).
- **Delete dead `concatenateBlocks`** — `Shared/EPUBXMLParsing.swift:711-744`. Zero callers (§9.4).

---

## 3. Concurrency

> Context: the project ships in **Swift 5 mode with MainActor-default isolation**, so the compiler emits ~30 concurrency warnings that are *not* errors yet but **become hard errors under Swift 6**. The two findings below that survived verification are genuine runtime hazards; the rest are migration blockers grouped by root cause.

### 3.1 `WatchViewModel` WCSessionDelegate methods are `@MainActor` but invoked off-main
- **Location:** `Echo Watch App/Services/WatchViewModel.swift:22-23, 317-358, 584-594`
- **What:** `WatchViewModel` is `@Observable @MainActor`, but its `WCSessionDelegate` conformances (`session(_:activationDidCompleteWith:)`, `sessionReachabilityDidChange`, `didReceiveUserInfo`) are not `nonisolated`; WatchConnectivity delivers them on a background queue, and they call `requestCurrentState()` which synchronously reads `WCSession.default`/`activationState` and `@MainActor` state with no actor hop.
- **Why:** A real data race reading main-actor-isolated state from the framework's background delivery thread; the sibling `WatchSyncManager.swift:142-196` proves the correct pattern (every delegate method `nonisolated`, body wrapped in `Task { @MainActor [weak self] in }`).
- **Action:** Mark the delegate methods `nonisolated` and hop into `Task { @MainActor in … }` before touching `requestCurrentState()`/state, mirroring `WatchSyncManager`.
- **Severity:** High

### 3.2 `OnnxKokoroEngine` actor reaches into `@MainActor`-inferred helpers (16-warning cluster)
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:40, 56-59, 73, 78-82, 88, 99-101, 115, 126-147`
- **What:** Under MainActor-default isolation, the un-annotated helpers `KokoroFrontEnd`, `ProgressFanOut`, and `NarrationCache` are inferred `@MainActor`, while `OnnxKokoroEngine` is an explicit `actor`; every cross-call (`frontEnd.encode`, `fan.emit/add/clear`, `NarrationCache.directory()`, even `Self.tensorData`) is an isolation conflict.
- **Why:** This is the largest Swift-6 blocker in the codebase (16 of ~30 concurrency warnings), and at runtime today the `@MainActor` helper code executes on the actor's background executor rather than main — benign only because those helpers happen to be self-contained.
- **Action:** Decide the engine's isolation deliberately: either make the helpers `nonisolated`/`Sendable` value types (they are effectively pure), or move the orchestration to `@MainActor` and keep only `session.run` off-main. Don't paper over with `nonisolated(unsafe)`.
- **Severity:** High

### 3.3 Mutable `var` captured in concurrently-executing closures (Swift-6 errors)
- **Location:** `EchoCore/Services/DefaultVisualizerTap.swift:44`, `EchoCore/Services/Narration/NarrationService.swift:197`, `EchoCore/ViewModels/PlayerModel+Narration.swift:174`
- **What:** Three `Task`/`db.write` closures capture a mutable `var` (`self`, `anchors`) that the compiler flags as "reference to captured var in concurrently-executing code; this is an error in the Swift 6 language mode."
- **Why:** Each is a Swift-6 hard error; the `anchors` case (read-only iteration inside `db.write`) is benign at runtime, but the pattern is a latent race if any becomes a write.
- **Action:** Bind a `let` copy before the closure (e.g. `let anchors = anchors`) or restructure the capture; trivial per site.
- **Severity:** Medium

### 3.4 `ContinuousAlignmentService.stop()` spawns an untracked fire-and-forget release Task
- **Location:** `EchoCore/Services/ContinuousAlignmentService.swift:70-89`
- **What:** `stop()` launches `Task { await task?.value; WhisperSession.shared.release() }` that is neither stored nor cancellable; rapid play/pause can fire several, each awaiting then calling `release()`.
- **Why:** Mismatched acquire/release can drive the shared WhisperKit model's retain count negative and unload the ~40 MB model out from under an in-flight transcription — the exact over-release the code comment warns about.
- **Action:** Track the teardown task and cancel/await any prior one before starting a new one, or serialize acquire/release through an actor so `release()` fires at most once per acquire.
- **Severity:** Medium

### 3.5 `ProgressFanOut` subscribers can be cleared mid-prepare, dropping the terminal event
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:72-104`, `EchoCore/Services/Narration/ProgressFanOut.swift:22-33`
- **What:** A second caller that joins an in-flight `prepare()` does `progressFanOut?.add(progress)`, but the first task's `defer { fan.clear() }` and the `.ready` emit can race so the joiner is added after completion and never receives a terminal event.
- **Why:** A UI joining the prepare to show download/compile progress can be stuck on a stale spinner — a correctness/UX race, not a crash.
- **Action:** On `add`, immediately drive a late subscriber to the latest terminal state (replay `.ready`), or guard registration against an already-completed fan-out.
- **Severity:** Low

### 3.6 `@MainActor` statics referenced from `nonisolated` contexts (default-isolation noise)
- **Location:** `Shared/Database/DatabaseService.swift:28`, `Shared/Database/Migrations/Schema_V22.swift:24`, `Shared/EPUBBlockParser.swift:171`, `EchoCore/ViewModels/PlayerModel+Narration.swift:32`, `EchoCore/Views/Bookmarks.swift:64-65`
- **What:** Several `@MainActor`-inferred statics (`suiteName`, `seed`, `isNonContent`, `NarrationCapability.default`) and the `recorder`/`elapsed` properties are touched from `nonisolated`/`@Sendable` contexts, each a Swift-6 warning.
- **Why:** Mostly benign today (the statics are effectively pure), but they will block the Swift-6 migration and one (`Bookmarks.swift:64-65` mutating `elapsed` from a `@Sendable` closure) is a genuine cross-isolation mutation.
- **Action:** Mark the pure statics `nonisolated`; for `Bookmarks.swift`, hop the closure body to the main actor before mutating `elapsed`.
- **Severity:** Low

---

## 4. API modernity

### 4.1 Deprecated `AVAsset(url:)` initializer
- **Location:** `Echo macOS/Services/AudioExtractor.swift:25`
- **What:** Constructs its asset with `AVAsset(url:)`, deprecated since iOS 18 / macOS 15 in favor of `AVURLAsset`; every other site in the codebase already uses `AVURLAsset`.
- **Why:** Emits a deprecation warning and is the single inconsistency in an otherwise modernized asset layer.
- **Action:** Replace with `AVURLAsset(url:)`.
- **Severity:** Low

### 4.2 Synchronous `AVAsset.tracks(withMediaType:)` on a possibly-unloaded asset
- **Location:** `Echo macOS/Services/MacAudioBoostTap.swift:35`
- **What:** `makeAudioMix` reads `item.asset.tracks(withMediaType: .audio)` synchronously — deprecated since iOS 16 / macOS 13 in favor of `loadTracks(withMediaType:)`.
- **Why:** Beyond the deprecation, synchronous track access on an unloaded asset can return an empty array, silently skipping installation of the volume-boost tap.
- **Action:** Make the builder `async` (or pre-load the audio track) and switch to `await asset.loadTracks(withMediaType: .audio)`.
- **Severity:** Medium

### 4.3 Soft-deprecated `.foregroundColor(_:)` / `.accentColor(_:)` modifiers
- **Location:** `Echo macOS/Views/MacReaderFeedView.swift:308,319`, `EchoCore/EchoCoreApp.swift:88`
- **What:** Three sites use the legacy `.foregroundColor`/`.accentColor` spellings instead of `.foregroundStyle`/`.tint`.
- **Why:** Compiles but is the legacy form; consolidating on the `ShapeStyle` modifiers keeps styling consistent and future-proof.
- **Action:** Replace `.foregroundColor(x)` → `.foregroundStyle(x)` and `.accentColor(x)` → `.tint(x)`.
- **Severity:** Low

---

## 5. Bugs / logic errors

### 5.1 Smart-rewind & chapter math index `m4bBooks` by track index, not book index
> **✅ FIXED** (branch `claude/heuristic-dewdney-c9fd89`, 2026-06-20). Added URL-resolved `PlaybackState.currentBook`/`currentBookStartOffset`; all seven `m4bBooks[currentIndex].cumulativeStartOffset` reads (PlaybackController ×5, `PlaybackProgressPresenter`, `PlayerModel.cumulativePlaybackTime`) now use it. Covered by `EchoTests/PlaybackBookTimeTests`. _Note: the reverse book→track conflation in `seekToAggregatedChapter`'s `coordinator_loadTrack?(agg.bookIndex,…)` (PlaybackController:601) and `PlayerModel+Bookmarks.seekToAggregatedChapterPosition` is the same root cause and is NOT yet fixed — see the book-time abstraction in §10 (recommendation 2)._
- **Location:** `EchoCore/Services/PlaybackController.swift:196,213,409,458,692-694` (also `EchoCore/ViewModels/PlayerModel.swift:251`, `PlayerModel+Bookmarks.swift:246`, `PlaybackProgressPresenter.swift:103`)
- **What:** `computeChapterStartTarget`/`clampToChapterBoundary`/`nextAggregatedChapter`/`previousAggregatedChapterOrRestart`/`skipBackward30` all read `state.m4bBooks[state.currentIndex].cumulativeStartOffset`, indexing the filename-sorted `m4bBooks` by the playlist *track* index. `state.currentIndex` indexes `state.tracks`, which is reorderable via persisted `loadOrder` and user `moveTracks`.
- **Why:** When track order diverges from filename order, `currentIndex` and the book's position in `m4bBooks` differ, so global-time math uses the wrong book's cumulative offset → cross-book seek/rewind errors and wrong chapter clamping. (A `.indices.contains` guard prevents a crash but not the wrong-offset selection.)
- **Action:** Resolve the current book by matching the playing track's URL to `m4bBooks` (or store the book index on the track) instead of indexing `m4bBooks` by `currentIndex`.
- **Severity:** High *(manifests only after a manual reorder of a multi-`.m4b` folder)*

### 5.2 `nextAggregatedChapter` loops to the first chapter past the final boundary
> **✅ FIXED** (branch `claude/heuristic-dewdney-c9fd89`, 2026-06-20). Extracted pure `PlaybackController.nextAggregatedIndex(chapters:globalTime:)` which returns nil at/past the final chapter (stay put) instead of falling through to chapter 0; wired into `nextAggregatedChapter`. Covered by `EchoTests/PlaybackBookTimeTests`.
- **Location:** `EchoCore/Services/PlaybackController.swift:407-422,572-579`
- **What:** `aggregatedChapterIndex` uses a half-open `< endSeconds` test that never matches the final boundary, returning `nil`; `nextAggregatedChapter` then computes `currentIdx = -1`, `nextIdx = 0` and seeks to the first chapter.
- **Why:** Pressing next-chapter while sitting on/just past the last chapter of a multi-`.m4b` book jumps the listener to the very beginning instead of staying put.
- **Action:** Treat a nil/out-of-range current index near the end as "no next chapter" instead of falling through to `aggregatedChapters.first`.
- **Severity:** Medium

### 5.3 `recalculateTimeline` divides by `averageCPS` with no zero/negative floor
- **Location:** `EchoCore/Services/AlignmentService.swift:266-302,316-317`
- **What:** `averageCPS` is overwritten with `totalChars / totalTime`; a degenerate anchor set (e.g. blocks re-imported out of sequence so a later anchor has a smaller `wordPosition`) can drive it near-zero or negative, and the synthetic-boundary projections then divide `distance / averageCPS`.
- **Why:** Projects front/last-block synthetic times to absurd or negative values, collapsing or inverting the interpolated timeline for the whole book.
- **Action:** Clamp `averageCPS` to a positive floor (e.g. `max(1.0, computed)`) before using it as a divisor.
- **Severity:** Medium

### 5.4 Zero-duration fallback chapter when duration is not yet known
- **Location:** `EchoCore/Services/ChapterLoadingCoordinator.swift:95-104,167-176`
- **What:** When no chapters parse, a single fallback chapter is built with `endSeconds: state.durationSeconds ?? 0`, but this can run before `loadDurationForNowPlaying` sets duration, yielding a `[0,0]` chapter.
- **Why:** A zero-length chapter persisted to `ChapterDAO` collapses downstream end-time math and makes `seek(toFraction:)` no-op (`chapterDuration == 0`).
- **Action:** Defer the single-span fallback until duration resolves, or patch `endSeconds` once `loadDurationForNowPlaying` completes.
- **Severity:** Medium

### 5.5 Tier-0 title-match anchors mix global and per-track time bases
> **⏳ INVESTIGATED — deferred to its own task** (2026-06-20). Confirmed and found to be deeper than the one-line action below: `PlayerModel.alignmentPickerChapters:347-360` returns **aggregated (global) chapter times** for multi-`.m4b`, while `AutoAlignmentService` captures on the loaded single file's local axis (`audioEngine.duration:558`) and holds **no `state`/book/offset context at all** (`grep m4bBooks` in that file = 0 hits). A correct fix must (a) filter `alignmentPickerChapters` to just the **loaded** book's chapters, (b) subtract that book's offset — the new `PlaybackState.currentBookStartOffset` (§5.1) is the right input to thread in — and (c) be verified **on-device** with a real multi-`.m4b` book + EPUB, since alignment quality can't be meaningfully unit-tested. Not bundled with the §5.1/§5.2/§5.20 playback PR because a wrong change here risks regressing the common single-file alignment path.
- **Location:** `EchoCore/Services/AutoAlignmentService.swift:289-307,481-488`; `EchoCore/ViewModels/PlayerModel.swift:347-360`
- **What:** `createTitleMatchAnchors` anchors a heading at the chapter's `startSeconds` (an aggregated/global time for multi-`.m4b`), while the DTW window filter and `captureAndTranscribe` operate on the single loaded file's local time axis.
- **Why:** For multi-`.m4b` books the bootstrap anchor AND the content-alignment capture run with global chapter times against a per-file engine, so anchors land at wrong positions or are filtered out by the window-slack gate.
- **Action:** Thread the loaded book's cumulative offset (`currentBookStartOffset`) into `AutoAlignmentService`, filter to the loaded book's chapters, and convert global→local before creating Tier-0 anchors and computing the DTW window. Verify on-device.
- **Severity:** Medium

### 5.6 `applyMove` reorder force-indexes the source `IndexSet` with no bounds check
- **Location:** `EchoCore/Services/PlaylistManager.swift:132-139`
- **What:** Maps `array[$0]` for every offset in the SwiftUI `onMove` `IndexSet` and removes at those offsets unchecked; if `state.tracks`/`chapters` changed between gesture start and drop, an out-of-range offset traps.
- **Why:** A stale offset crashes during a drag-reorder of tracks or chapters.
- **Action:** Filter the source `IndexSet` to `array.indices` (and clamp destination) before mapping/removing.
- **Severity:** Low

### 5.7 Bookmark/section look-back thresholds are speed-independent
- **Location:** `EchoCore/Services/PlaybackController.swift:508-535,737-747,798-808`
- **What:** `previousSectionOrRestart`/`jumpToPreviousBookmark` hardcode `t - 5.0`/`currentTime - 2.0`, and `skipForward30` clamps only to total duration — unlike `applyBookmarkLoopIfNeeded`, none scale by playback speed, and the forward skip lacks the backward path's chapter-boundary clamp.
- **Why:** At 2×+ speed "previous section" restarts the current section, previous-bookmark can snap to the same mark, and a 30 s forward skip overshoots into the next aggregated chapter without boundary handling.
- **Action:** Scale the restart thresholds by current speed (mirror `applyBookmarkLoopIfNeeded`) and mirror `skipBackward30`'s chapter-boundary clamp on the forward path.
- **Severity:** Low

### 5.8 `reingestTimelineFromEPUB` falls back to `URL(fileURLWithPath: "/")` as the audio URL
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:1098-1114`
- **What:** With no track loaded, passes `folderURL ?? URL(fileURLWithPath: "/")` as the audio URL into timeline ingestion.
- **Why:** Ingesting against filesystem root can key a timeline to an invalid path or trigger `AVAsset` work on `/`, masking the real "no audio" condition.
- **Action:** Guard-return when there is no real audio/folder URL instead of substituting root.
- **Severity:** Low

### 5.9 `chapterIndex(forTime:)` re-finds by value-equality, mismatching overlapping chapters
- **Location:** `EchoCore/Services/ChapterService.swift:67-77`
- **What:** `chapter(forTime:)` returns the shortest match, then `chapterIndex(forTime:)` locates it again via `firstIndex(of:)`; for overlapping chapters that compare `==`, the wrong (earlier) index can be returned.
- **Why:** Desyncs Now Playing subtitle and chapter navigation for books with duplicate/overlapping ranges.
- **Action:** Carry the index through the min-by selection instead of re-searching by value equality.
- **Severity:** Low

### 5.10 `DSPSplitComplex` stores pointers to temporaries (compiler-flagged lifetime hazard)
- **Location:** `EchoCore/Services/DefaultVisualizerTap.swift:138`
- **What:** `var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)` — the compiler warns the `&realp`/`&imagp` inout pointers "must outlive the call"; the struct retains pointers only guaranteed valid for the initializer's duration.
- **Why:** Works today but is formally undefined behavior; an optimizer change could leave `splitComplex` holding dangling pointers during the subsequent `vDSP_ctoz`/`vDSP_fft_zrip` calls.
- **Action:** Build the split-complex inside nested `realp.withUnsafeMutableBufferPointer { … imagp.withUnsafeMutableBufferPointer { … } }` so the pointers provably outlive use.
- **Severity:** Medium

### 5.11 ONNX engine caches a *failed* initialization Task — narration wedged for the session
> **✅ FIXED** (branch `claude/fix-narration-prepare-retry`, 2026-06-20). `prepare(progress:)` now clears `initializationTask = nil` when the init task throws, so a later call starts a fresh attempt instead of re-awaiting the cached failure. A constructor seam (`OnnxKokoroEngine(modelProvider:)`) makes the retry path unit-testable without a network/model. Covered by `EchoTests/OnnxKokoroEnginePrepareTests`. _Related but still open: §5.13 (a corrupt downloaded model is still sticky — no integrity check before promote)._
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:72-77,103-104`
- **What:** `initializationTask` is set once and never reset on failure; after any thrown `prepare()` (network blip mid-download, non-2xx, disk-full move), every later call re-awaits the cached failed task and re-throws. The production engine is a session-lived `lazy var` (`PlayerModel.narrationTTS`).
- **Why:** A single transient first-load failure bricks all on-device narration until app relaunch, with no retry. Compounded by §5.13 (a corrupt model is sticky).
- **Action:** Clear `initializationTask = nil` in the task's failure path (or via `do/catch` around `try await task.value`) so a later `prepare()` starts fresh.
- **Severity:** High

### 5.12 Narration export concatenates duplicate chapter audio across voice/version
> **✅ FIXED (export path)** (branch `claude/fix-narration-export-dedup`, 2026-06-20). `NarrationCacheSource.items()` now collapses the glob to one file per chapter via a new pure `currentVersionFiles(...)`: it prefers the canonical file (current `renderVersion` + the DB-recorded voice for that chapter) and falls back to a single deterministic file when the canonical one is absent (so a not-yet-re-rendered chapter is still exported, not dropped). Fixes the export corruption on **both** iOS and macOS (both export through `NarrationCacheSource`). Covered by `EchoTests/NarrationExportDedupTests`; existing `NarrationExportOrderingTests` unchanged. _Still open (disk-bloat, not export corruption): the macOS render path (`MacBatchProcessingService:322-366`) does not sweep stale voice/version files as iOS does — a separate cleanup._
- **Location:** `EchoCore/Services/Export/NarrationCacheSource.swift:13-29,36-54`, `Echo macOS/Services/MacBatchProcessingService.swift:322-366`, `EchoCore/Services/Narration/NarrationFileNaming.swift:44-48`
- **What:** `NarrationCacheSource.items()` selects every `<token>-ch*.m4a` regardless of voice or `renderVersion`, and `chapterIndex(fromFileName:)` ignores both; the iOS stale-file sweep runs only via `PlayerModel+Narration.swift:62-71`, and the macOS render path never sweeps. `AudioExportService.exportM4B` inserts each item sequentially with a `ChapterAtom` per item.
- **Why:** A book re-rendered after a voice change or `renderVersion` bump exports the same chapter twice back-to-back, corrupting chapter timing and total duration in the `.m4b`.
- **Action:** Filter the cache listing to the current `renderVersion` and resolve a single voice per chapter index before ordering; run the stale-file sweep on the macOS render path as iOS does.
- **Severity:** High

### 5.13 Downloaded ONNX model is promoted with no integrity check and is sticky when corrupt
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:179-198`
- **What:** `ensureModel` validates only the HTTP status, then `moveItem`s the temp file to the durable path with no size/hash check; a truncated-but-2xx download is kept and `fileExists` short-circuits every future run.
- **Why:** A corrupt model makes `ORTSession` creation throw on every launch and (with §5.11) never self-heals.
- **Action:** Verify size/hash before promoting the file, and delete + re-download when session creation fails to load it.
- **Severity:** Medium

### 5.14 Mid-render synthesis failure leaves a truncated chapter treated as complete
- **Location:** `EchoCore/Services/Narration/NarrationService.swift:116,134-150,180`, `EchoCore/ViewModels/PlayerModel+Narration.swift:210-211,284`
- **What:** `renderChapter` opens the stream file up front; a non-cancellation/non-length-cap synthesize error propagates while the `ALACFileStream` flushes a short-but-valid `.m4a` that is never deleted, and the render loop only re-renders chapters whose file is *absent*.
- **Why:** On next launch the truncated file passes the `fileExists` reuse check and is played as complete — the user permanently hears a cut-short chapter until they clear the cache.
- **Action:** On any non-cancellation throw in `renderChapter`, delete the partial file before propagating so it is re-rendered.
- **Severity:** Medium

### 5.15 Audiobook IDs differing only in punctuation collapse to the same cache token
- **Location:** `EchoCore/Services/Narration/NarrationFileNaming.swift:27-39`
- **What:** `safeToken` maps every non-alphanumeric char to `_`, so two `file://` audiobook IDs differing only in punctuation produce identical chapter filenames/prefixes.
- **Why:** Such books read and overwrite each other's rendered chapters and cross-contaminate exports/playback.
- **Action:** Derive the token from a collision-resistant digest (short hash) of the audiobookID rather than lossy character-class replacement.
- **Severity:** Medium

### 5.16 Pronunciation-override IPA lookup is order-dependent on case collisions
- **Location:** `EchoCore/Services/Narration/PronunciationOverrides.swift:34-43`
- **What:** After a case-insensitive match, the IPA is resolved via `entries.first(where: { $0.key.lowercased() == matched.lowercased() })`, picking an arbitrary entry when two keys differ only in case ("Polish" vs "polish").
- **Why:** The applied pronunciation becomes nondeterministic across runs/dictionary mutations.
- **Action:** Normalize override keys to one canonical case at store time, or key a case-folded lookup map.
- **Severity:** Low

### 5.17 ONNX `input_ids` are never bounded to the model's phoneme cap
- **Location:** `EchoCore/Services/Narration/OnnxKokoroEngine.swift:115-128`, `EchoCore/Services/Narration/NarrationTextChunker.swift:25`
- **What:** The chunker caps on character count (~200) while the model/voicepack are indexed by phoneme count (~510); the ONNX path passes whatever ids it gets with no truncation or `lengthCapExceeded` throw, so a phoneme-dense ≤200-char chunk could exceed the cap.
- **Why:** An over-cap chunk feeds an out-of-range sequence (the voicepack row merely clamps), risking degraded audio with no guardrail.
- **Action:** Enforce an explicit phoneme-count cap in the engine (truncate or throw `lengthCapExceeded`, which the service already handles).
- **Severity:** Low

### 5.18 `PlaybackSessionRecorder` uses rowID `0` as a failed-insert sentinel
- **Location:** `EchoCore/Services/PlaybackSessionRecorder.swift:120-143,149-167`
- **What:** `insertOpen` returns `0` when both insert attempts fail; that `0` is stored as `openRowID`, after which `extendOpen`/`finalize`/`discard` run `UPDATE/DELETE … WHERE id = 0` as if a real row were open.
- **Why:** A failed insert is silently treated as success; later updates/deletes target a non-existent row and the segment is lost with no error.
- **Action:** Return optional/throw on insert failure and leave `openRowID` nil so downstream actions no-op.
- **Severity:** Low

### 5.19 (ABS) — see §6 for the security-flavored Audiobookshelf findings

### 5.20 Multi-track ABS progress push uses current-track duration, corrupting remote progress
> **✅ FIXED** (branch `claude/heuristic-dewdney-c9fd89`, 2026-06-20). Added `PlaybackState.effectiveBookDuration` (`isMultiM4B ? totalBookDuration : durationSeconds`); `maybePushABSProgress` now uses it instead of `durationSeconds ?? 0`. Covered by `EchoTests/PlaybackBookTimeTests`. _Follow-up: the duplicated `isMultiM4B ? totalBookDuration : durationSeconds` ternary at `PlayerScrubberView:79`, `TransportControlsView:48`, `PlaybackProgressPresenter:100` can now also adopt this helper (cleanup, not a bug)._
- **Location:** `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift:92-98`, `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift:124-136`
- **What:** `maybePushABSProgress` pushes `currentTime = cumulativePlaybackTime` (book-absolute) but `duration = durationSeconds` (the *current track's* duration, not `totalBookDuration`); `patchProgress` then computes `min(1.0, current/duration)` → clamps to 1.0 and `isFinished` becomes true past the first track. Every other book-level consumer correctly uses `isMultiM4B ? totalBookDuration : durationSeconds`.
- **Why:** Any multi-track ABS book has its server-side progress and "finished" flag corrupted on the first push; that bad state flows back to other ABS clients and Echo's reconcile-on-load.
- **Action:** Push `totalBookDuration` (when `isMultiM4B`) alongside the book-absolute `currentTime`, or gate ABS push to single-track books in v1.
- **Severity:** High

### 5.21 CloudKit anchor sync never checks `accountStatus`
- **Location:** `EchoCore/Services/CloudKitSyncService.swift:83-233`, `EchoCore/Services/EPUBAutoImportScanner.swift:185-194`, `EchoCore/Views/BookSettingsView.swift:113-114`
- **What:** `uploadAnchors`/`downloadAnchors` hit `publicCloudDatabase` with no `CKContainer.accountStatus()` precheck, and no caller checks it.
- **Why:** Signed-out / restricted iCloud users get an opaque `CKError` surfaced raw (upload) or silently swallowed via `try?` (download), instead of a clean "sign in to iCloud" state.
- **Action:** Query `accountStatus()` before any CloudKit op and short-circuit with a typed "no account" result so callers present a clear message or skip silently.
- **Severity:** Medium

### 5.22 ABS progress push swallows all errors via `try?`, hiding persistent sync failure
- **Location:** `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift:95-98,109`
- **What:** Both `maybePushABSProgress` (`try? patchProgress`) and `reconcileABSProgressOnLoad` (`try? getProgress`) discard every error including auth/network/non-2xx, and `absLastPushAt` is advanced *before* the push so a failed push still consumes the throttle window.
- **Why:** A revoked refresh token or unreachable server silently stops progress sync with no diagnostic.
- **Action:** At minimum `os_log` the error (surface a sync-failure state), and don't advance `absLastPushAt` until the push succeeds.
- **Severity:** Medium

### 5.23 ABS search/filter query values don't percent-encode `+`
- **Location:** `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:35,63-70`
- **What:** `search()`/`items()` build query values via `URL.appending(queryItems:)`, which uses `urlQueryAllowed` and leaves `+` literal; ABS (Express/`qs`) decodes a literal `+` as a space.
- **Why:** A search containing `+` (e.g. "C++") is sent as spaces and returns wrong/empty results; the latent base64 `filter` path (routinely `+`/`/`/`=`) would silently break the moment it's wired up.
- **Action:** Explicitly percent-encode `+` (and other sub-delimiters) in query values before composing the URL.
- **Severity:** Medium

### 5.24 `TimelineItem` decoder crashes the feed on any unknown `item_type`/`granularity_level`
- **Location:** `Shared/Database/TimelineItem.swift:5-18,21`, `Shared/Database/Migrations/Schema_V4.swift:12,20`, `Shared/Database/DAOs/TimelineDAO.swift:32,63`
- **What:** `TimelineItemType` (String) and `GranularityLevel` (Int) use the synthesized `Codable` decoder, which throws `DecodingError.dataCorrupted` on any raw value outside the known set; the columns are bare TEXT/INTEGER with no CHECK constraint, and every `TimelineDAO` query ends in `fetchAll` with no per-row degradation. (The `init?(legacyRawValue:)` helper is not wired into the GRDB decoder.)
- **Why:** One out-of-set row aborts the whole feed fetch for that book — exactly the failure mode `BatchItemKind` already guards against. No current writer emits one, so this is a forward-compat / cross-version-downgrade / CloudKit-from-newer-build hazard.
- **Action:** Give both enums a custom `init(from:)` mapping unknown raw values to a safe default (`textSegment` / `paragraph`), mirroring `BatchItemKind`.
- **Severity:** Medium

### 5.25 CarPlay Library/Chapters/Bookmarks tabs never refresh after connect
- **Location:** `EchoCore/CarPlay/CarPlayManager.swift:40-44`, `EchoCore/ViewModels/PlayerModel.swift:962-996`
- **What:** `refreshLibrary`/`refreshChapters`/`refreshBookmarks` are called only inside `connect()`; `PlayerModel` wires CarPlay observers solely for add-bookmark/voice-memo/mark-passage actions, with no callback that re-pushes template sections on book/chapter/bookmark change.
- **Why:** Switching books, advancing chapters, or adding a bookmark while connected leaves the Chapters/Bookmarks tabs stale until reconnect (Now Playing stays live via `MPNowPlayingInfoCenter`).
- **Action:** Expose a refresh hook from `CarPlayManager` and invoke it from `PlayerModel` on book-load, chapter-change, and bookmark mutation.
- **Severity:** Medium

### 5.26 Synchronous main-thread DB reads block the reader feed (LIKE scan per keystroke)
- **Location:** `EchoCore/ViewModels/ReaderFeedViewModel.swift:83,94-106`, `Shared/Database/DAOs/EPubBlockDAO.swift:97-110`
- **What:** `ReaderFeedViewModel` is `@MainActor` and `reload()` runs `blocksByChapter`/`searchBlocks` synchronously through `db.read` on main (search `didSet` fires `reload` per keystroke); `searchBlocks` runs an unindexable `LIKE '%query%'` full scan.
- **Why:** On a large EPUB this blocks the main thread during load/scan, producing visible hangs while typing in search or opening the reader.
- **Action:** Move the block loads/searches to async `reader.read` off the main actor and hand results back to `@MainActor`, as `AudiobookDAO.allAsync()` already does; consider FTS5 for block-text search. (Overlaps §7.6.)
- **Severity:** Medium

### 5.27 Per-book `UserDefaults` keys are never deleted on book removal
- **Location:** `EchoCore/Services/BookPreferencesService.swift:10-34`, `EchoCore/Services/Persistence.swift:29-33,246`, `Shared/Database/DAOs/AudiobookDAO.swift:42-46`
- **What:** Per-book keys (`book_appFont_<id>`, `book_volumeBoost_<id>`, `bookmarks_<key>`, `order_<key>`, `enabled_<key>`, `EchoAudiobooks.progress.<key>`, …) are written per audiobook, but `AudiobookDAO.delete` removes only the SQL row; `removeObject` runs solely on explicit override-reset, never on book deletion.
- **Why:** Every imported-then-deleted book leaves its keys behind forever, so the standard defaults plist grows unbounded for users who churn books.
- **Action:** Add a deletion routine that removes all `UserDefaults` keys derived from the audiobook's id/folderKey; centralize the key prefixes so cleanup stays in sync with the writers.
- **Severity:** Medium

### 5.28 Widget/Siri "Create Bookmark" writes to a store no platform reads
- **Location:** `Echo Widget/Models/AppIntent.swift:38-61`, `EchoCore/Services/Persistence.swift:24,263-273`, `Shared/Database/MigrationService.swift:19,24-25`
- **What:** `CreateBookmarkIntent` encodes `[Bookmark]` into `AppGroupDefaults.shared` under `bookmarks_<folderKey>`, but iOS reads bookmarks from `UserDefaults.standard`, the one-shot iOS DB migration also reads `UserDefaults.standard`, and Mac/watch read GRDB — no live path reads the App-Group suite for that key.
- **Why:** Every bookmark created via Siri/App Shortcut/widget is silently discarded; it never appears in the library on any platform.
- **Action:** Route the widget intent through the same persistence the live app reads (write via the shared GRDB writer, or at minimum the exact `UserDefaults.standard` key + sidecar iOS `Persistence` consumes).
- **Severity:** High

### 5.29 iOS persists bookmarks to UserDefaults/sidecar while Mac/watch use GRDB
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:627-630`, `EchoCore/Services/Persistence.swift:248-264`, `Echo macOS/Views/MacPlayerModel.swift:714-738`
- **What:** iOS `bookmarkStore.onPersist` calls `saveBookmarks` (`UserDefaults.standard` + EPUB-folder sidecar), while Mac/watch persist via `BookmarkDAO` into the shared DB; `MigrationService` only migrates UserDefaults→DB once on first iOS launch.
- **Why:** New bookmarks created on iOS *after* first launch never reach the DB Mac/watch read, breaking cross-device bookmark parity (and contradicting `MacPlayerModel`'s own "visible to iOS/watchOS" header claim).
- **Action:** Unify the bookmark seam so iOS also writes through `BookmarkStore.configureForDatabase`/`BookmarkDAO`, eliminating the dual UserDefaults-vs-DB paths.
- **Severity:** Medium

### 5.30 macOS folder audiobooks restore as a single track on relaunch
- **Location:** `Echo macOS/Views/MacPlayerModel.swift:277-297,392-418,499-516`
- **What:** `loadFolder` sets `tracks`, but only `open()` persists a security-scoped bookmark for the first file; `restoreLastFile` reopens that single file and `open()` rebuilds `tracks` as `[url]` because `tracks` is empty.
- **Why:** After quit/relaunch, a folder-based book returns with only one track, silently disabling next/previous-track navigation until the user re-opens the folder.
- **Action:** Persist the folder URL (security-scoped) alongside the last file and re-run the folder scan on restore.
- **Severity:** Medium

### 5.31 macOS volume boost & smart-rewind ignore user settings that iOS honors
- **Location:** `Echo macOS/Views/MacPlayerModel.swift:81-104,117-121`, `EchoCore/ViewModels/PlayerModel.swift:141-208,1187-1216`
- **What:** `MacPlayerModel` hardcodes `volumeBoostGain = 9.0` (never adopting `settings.volumeBoostGain` or a per-book override) and builds `SmartRewindPolicy` from fixed 3/10/30 s literals, whereas iOS resolves both from `SettingsManager`/`BookPreferencesService`.
- **Why:** Boost gain, per-book boost overrides, and tuned resume-rewind amounts set on iOS have no effect on macOS — audible cross-platform inconsistency.
- **Action:** Have macOS `applySettings()` read `settings.volumeBoostGain` and build the rewind policy from injected settings, mirroring `PlayerModel`.
- **Severity:** Medium

---

## 6. Security

### 6.1 Audiobookshelf credentials/tokens sent over plaintext HTTP by default
- **Location:** `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:11-17`, `EchoCore/Views/ABSConnectionsSettingsView.swift:28`, `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift:28-39,53,70`
- **What:** `normalizedBaseURL` defaults a scheme-less entry (bare `host:port`) to `http://`; the username/password login, the `x-refresh-token` header, and `?token=` query params are then transmitted unencrypted, with no warning or "require TLS" option.
- **Why:** A same-LAN/Wi-Fi sniffer can capture the ABS username, password, and long-lived refresh token in cleartext. Mitigated by the self-hosted LAN/Tailscale (WireGuard-encrypted) deployment model and Keychain-at-rest storage — hence Medium, not High — but it's a real hardening gap.
- **Action:** Prefer `https` when scheme is absent (fall back to `http` only for confirmed loopback/private addresses), and surface a plaintext warning + "require secure connection" toggle.
- **Severity:** Medium

### 6.2 ABS-downloaded audiobook blobs not excluded from iCloud/iTunes backup
- **Location:** `Shared/FileLocations.swift:57-61`, `EchoCore/Services/Audiobookshelf/ABSImportService.swift:25-33`
- **What:** `absLibraryDirectory` stores whole-item downloads (audio + EPUB, potentially hundreds of MB) under Application Support, and `ABSImportService` never sets `isExcludedFromBackup` — unlike `NarrationCache`, which does.
- **Why:** Large re-downloadable media is copied into device/iCloud backups, bloating them and consuming the user's iCloud quota; may trip App Store data-storage review.
- **Action:** Set `isExcludedFromBackup` (`URLResourceValues`) on the ABS library directory at creation, matching `NarrationCache`.
- **Severity:** Medium

### 6.3 Remote ABS zip extracted without the decompression-bomb limit
- **Location:** `EchoCore/Services/Audiobookshelf/ABSImportService.swift:30-33`
- **What:** The whole-item zip from the (less-trusted, remote) ABS server is expanded via `unzipItem(at:to:)` with no `ArchiveExtractionLimits.checkedTotal` guard, whereas the EPUB and APKG paths both enforce an uncompressed-size cap.
- **Why:** A malicious/compromised ABS server could serve a zip bomb that fills the disk during extraction (DoS/data loss) — exactly the case the existing bomb defense was built for.
- **Action:** Extract ABS items entry-by-entry through the shared `safeDestination` + `ArchiveExtractionLimits.checkedTotal` path, mirroring `EPUBAutoImportScanner`/`ApkgImportService`.
- **Severity:** Medium

### 6.4 Community alignment anchors written to a world-writable public CloudKit DB
- **Location:** `EchoCore/Services/CloudKitSyncService.swift:11-20,107-135`, `EchoCore/Services/EPUBAutoImportScanner.swift:190-194`
- **What:** Shared anchors plus the book's title/author/duration are saved to `publicCloudDatabase`, readable and overwritable by any client with the container id; downloaded payloads are auto-consumed during import.
- **Why:** A third party can poison a popular book's shared anchors or harvest the catalog of aligned titles; the merge-on-conflict write lets an attacker degrade the shared record for everyone (download is mitigated by timestamp/block validation, but the write surface is open).
- **Action:** Move community sharing to a server-validated / `CKShare` / owner-private model, or gate writes behind moderation + per-device rate limiting (as the in-file note already recommends).
- **Severity:** Medium

### 6.5 ABS access/refresh JWT carried in URL query strings for covers & downloads
- **Location:** `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift:47-61`, `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift:106-109,188-193`
- **What:** `coverURL`/`fileDownload`/`downloadItem` embed the token as `?token=` so URLs are self-contained for `AsyncImage`/background downloads.
- **Why:** Tokens in URLs leak into `URLCache`, server access logs, and proxies more readily than an `Authorization` header — widening exposure of a live session token (the rotating refresh token in §6.1 is the more sensitive one).
- **Action:** Prefer the `Authorization: Bearer` header for downloads (already sent), and for `AsyncImage` covers route through an authenticated loader or accept the trade-off knowingly and keep responses out of persistent caches.
- **Severity:** Low

### 6.6 ABS `signOut` and `connect` leave orphaned credentials
- **Location:** `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift:66-74`, `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift:14-33`
- **What:** `signOut` fires `POST /logout` with `try?` and unconditionally clears local tokens, so a failed logout wipes the local refresh token while the server-side one stays valid. Symmetrically, `connect` writes Keychain tokens *before* `dao.save(record)`, so a `dao.save` throw leaves Keychain tokens under a serverID with no matching `ABSServerRecord` (and `clear()` is keyed off that record, so nothing ever removes them).
- **Why:** Both paths strand credentials — a usable refresh token on the server, or an unreachable Keychain entry that leaks across relaunches.
- **Action:** Distinguish logout failure from local clearing (retry/warn), and persist the server record first (or roll back `tokens.clear()` in a catch) so Keychain + DB write atomically.
- **Severity:** Low

---

## 7. Performance

### 7.1 `TextNormalizer` recompiles 4-5 `NSRegularExpression`s on every `normalize()`
- **Location:** `EchoCore/Services/Narration/TextNormalizer.swift:28-29,38,44`
- **What:** `replaceStreetVsSaint`, `stripThousandsSeparators`, and `normalizeRomanNumeralChapters` build their `NSRegularExpression` with `try!` inside the method body, so every call recompiles the patterns.
- **Why:** `normalize()` runs once per text chunk during narration (potentially thousands per book); regex compilation dominates the tiny substitutions, adding avoidable CPU to the narration hot path.
- **Action:** Hoist each compiled regex into a `private static let`.
- **Severity:** Medium

### 7.2 Reader collection-view coordinator resolves cards by O(sections×items) linear scan
- **Location:** `EchoCore/Views/ReaderFeedCollectionView.swift:231-238,243,539,565,576`
- **What:** `Coordinator.card(for:)` is a nested linear scan over all sections, invoked from `cell(for:)` (every dequeue), `didSelectItemAt`, `contextMenuConfiguration`, and `updateChapterTitle` (every `scrollViewDidScroll`). The view model already builds a `cardIndexByBlockID` dictionary the coordinator doesn't use.
- **Why:** Each cell render and scroll tick walks the whole book's card array; impact scales with full-book card count → scroll-path inefficiency that grows with book length (cheap string compares keep it Medium, not severe).
- **Action:** Maintain a `[cardID: ReaderCardItem]` (and `[cardID: IndexPath]`) map when sections are assigned and resolve via that map.
- **Severity:** Medium

### 7.3 `ReaderFeedViewModel.reload()` does the full book load + DB reads synchronously on main
- **Location:** `EchoCore/ViewModels/ReaderFeedViewModel.swift:94-304`
- **What:** `reload()` runs `blocksByChapter`, TOC fetch, section/heading construction, a LEFT-JOIN timeline query, and an unconditional whole-book word-timing fetch synchronously inside the `@MainActor` view model; `searchQuery.didSet` reloads per keystroke. (The narration-burst trigger *is* coalesced via a 250 ms quiet window in `ReaderTab.swift:244-261`.)
- **Why:** For large EPUBs this blocks the main thread during card-feed construction and word-cache building, risking a hang on book open and search.
- **Action:** Move the DB reads and section/heading assembly off the main actor (background task returning prepared structs) and assign back on `@MainActor`; debounce search.
- **Severity:** Medium

### 7.4 `StatsRepository` re-scans the whole `playback_event` table per chart
- **Location:** `Shared/Stats/StatsRepository.swift:98,188-203`
- **What:** `fetchSpeedTrend`, `fetchTimeOfDayHistogram`, `fetchSessionLengthDistribution`, and `fetchOverview` each call `fetchSegments(.distantPast, .distantFuture)` independently, each decoding every row with an `ISO8601DateFormatter`.
- **Why:** A Stats screen with several all-time charts scans and string-parses the entire history multiple times.
- **Action:** Fetch the all-time segment array once and pass it to the aggregators.
- **Severity:** Medium

### 7.5 `ISO8601DateFormatter` allocated per-row and per-call across `StatsRepository`
- **Location:** `Shared/Stats/StatsRepository.swift:23,45-50,80,155,305,319,407`
- **What:** Each fetch constructs a fresh `ISO8601DateFormatter`, and `fetchDailyReviewCounts` allocates one *inside its per-row map closure* (line 305) for every emitted day.
- **Why:** `ISO8601DateFormatter` is expensive to allocate/configure; per-row creation inflates parse time for large histories.
- **Action:** Use a single shared/`static` formatter for all parse/format operations.
- **Severity:** Medium

### 7.6 `PlaylistView` re-scans all bookmarks per chapter (O(chapters×bookmarks))
- **Location:** `EchoCore/Views/PlaylistView.swift:224-234`
- **What:** Inside the per-chapter loop, `recomputePlaylistRows` filters and sorts the entire `model.bookmarks` array for each chapter.
- **Why:** A book with many chapters and bookmarks rebuilds rows in O(chapters×bookmarks) on the main actor → stutter when editing/filtering large playlists.
- **Action:** Pre-bucket bookmarks by owning chapter once (single binning pass), then index per chapter.
- **Severity:** Medium

### 7.7 Cover signature / thumbnail decode-and-redraw with no in-memory result cache
- **Location:** `EchoCore/Services/DominantColorExtractor.swift:51-137`, `EchoCore/Services/ArtworkCache.swift:126-159`
- **What:** `signature(from:)` draws the cover into a 100×100 context and walks 10k pixels per call with no `CoverSignature` cache; `generateThumbnails`/`makeWatchThumbnailData` re-render per call (only the watch JPEG is version-cached).
- **Why:** Repeated requests for the same cover (scheme change, re-layout, repeated sync) redo decode+redraw work on a UI-appearance path.
- **Action:** Cache derived signatures/thumbnails keyed by artwork identity/version.
- **Severity:** Low

### 7.8 Reader cells re-format start-time strings per visible cell on every update
- **Location:** `EchoCore/Views/ReaderFeedCollectionView.swift:96-100,276-278,316-318`
- **What:** On each alignment/start-time change, `updateUIView` iterates `visibleCells` calling `Duration.seconds(...).formatted(.time(...))` per cell, and `cell(for:)` repeats it per dequeue.
- **Why:** `FormatStyle` time formatting is non-trivial and re-derives the same `m:ss` string per aligned block during scroll/alignment refresh.
- **Action:** Precompute/cache formatted start-time strings keyed by `blockID` when `audioStartTimeByBlockID` changes.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 Reader feed cells expose nothing curated to VoiceOver
- **Location:** `EchoCore/Views/Cells/ParagraphCardCell.swift:5-176`, `HeadingCardCell.swift:5-175`, `ImageCardCell.swift:48-71`, `ChapterDividerCell`, `EchoCore/Views/ReaderFeedCollectionView.swift:585-612`
- **What:** The reader cells set no `isAccessibilityElement`/`accessibilityLabel`/`accessibilityTraits`. Body text is still read (a `UILabel` in a cell is an a11y element by default), but headings lack the `.header` trait, the per-cell debug timestamp leaks as a separate element, cells aren't grouped, and `ImageCardCell` exposes no alt text (falls back to a bare "photo" SF Symbol).
- **Why:** The primary reading surface of an accessibility-first study app gives a degraded, uncurated VoiceOver experience and an App Store accessibility-quality risk (text is not invisible, hence Medium not High).
- **Action:** Make each cell an a11y element with a label from the block text, a `.staticText`/`.header` trait per kind, a meaningful image label/caption, and expose tap-to-seek as a custom a11y action; suppress the debug timestamp (§8.4).
- **Severity:** Medium

### 8.2 Reader body text ignores system Dynamic Type
- **Location:** `Shared/ReaderSettings.swift:30-69`, `EchoCore/Views/Cells/ParagraphCardCell.swift:76-138`, `HeadingCardCell.swift:8-15,92-103`
- **What:** `uiFont(forTextStyle:)` returns `UIFont.systemFont(ofSize:)` at a hardcoded base size scaled only by the in-app slider, never via `UIFontMetrics`/`preferredFont`; `HeadingCardCell`'s `adjustsFontForContentSizeCategory = true` is dead because `configure()` overwrites the font.
- **Why:** Users relying on the OS Larger Accessibility Sizes can't enlarge the main reading content via the system control (the in-app slider works, softening impact to Medium).
- **Action:** Scale the computed point size through `UIFontMetrics(forTextStyle:).scaledFont(for:)` so the reader honors the system content-size category in addition to the slider.
- **Severity:** Medium

### 8.3 Active-block highlight is a near-invisible 0.95 vs 1.0 alpha delta
- **Location:** `EchoCore/Views/Cells/ParagraphCardCell.swift:42-47`, `HeadingCardCell.swift:44-49`
- **What:** The only full-cell distinction for the currently-playing block is `contentView.alpha = 1.0` vs `0.95` plus a thin 3 pt bar; a 5% alpha change is effectively invisible and not exposed to VoiceOver as state.
- **Why:** Read-along users (the signature feature) can lose the active paragraph, and the cue is unavailable to assistive tech.
- **Action:** Use a clearly perceptible active treatment (background tint/border) plus a "currently playing" a11y value; don't encode state in near-zero alpha.
- **Severity:** Medium

### 8.4 Always-on alignment debug timestamp shipped in the production reader
- **Location:** `EchoCore/Views/Cells/ParagraphCardCell.swift:23-30,140-147`, `HeadingCardCell.swift:25-32,150-157`, `EchoCore/Views/ReaderFeedCollectionView.swift:96-101,275-280,315-320`
- **What:** Every reader card renders an `anchorLabel` showing the raw audio timestamp ("None", red for locked, grey for interpolated) — a self-described "alignment debugging aid" with no gate.
- **Why:** Per-paragraph timecodes are visible clutter for ordinary readers and read like leaked developer instrumentation.
- **Action:** Gate the overlay behind a debug/developer setting (or remove it).
- **Severity:** Medium

### 8.5 Themed reader cards compute text color against the tint, not the rendered background
- **Location:** `EchoCore/Views/Cells/ParagraphCardCell.swift:90-137`, `HeadingCardCell.swift:85-120`, `Echo macOS/Views/MacReaderFeedView.swift:304-350`
- **What:** With a `chapterThemeColor`, the cell background is forced to white@40%/black@20% but text color comes from `tint.contrastingTextColor` (contrast vs the *tint*, not the actual background); macOS applies the raw theme color with no contrast check at all.
- **Why:** Themed cards can drop below readable contrast (black-on-dark / white-on-light), hurting legibility for the long-form reading the app is built around.
- **Action:** Compute text color against the actual composited background (or pin a readable per-scheme label color); constrain themed text on macOS to a contrast-checked color.
- **Severity:** Medium

### 8.6 Image card & macOS fallbacks are debug-grade and inaccessible
- **Location:** `EchoCore/Views/Cells/ImageCardCell.swift:48-70`, `Echo macOS/Views/MacReaderFeedView.swift:387-390`
- **What:** A missing EPUB image substitutes a generic "photo" SF Symbol with no a11y label and no caption wiring; macOS renders developer strings like `[Image: <path>]`.
- **Why:** Missing illustrations look broken and convey nothing to assistive tech; the bracketed-path fallback is debug UI surfaced to end users.
- **Action:** Expose the caption (or a localized "Image unavailable") as the artwork's a11y label and visually distinguish a genuinely-missing image from a decorative placeholder.
- **Severity:** Low

### 8.7 Two buttons in a single `ToolbarItem` in the standalone Playlist sheet
- **Location:** `EchoCore/Views/PlaylistView.swift:96-105`
- **What:** The non-embedded toolbar puts both "Edit" and "Done" inside one `topBarTrailing` `ToolbarItem`.
- **Why:** SwiftUI doesn't reliably lay out multiple controls in one `ToolbarItem` (they can collapse/render unexpectedly).
- **Action:** Split into separate `ToolbarItem`s or a `ToolbarItemGroup`.
- **Severity:** Low

---

## 9. Dead code / duplication / refactor

### 9.1 Time/duration formatting reimplemented ~10 times
- **Locations:** `EchoCore/Services/NowPlayingController.swift:182` (canonical), plus private copies in `PlayerModel+MarkedPassages.swift:47`, `PlaylistView.swift:62`, `ChapterPickerSheet.swift:46`, `CardInboxView.swift:170`, `Stats/BookStatsView.swift:63`, `Stats/StatsView.swift:217`, `Utilities/ViewModifiers.swift:52`, `TimelineIngestionFactory.swift:392`, `StatsModuleView.swift:55`, `SchedulingSheet.swift:116`, `StudyNotesExportService.swift:129`
- **What:** A canonical `NowPlayingController.formatTime` exists, yet ≥10 files define their own `Int(seconds)/3600 → String(format:)` helper.
- **Action:** Consolidate into one `Shared` `TimeFormatting` utility (or extend `formatTime`) and delete the per-file copies.
- **Severity:** Medium

### 9.2 App-group identifier literal hardcoded in 4+ sites despite `AppGroupDefaults.suiteName`
- **Locations:** `Shared/AppGroupDefaults.swift:7` (constant), duplicated in `EchoCore/Views/Components/Haptic.swift:9`, `EchoCore/Views/Fidget/DoodlePadView.swift:65`, `EchoCore/Services/SettingsManager.swift:380,591`, `Shared/FileLocations.swift:22`
- **What:** The `"group.com.echo.audiobooks"` literal is re-typed instead of referencing the central constant.
- **Why:** A future app-group rename requires editing scattered literals; a missed site silently falls back to a wrong suite and loses shared data.
- **Action:** Reference `AppGroupDefaults.suiteName` everywhere (including as the `FileLocations` default-parameter value).
- **Severity:** Medium

### 9.3 `PlayerModel.swift` core remains 1,594 LOC after the extension split
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:1-1594`
- **What:** Despite eight `PlayerModel+*.swift` extensions, the core still mixes folder/track loading, playback controls, joystick scrubbing/snippet playback, sleep timer, and audio-source switching.
- **Why:** A 1,594-line `@Observable` model is hard to reason about for state and concurrency, raising coupling and merge-conflict risk.
- **Action:** Extract the MARK-delimited sections into `PlayerModel+Loading`, `+ScrubbingSnippet`, `+SleepTimer`, `+AudioSource`.
- **Severity:** Medium

### 9.4 Dead function `concatenateBlocks`
- **Location:** `Shared/EPUBXMLParsing.swift:711-744`
- **What:** ~35 lines documented for "CLI-style sliding-window alignment consumers" with zero callers in app or tests (the in-app DTW path supersedes it).
- **Action:** Delete after a final xref.
- **Severity:** Low

### 9.5 Application Support directory built via raw `FileManager.urls` instead of `FileLocations`
- **Location:** `EchoCore/Services/EPUBAssetStorage.swift:28-34`, `EchoCore/Services/Narration/NarrationCache.swift:16`
- **What:** Two services build the Application Support URL with raw `fm.urls(for:.applicationSupportDirectory,…).first` despite `FileLocations.applicationSupportDirectory` being the documented single source of truth.
- **Action:** Replace with `FileLocations.applicationSupportDirectory`.
- **Severity:** Low

### 9.6 Oversized files (>700 LOC) with concrete split seams
- **Locations:** `PlaylistView.swift:990`, `PlaybackController.swift:974`, `Echo Watch App/Services/WatchViewModel.swift:974`, `Echo Watch App/Views/PlayerPage.swift:969`, `Echo macOS/Views/MacPlayerModel.swift:805`, `Shared/EPUBXMLParsing.swift:745`, `WatchAppSettingsView.swift:729`, `SettingsManager.swift:691`
- **What:** Each exceeds the 500-LOC guideline with natural MARK seams (e.g. `PlaybackController`: Navigation / Skip&Seek / Loop / Track-End; `EPUBXMLParsing`: one file per `XMLParserDelegate`; `SettingsManager`: domain-grouped property clusters).
- **Action:** Split along existing MARK boundaries into per-concern extensions/files.
- **Severity:** Low

### 9.7 Playback-speed label formatting duplicated across targets
- **Locations:** `EchoCore/DailyPlanner/SchedulingSheet.swift:38`, `RealTimeProjectionService.swift:103` (ad-hoc `String(format:"%.1f",speed)+"x"`), `Echo Watch App/Views/PlayerPage.swift:402` (dedicated `formatSpeed` not shared)
- **What:** Speed display is formatted three ways (incl. a watch-only helper).
- **Action:** Promote one shared speed-formatting helper and call it from all speed labels.
- **Severity:** Low

### 9.8 watchOS hardcodes its own speed-preset list
- **Location:** `Echo Watch App/Services/WatchViewModel.swift:108-110`, `EchoCore/Services/SettingsManager.swift:28`, `EchoCore/Services/WatchCommandRouter.swift:96-99`
- **What:** `WatchViewModel.availableSpeeds` is a duplicated literal `[1.0,1.25,1.5,2.0,3.0]`; the phone maps incoming speeds back via `firstIndex`, so a phone speed not in the watch's list silently fails to update the watch display.
- **Why:** The two preset lists can drift, after which the watch indicator stops reflecting the phone's actual speed.
- **Action:** Have the watch consume the shared `SettingsManager.Defaults.speedPresets` (or sync the list in the watch context).
- **Severity:** Low

---

## 10. Cross-cutting recommendations

1. **Decide isolation deliberately before the Swift-6 migration.** The ~30 concurrency warnings (§3.2, §3.3, §3.6) all stem from `MainActor`-default isolation colliding with hand-rolled `actor`/`nonisolated` boundaries. Pick one model per subsystem — `@MainActor` orchestration with explicitly-`nonisolated`/`Sendable` compute helpers — rather than silencing case-by-case. The narration engine (§3.2) is the highest-value place to start. The two genuine runtime races (§3.1, the `Bookmarks` closure in §3.6) should be fixed now regardless of the migration.

2. **One book-time abstraction for multi-`.m4b`.** §5.1, §5.2, §5.5, §5.20 are all the same root confusion between *track-local* time and *book-global* time (and between *track index* and *book index*). A single helper that resolves "current book + its cumulative offset" by URL, and a `bookDuration` accessor that already encodes `isMultiM4B ? totalBookDuration : durationSeconds` (which most call sites use, but the ABS push and the chapter math don't), would close all four.

3. **Unify the bookmark persistence seam.** §5.28 and §5.29 are the same architectural split: iOS uses `UserDefaults`/sidecar, Mac/watch use GRDB, and the widget writes to a third store nobody reads. Route every platform (and the widget intent) through `BookmarkDAO`/`BookmarkStore.configureForDatabase` so bookmarks are write-once, read-everywhere.

4. **Make GRDB-backed enums and re-renders forward-compatible.** §5.24 (enum decode crash) mirrors the already-solved `BatchItemKind` pattern — apply it to `TimelineItemType`/`GranularityLevel` and audit other `RawRepresentable & Codable` enums fetched from the DB. Separately, the narration cache (§5.12, §5.15) needs `renderVersion`/voice to be part of selection and the token to be collision-resistant.

5. **Stop swallowing sync/IO errors with `try?`.** §5.21, §5.22, §6.6 each discard errors on a path where the user cares about the outcome (CloudKit, ABS sync, logout). At minimum `os_log` them; ideally surface a typed failure state. Pair this with the `accountStatus`/TLS prechecks so failures are diagnosable rather than silent.

6. **Reconcile the macOS/watch reimplementations against iOS.** §5.30, §5.31, §9.8 show Mac/watch player logic that has drifted from the iOS source of truth (hardcoded boost/rewind, single-track restore, duplicated presets). Where a second implementation is truly needed, drive it from the shared `SettingsManager`/`BookPreferencesService` values instead of literals; the `cross-platform-parity-reviewer` agent should gate shared-logic changes.

---

## 11. What was NOT audited

- `ThirdParty/MisakiSwift/` (vendored G2P) — treated as a black box; not reviewed.
- Algorithmic correctness of the alignment DTW (`TokenDTW`), the Whisper transcription pipeline, and the Kokoro G2P/phoneme math — only obvious logic/bounds issues surfaced, not domain correctness.
- ONNX Runtime model I/O correctness beyond the documented tensor contract.
- `Tools/` (Python transcription pipeline), `Scripts/`, `fastlane/` — out of scope.
- Test targets (`EchoTests`, `EchoUITests`, `Echo Watch AppTests`) — light scan only; no coverage assessment. Note: where a High finding lacks a regression test (e.g. §5.1, §5.20, §5.28), adding one is recommended but not separately filed.
- Build settings / Xcode project structure beyond the shared scheme and the `SWIFT_DEFAULT_ACTOR_ISOLATION`/`SWIFT_VERSION` settings noted above.
- Per-target entitlements and App-Group identifiers were read only where a finding touched them (§9.2); a full entitlements/provisioning audit was not done.
- StoreKit product configuration (`.storekit`) and IAP receipt validation — not exercised.
- Localization / string catalogs — not assessed.
- GRDB migration *execution* on real upgrade paths — migrations were read for safety (append-only, idempotency, indexes) but not run against historical DBs.

---

## 12. Verification

Spot-check pattern: command-click any `path:line` to land on the cited line. Each High finding below was opened during the adversarial verification pass (and the top items re-read by hand).

- **§5.1** — `EchoCore/Services/PlaybackController.swift:195-196`. Confirm `state.m4bBooks[state.currentIndex].cumulativeStartOffset` indexes the books array by the track index; cross-ref `M4BParser.parseFolder` (filename sort, `trackIndex = i` post-sort) and `PlaylistManager.swift:78-108` (reorderable `tracks`).
- **§5.20** — `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift:92-94`. Confirm `current = cumulativePlaybackTime` (book-absolute) is paired with `duration = durationSeconds` (current track); compare to `PlaybackProgressPresenter.swift:100` which uses `isMultiM4B ? totalBookDuration : durationSeconds`.
- **§5.28** — `Echo Widget/Models/AppIntent.swift:55-60` (writes `AppGroupDefaults.shared` under `bookmarks_<folderKey>`) vs `EchoCore/Services/Persistence.swift:24,263-273` (iOS reads `UserDefaults.standard`) — the keys never meet.
- **§5.12** — `EchoCore/Services/Export/NarrationCacheSource.swift:13-54` (voice/version-agnostic listing) + `NarrationFileNaming.swift:44-48` (`chapterIndex` ignores `-v{N}`/voice) + `MacBatchProcessingService.swift:322-366` (no stale sweep). Two same-index files concatenate in `AudioExportService.exportM4B`.
- **§5.11** — `EchoCore/Services/Narration/OnnxKokoroEngine.swift:103-104`. `initializationTask` set once, never reset on throw; `store()` only sets `session` on success. The engine is `PlayerModel.narrationTTS` (a session-lived `lazy var`).
- **§3.2** — `EchoCore/Services/Narration/OnnxKokoroEngine.swift:40,56-59,73,88,115,126-147`. The build log (`/tmp/echo_build_warnings.txt`) shows 16 "main actor-isolated … cannot be called from outside of the actor" warnings on this file; root cause is `actor` + `@MainActor`-inferred helpers under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- **§3.1** — `Echo Watch App/Services/WatchViewModel.swift:317-358,584-594`. Delegate methods lack `nonisolated`; `requestCurrentState()` reads `WCSession.default`/`activationState` synchronously. Compare the correct `nonisolated` + `Task { @MainActor }` pattern in `WatchSyncManager.swift:142-196`.
- **§5.10** — `EchoCore/Services/DefaultVisualizerTap.swift:138`. The build log shows two "argument 'realp'/'imagp' must be a pointer that outlives the call" warnings on `DSPSplitComplex(realp:&realp, imagp:&imagp)`.
- **Dropped (false positive):** the raw finding "PlayerLoadingCoordinator mutates `@MainActor` state from background Task" was refuted — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes the un-annotated class `@MainActor`, so its bare `Task {}` inherits main-actor isolation (`PlayerLoadingCoordinator.swift:12`, `PlaybackState.swift:12-13`). Not in this report.

If any finding doesn't reproduce at the cited line, flag the specific §N.M and I'll re-investigate.
