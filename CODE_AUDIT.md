# Echo: Audiobook Study Player — Code Audit (Wave-2 + Architecture)

Generated **2026-06-13** (session 3). Scope: **48,756 Swift LOC across 406 files + 1 Metal shader**, in targets **Echo (iOS)**, **Echo Watch App (watchOS)**, **Echo Widget**, **Echo macOS**, plus shared `EchoCore/` and `Shared/`. Excluded: `Tools/` (Python), `Scripts/`, `docs/`, `fastlane/`, asset catalogs, and SPM dependency internals (GRDB, WhisperKit, ZIPFoundation, swift-transformers, swift-crypto). Test targets: light scan.

**This is a layered audit.** It runs an **architecture-first lens** (MVVM separation, protocol/DI reality, cross-platform parity, `PlayerModel` teardown) and feeds those structural findings into a full **bug / concurrency / security / performance sweep**, so symptoms are reported against their root cause. The prior session-2 report (which remediated 34 findings) is preserved at `docs/CODE_AUDIT_2026-06-13_session2.md`; this report deliberately targets the **Wave-2 delta** (CarPlay, soundscapes/visualizer, `.apkg`/AnkiConnect, location capture, on-device alignment, macOS tri-pane) plus structural issues a statement-level scan misses.

**Compiler ground truth (this audit):** a fresh `make build-tests` returned **`** TEST BUILD SUCCEEDED **`** with **~30 distinct warnings** (90 raw, deduped across targets). Critically, several are **Swift-6-language-mode errors-in-waiting** — main-actor isolation violations in Wave-2 code (`PlaybackSessionRecorder`, `InlineFlashcardTriggerController`, CarPlay command handlers, `ApkgImportService`, `DefaultVisualizerTap`). This is a **regression** from session-2's "17 warnings, all fixed" baseline; the new subsystems were merged without the isolation discipline session-2 established. See §3.1.

**Verification discipline:** every High was confirmed by opening the cited lines. The audit also **caught over-reporting** — three "performance/state bugs" turned out to live in **dead code** (`TranscriptOverlayView`, `ContentCardEditor`, the Timeline-Feed cluster); they were demoted to deletion candidates rather than propagated as live bugs. See §12.

Findings cite `path/to/file.swift:LINE`. No code was changed.

---

## 1. Executive summary

1. **[High] Dead "Timeline Feed prototype" cluster (~1,500 LOC) ships but is unreachable** — §9.1 — `EchoCore/ViewModels/TimelineFeedViewModel.swift` + 9 sibling files.
2. **[High] The protocol-oriented / DI design is aspirational, not real** — §10.1 — 6 protocols + 5 mocks exist; none is an injection seam; `PlayerModel` hard-constructs every service.
3. **[High] macOS↔iOS alignment handoff is broken by divergent block-ID schemes** — §5.1 — every Mac-produced anchor references a non-existent iOS block and is silently dropped.
4. **[High] Swift-6 main-actor isolation regressions (compiler-confirmed)** — §3.1 — `PlaybackSessionRecorder` (×4), `InlineFlashcardTriggerController` (×2), CarPlay handlers (×3), `ApkgImportService` (×2), `DefaultVisualizerTap`.
5. **[High] WhisperKit stale-model reference silently stops re-alignment** — §5.2 — `release()` never nils `whisperKit`, so a second run transcribes against an unloaded model.
6. **[High] `.apkg` export generates colliding `notes.id`/`cards.id` → PRIMARY KEY abort** — §5.3 — export fails entirely for non-trivial decks.
7. **[High] JSON deck import inserts flashcards without ensuring the `audiobook` row → FK abort** — §5.4.
8. **[High] CloudKit *public*-DB sync overwrites (clobbers) other users' shared anchors** — §6.1 — community data loss + malicious-wipe vector.
9. **[High] `WatchSyncManager` mutates state from off-main `WCSessionDelegate` callbacks** — §3.2 — data race on non-`@MainActor` type.
10. **[High] `PlayerModel` teardown gaps: nonisolated-deinit `Timer` invalidation + `continuousAlignmentService` never stopped** — §3.3 — latent "bad free" / leaked 15 s timer + WhisperKit task. (Coordinator-closure retain graph verified **clean** — §3.4.)

---

## 2. Quick wins (≤30 minutes each)

### 2.1 Delete the dead Timeline-Feed cluster
- **Location:** see §9.1 file list
- **Action:** Remove the unreachable views/VM/services after confirming the cascade (§9.1). Biggest single LOC reduction available.
- **Severity:** High (impact) / trivial effort

### 2.2 Delete orphaned `TranscriptOverlayView` + `ContentCardEditor`
- **Location:** `EchoCore/Views/Components/TranscriptOverlayView.swift`, `EchoCore/Views/ContentCardEditor.swift`
- **Action:** Zero references confirmed (§12). Deleting also removes the DEBUG paywall-bypass in dead code (§6.4).
- **Severity:** Medium

### 2.3 Clear the trivial compiler warnings
- **Location:** `EchoCore/Views/ContentCardEditor.swift:105` (`var`→`let`), `EchoCore/Services/DefaultSoundscapeMixer.swift:48` (unused `engine`), `EchoCore/Services/SnippetPlayer.swift:87` (`self` written never read), `EchoCore/Services/AlignmentService.swift:406` (unused `write` result), `EchoCore/ViewModels/PlayerModel+MarkedPassages.swift:25` (unused `insert` result), `:40` (optional string interpolation)
- **Action:** Mechanical fixes; each clears a real warning.
- **Severity:** Low

### 2.4 Regenerate `ARCHITECTURE.md`
- **Location:** `ARCHITECTURE.md` (last generated 2026-06-11)
- **Action:** Run `make architecture`. The doc lists phantom files (`AudioRingBuffer.swift`, `SilenceAnalyzer.swift`, `PlaybackStateDAO.swift`, `SettingsDAO.swift` — none exist) and presents the dead Timeline cluster as live. See §9.10.
- **Severity:** Low

### 2.5 Merge duplicate `.onAppear` on `RootTabView`
- **Location:** `EchoCore/Views/RootTabView.swift:146-151` and `:167-169`
- **Action:** Collapse two `.onAppear` blocks into one to make ordering explicit.
- **Severity:** Low

---

## 3. Concurrency

### 3.1 Swift-6 main-actor isolation regressions across Wave-2 subsystems
- **Location:** `EchoCore/Services/PlaybackSessionRecorder.swift:15,20,26,111`; `EchoCore/Services/InlineFlashcardTriggerController.swift:57,133`; `EchoCore/ViewModels/PlayerModel.swift:848,857,869` (CarPlay handlers); `EchoCore/Services/ApkgImportService.swift:81,94`; `EchoCore/Services/CoverThemeBuilder.swift:194`; `EchoCore/Services/DefaultVisualizerTap.swift:35`; `EchoCore/Services/AudioEngine.swift:283` (non-Sendable `Timer` captured in `@Sendable` closure)
- **What:** ~12 sites call main-actor-isolated methods from synchronous nonisolated contexts (or capture non-Sendable state in `@Sendable` closures); the compiler labels several "this is an error in the Swift 6 language mode."
- **Why:** These compile in Swift 5 mode but will hard-fail the moment the project moves to Swift 6 — and each is a real latent race (e.g. CarPlay command handlers touch `PlayerModel` main-actor state from the MediaPlayer command queue). This regresses the session-2 milestone that drove warnings to a known, fixed set.
- **Action:** Group by owner: annotate the delegate/recorder types `@MainActor` and hop the framework-callback bodies onto the main actor (the same fix session-2 applied to the Widget intents); for `AudioEngine:283`, capture a Sendable token instead of the `Timer`.
- **Severity:** High

### 3.2 `WatchSyncManager` mutates state from off-main `WCSessionDelegate` callbacks
- **Location:** `EchoCore/Services/WatchSyncManager.swift:12,40,84-196`
- **What:** The type is a plain `NSObject: WCSessionDelegate` (not `@MainActor`); WatchConnectivity invokes its delegate methods on a background queue, yet `syncToWatch`/`sendThumbnailIfNeeded` read-modify-write `lastSyncedArtworkKey` and invoke provider closures that wrap `@MainActor PlayerModel` state.
- **Why:** Data race on a non-`Sendable` `String?` and on the provider closures when the live-send path (main) and a delegate callback (background) overlap. Verified: class declaration is non-isolated.
- **Action:** Mark `WatchSyncManager` `@MainActor` and funnel every `WCSession` access through one executor; the delegate methods already hop for activation, so this only formalizes the rest.
- **Severity:** High

### 3.3 `PlayerModel` teardown: nonisolated-deinit `Timer` invalidation + un-stopped continuous alignment
- **Location:** `EchoCore/Services/SleepTimerManager.swift:18-20`, `EchoCore/Services/TimelineService.swift:49-50`, `EchoCore/ViewModels/PlayerModel.swift:893-911`
- **What:** `SleepTimerManager` and `TimelineService` are `@MainActor @Observable` but invalidate a main-actor `Timer` from a **nonisolated `deinit`** without the `MainActor.assumeIsolated` wrapper that `PlayerModel`/`AudioEngine` use. Separately, `PlayerModel.deinit` (verified, full body read) never calls `continuousAlignmentService?.stop()`, so its 15 s repeating `Timer` + WhisperKit `Task` keep running after teardown.
- **Why:** Invalidating a runloop-scheduled `Timer` from whatever thread ARC runs the deinit on is the "bad free" signature; the un-stopped continuous service leaks a timer/task and an unbalanced `WhisperSession` reference.
- **Action:** Add `continuousAlignmentService?.stop(); continuousAlignmentService = nil` to `PlayerModel.deinit`. For the two timer deinits, **match the existing `assumeIsolated` pattern** rather than converting to `isolated deinit` — see the caveat in §3.9.
- **Severity:** High

### 3.4 (Verified clean) Coordinator-closure retain graph has no cycles
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:529-837`
- **What:** All ~24 `coordinator_*`/`on*`/`*Provider` closures use `[weak self]`; `playbackController.delegate` is `weak`; `WatchConnectivityCoordinator` holds `weak playerModel`.
- **Why:** Reported explicitly as a **negative result** — the decomposition's most-suspected failure mode is sound and needs no change. Recorded so a future reviewer doesn't re-investigate.
- **Severity:** _N/A (informational)_

### 3.5 `ContinuousAlignmentService.stop()` releases the WhisperKit ref before the in-flight task unwinds
- **Location:** `EchoCore/Services/ContinuousAlignmentService.swift:59-116`
- **What:** `stop()` cancels `transcriptionTask` then immediately calls `WhisperSession.shared.release()`, while the cancelled task's own `acquire`/`defer { isProcessing = false }` may still be resolving.
- **Why:** Contributes to `WhisperSession` retain-count imbalance (§5.2) — a `loadModelIfNeeded` `acquire` can land after `stop()` already released, leaving the ~40 MB model retained.
- **Action:** `await transcriptionTask?.value` (or release inside the task's own `defer`) before calling `release()`.
- **Severity:** Medium

### 3.6 `AutoAlignmentService` has no `deinit` to invalidate its model-unload `Timer`
- **Location:** `EchoCore/Services/AutoAlignmentService.swift:52,507-515`
- **What:** `scheduleModelUnload()` installs a `Timer`; the service has no `deinit`, so dropping the service before the keep-alive fires leaves the timer (and a queued `release()` `Task`) live.
- **Why:** On rapid book switches, stale unload timers stack and a pending `release()` can decrement a count the new service re-acquired.
- **Action:** Add a `deinit` invalidating the timer; prefer a cancellable `Task.sleep` handle over `Timer`+nested `Task`.
- **Severity:** Medium

### 3.7 `NowPlayingController` is not `@MainActor` despite driving MediaPlayer
- **Location:** `EchoCore/Services/NowPlayingController.swift:7,47-164`
- **What:** Plain `final class` whose every method touches `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`/`UIImage` (main-thread-only), called at audio-tick rate via `PlaybackProgressPresenter`.
- **Why:** Correct today only because callers happen to be main; no type-level guarantee. The command handlers already hop with `Task { @MainActor }`, confirming the type should be isolated.
- **Action:** Mark the type `@MainActor`; keep the hops inside the off-main command-handler closures.
- **Severity:** Medium

### 3.8 `LocationCaptureService` builds/drives CoreLocation clients on its actor, not main
- **Location:** `EchoCore/Services/LocationCaptureService.swift:38-80,108-123`
- **What:** Since commit `a36e040` moved client construction out of `init`, the `lazy` `CLLocationManager`/`CLGeocoder` are now built on the service's actor executor; `CLLocationUpdate.liveUpdates()` and `reverseGeocodeLocation` are driven there.
- **Why:** CoreLocation expects main-thread-ish delegate dispatch; on a custom actor executor it can drop `liveUpdates()` callbacks or deliver on an unexpected queue. The timeout path also returns `nil` without `cancelGeocode()`, so a slow geocode runs past its 10 s budget and serializes the next capture.
- **Action:** Build/drive the CoreLocation clients via a small `@MainActor` helper the actor awaits into; keep only the cache on the actor; call `cancelGeocode()` on timeout.
- **Severity:** Medium

### 3.9 (Caveat) Do not convert teardown to `isolated deinit` to chase the 26.2 crash
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:896`, `EchoCore/Services/AudioEngine.swift:97`
- **What:** `PlayerModel`/`AudioEngine` already use `MainActor.assumeIsolated` in deinit yet the CI gate still hits a "bad free" on the **iOS 26.2 simulator** — attributed to an Apple isolated-deinit runtime bug (CI is build-only pending 26.3+).
- **Why:** Because the runtime fault is *in* isolated-deinit, converting more deinits to `isolated deinit` risks widening the crash surface, not fixing it. The §3.3 deinit smells are worth fixing for **consistency/correctness**, but are **not** asserted to be the root cause of the 26.2 crash.
- **Action:** Standardize on the `assumeIsolated` wrapper; revisit `isolated deinit` only after the runtime is fixed. Keep `PlayerModelAccentTests` skipped on CI until then.
- **Severity:** _Informational / guidance_

### 3.10 `StandaloneTranscriptionService` cancellation can't interrupt an in-flight chapter
- **Location:** `EchoCore/Services/StandaloneTranscriptionService.swift:59-77`
- **What:** The detached loop checks `Task.isCancelled` between chapters, but `transcribeChapter`'s long `await wk.transcribe(...)` has no cancellation check, so `cancel()` only stops the *next* chapter.
- **Why:** Cancelling mid-chapter still runs a full transcription (tens of seconds), wasting CPU/battery and delaying `WhisperSession.release()`.
- **Action:** Thread `Task.checkCancellation()` into `transcribeChapter`; prefer a structured child task over `Task.detached`.
- **Severity:** Medium

### 3.11 Repeating timers rely on `MainActor.assumeIsolated` with inconsistent run-loop modes
- **Location:** `EchoCore/Services/ContinuousAlignmentService.swift:59-64`, `Echo Watch App/Services/WatchViewModel.swift:175-186,848-924`
- **What:** Several repeating `Timer`s run their body in `assumeIsolated`; unlike `AudioEngine` (which re-adds its timer in `.common` mode), these use `.default`, so they silently pause during scroll/tracking, and `assumeIsolated` traps if a timer ever fires off-main.
- **Why:** Fragile timing + crash-on-violation pattern for periodic services.
- **Action:** Drive these with a cancellable `Task.sleep` loop, or standardize run-loop mode and use the main-actor-bound timer closure form.
- **Severity:** Low

### 3.12 `CarPlaySceneDelegate` is non-isolated but calls into `@MainActor CarPlayManager`
- **Location:** `EchoCore/CarPlay/CarPlaySceneDelegate.swift:3-23`
- **What:** Plain `UIResponder` subclass calls a `@MainActor` method synchronously; compiles only because scene-delegate methods are implicitly main-actor today.
- **Why:** Relies on an unstated guarantee; brittle under stricter isolation.
- **Action:** Annotate `CarPlaySceneDelegate` `@MainActor` to make the assumption explicit.
- **Severity:** Low

---

## 4. API modernity

### 4.1 CarPlay uses `setRootTemplate(_:animated:)` deprecated since iOS 14
- **Location:** `EchoCore/CarPlay/CarPlayManager.swift:37`
- **What:** Compiler-confirmed deprecation warning.
- **Why:** Deprecated API path; replace before it's removed.
- **Action:** Use the `setRootTemplate(_:animated:completion:)` replacement.
- **Severity:** Medium

### 4.2 `templateApplicationScene(_:didDisconnect:)` nearly matches a different optional requirement
- **Location:** `EchoCore/CarPlay/CarPlaySceneDelegate.swift:17`
- **What:** Compiler warns the method "nearly matches optional requirement `templateApplicationScene(_:didSelect:)`" — i.e. it is **not** an actual protocol requirement and may never be called.
- **Why:** A disconnect handler that the framework never invokes is a silent functional gap (CarPlay teardown never runs).
- **Action:** Verify the intended `CPTemplateApplicationSceneDelegate` signature; rename to the real requirement or remove.
- **Severity:** Medium

### 4.3 `CLGeocoder.reverseGeocodeLocation` superseded by `MKReverseGeocodingRequest`
- **Location:** `EchoCore/Services/LocationCaptureService.swift:32,68`
- **What:** Uses the older single-in-flight `CLGeocoder` path.
- **Why:** The MapKit replacement is structured-concurrency-native and cancellable, which pairs better with the timeout issue in §3.8.
- **Action:** Migrate reverse geocoding to `MKReverseGeocodingRequest` (or document the single-request constraint + `cancelGeocode()`).
- **Severity:** Low

### 4.4 Batch `whisperKit.transcribe(audioArrays:)` swallows errors as `nil`
- **Location:** `EchoCore/Services/AlignmentTranscript.swift:115`, `EchoCore/Services/StandaloneTranscriptionService.swift:134`, `Echo macOS/Services/MacGlobalAlignmentService.swift:207`
- **What:** Uses the non-throwing array-batch WhisperKit API; per-array failures (decode/OOM) become `nil`, indistinguishable from genuine silence.
- **Why:** Real failures are logged as "silence" and skipped, masking model problems in the alignment pipeline.
- **Action:** Use the throwing single-array API and distinguish failure from silence.
- **Severity:** Low

### 4.5 `DefaultChimePlayer` uses a synchronous scheduling call with an async alternative
- **Location:** `EchoCore/Services/DefaultChimePlayer.swift:67`
- **What:** Compiler suggests the asynchronous alternative function.
- **Why:** Modernization; the sync form can block the calling context.
- **Action:** Adopt the async `scheduleFile` variant where appropriate.
- **Severity:** Low

---

## 5. Bugs / logic errors

### 5.1 macOS↔iOS alignment handoff broken by divergent EPUB block-ID schemes
- **Location:** `Echo macOS/Services/MacEPUBParser.swift:98` (`"epub-mac-s\(spineIdx)-b\(blockCount)"`) and `Echo macOS/Services/MacGlobalAlignmentService.swift:162` vs `EchoCore/Services/EPUBImportService.swift:196` (`"epub-\(audiobookID)-s\(i)-b\(blockIdx)"`), ingested at `EchoCore/Services/EPUBAutoImportScanner.swift:143-159`
- **What:** The Mac aligner writes `…alignment.json` keyed by its own parser's block IDs; iOS upserts `export.blockId` straight into `epub_block.id`. The two ID formats can never match (verified).
- **Why:** **Every Mac-produced anchor references a non-existent iOS block and is silently dropped** at timeline recalculation — the entire macOS-alignment feature produces no visible result on the phone. The two parsers also emit different block *sets* (Mac ignores `linear="no"`, headings, images), so even a unified ID wouldn't align them.
- **Action:** Have `MacGlobalAlignmentService` align against the shared `XHTMLBlockDelegate`/`EPUBImportService` block stream (reuse the iOS ID formula + per-spine counter); delete `MacEPUBParser`'s parallel extraction.
- **Severity:** High

### 5.2 WhisperKit stale-model reference silently stops re-alignment
- **Location:** `EchoCore/Services/AutoAlignmentService.swift:486,503,512`
- **What:** `loadWhisperModel()` early-returns when `whisperKit != nil`, but the keep-alive `Timer` calls `WhisperSession.shared.release()` **without ever setting `whisperKit = nil`** (verified). After a release-driven unload, the next run reuses a WhisperKit whose CoreML models were unloaded.
- **Why:** Transcription returns empty/garbage → alignment silently produces no anchors after the first keep-alive window — the project's headline feature degrades with no error surfaced. (Note: per-chunk `scheduleModelUnload()` rescheduling is wasteful but self-cancels; the real defect is the un-nil'd reference.)
- **Action:** Treat `whisperKit` as a strict mirror of the shared box — set `whisperKit = nil` in the unload/`release()` path; acquire once at pipeline start and release once at completion, not per chunk.
- **Severity:** High

### 5.3 `.apkg` export produces colliding `notes.id`/`cards.id` → PRIMARY KEY abort
- **Location:** `EchoCore/Services/ApkgExportService.swift:231,246`
- **What:** `noteID = Int64(now*1000) + Int64(card.id.hashValue % 1000)` and `cardID = noteID + 1` (verified). Cards exported in the same millisecond can produce equal `noteID`s, and `cardID = noteID+1` can equal the next card's `noteID`; `hashValue` is also per-process randomized.
- **Why:** `notes.id`/`cards.id` are `INTEGER PRIMARY KEY`; a collision throws inside the write transaction, aborting the **whole** export — the user gets no `.apkg` at all for larger decks.
- **Action:** Allocate monotonically increasing IDs from separate non-overlapping sequences; never derive from `hashValue` or `+1`.
- **Severity:** High

### 5.4 JSON deck import inserts flashcards without ensuring the `audiobook` row exists (FK abort)
- **Location:** `EchoCore/Services/DeckImportService.swift:60-85`
- **What:** Flashcards are inserted with `audiobookID: deck.targetMediaID` (untrusted JSON) but no `audiobook` row is created first (verified); `flashcard.audiobook_id` is `NOT NULL REFERENCES audiobook(id)`.
- **Why:** If `targetMediaID` names a not-yet-imported book, the first insert throws and the entire import fails. `ApkgImportService` correctly does `INSERT OR IGNORE INTO audiobook`; this path does not.
- **Action:** Mirror `ApkgImportService` — `INSERT OR IGNORE` a placeholder audiobook inside the same transaction, or validate and surface a clear error.
- **Severity:** High

### 5.5 `AudioSegmentReader` converter input block never signals end-of-stream
- **Location:** `EchoCore/Services/AudioSegmentReader.swift:93-99`
- **What:** The `AVAudioConverterInputBlock` always returns `.haveData` with the same already-consumed buffer.
- **Why:** For sample-rate conversions `AVAudioConverter` may call the input block repeatedly; re-feeding stale samples yields duplicated/garbled 16 kHz audio to WhisperKit → mis-placed anchors. Output capacity is also computed from one buffer's frames only.
- **Action:** Track whether the buffer was supplied; return `.endOfStream` with a nil buffer on the second call, or use the block-less single-buffer `convert(to:from:)`.
- **Severity:** Medium

### 5.6 End-of-file capture window collapses to time 0
- **Location:** `EchoCore/Services/AutoAlignmentService.swift:460`
- **What:** `clampedTime = max(0, min(time, maxTime - duration))`. When `time` is within `duration` of the end (or `duration > maxTime`), `maxTime - duration < time`, so the capture jumps to the start of the file.
- **Why:** Chapters near the end of a book transcribe from the wrong audio region → wrong anchors for the book's tail.
- **Action:** Clamp the window *end* (`min(time + duration, maxTime)`) and derive start from it; guard `duration <= maxTime`.
- **Severity:** Medium

### 5.7 `recalculateTimeline` falls back to `totalDuration = 1.0`, collapsing the book to ~1 s
- **Location:** `EchoCore/Services/AlignmentService.swift:204-211,253-262`
- **What:** When no `chapterMarker` rows exist yet, `maxEndTime` is nil and `totalDuration = 1.0`; the synthetic last-block anchor is clamped to ~1 s.
- **Why:** During first import (EPUB ingested before chapter markers materialize), every interpolated block collapses into the first second of audio until a later recalc — the whole book briefly reads as "aligned" to 0–1 s.
- **Action:** Fall back to the known audio duration (passed in) rather than `1.0`, or defer the synthetic last anchor until duration is known.
- **Severity:** Medium

### 5.8 Silence detection can spin forever on a zero-frame read
- **Location:** `EchoCore/Services/SilenceDetectionService.swift:39-80`
- **What:** The loop advances `currentFrame += buffer.frameLength`; if `file.read` yields `frameLength == 0` before reaching `totalFrames` (decode hiccup on a damaged track), `currentFrame` never advances and the loop spins. `windowSize` is assumed > 0.
- **Why:** A corrupted M4B stalls the detached task indefinitely, blocking the whole auto-alignment pipeline (which awaits `detectSilences()`).
- **Action:** Break when a read returns 0 frames; guard `windowSize > 0`.
- **Severity:** Medium

### 5.9 `AudioEngine.stop()` removes route/interruption observers but leaves the graph wired
- **Location:** `EchoCore/Services/AudioEngine.swift:359-381`
- **What:** `stop()` sets `audioSessionConfigured = false` and removes all observers, but leaves `engine`/`playerNode` attached; `configureAudioSession()` early-returns on `engine != nil`, so the observers are never re-added on the next `play()`.
- **Why:** After a `stop()`/replace cycle, unplugging headphones or taking a call no longer pauses playback — the book plays aloud on the speaker, the exact failure the route handler exists to prevent.
- **Action:** Re-register observers in `play()`/`replaceCurrentItem` when missing, or only tear them down in `cleanup()`; decouple observer setup from the `engine == nil` guard.
- **Severity:** Medium

### 5.10 V11→SQL migration uses plain `insert` and can wedge forever
- **Location:** `Shared/Database/MigrationService.swift:33-37`
- **What:** Bookmarks migrate via `dao.insert(record)` (not upsert); `isMigrationDone` flips only after the whole transaction succeeds, so any later throw rolls back and re-runs step 1 next launch.
- **Why:** A deterministic-ID collision or partial prior attempt makes `insert` throw, rolling back forever — migration never completes and SQL-backed features stay empty while data is stranded in UserDefaults.
- **Action:** Use `INSERT OR IGNORE`/upsert for the idempotent migration path; isolate per-record failures.
- **Severity:** Medium

### 5.11 DTW back-projection mis-handles non-monotonic WhisperKit word times
- **Location:** `EchoCore/Services/TokenDTW.swift:224-230`
- **What:** Local rate uses `(lastTime - firstTime) / (count - 1)`; chunks are concatenated (`words += …`), so `firstTime > lastTime` is reachable, producing a negative rate clamped to 0.15 and an arbitrary block-start estimate.
- **Why:** Skews anchor placement when word timestamps aren't monotonic across chunk seams.
- **Action:** Clamp the numerator to `max(0, …)` and/or validate/sort audio token times before DTW.
- **Severity:** Low

### 5.12 `AlignmentChunkPlanner` trusts caller-supplied chunk bounds
- **Location:** `EchoCore/Services/AlignmentChunkPlanner.swift:41-47`
- **What:** With the default config it's safe, but an inverted `minChunk >= maxChunk` yields `windowStart > windowEnd` and chunks with `end < start` (negative duration) fed to `AudioSegmentReader`.
- **Why:** Defensive gap; a future config change could emit negative-length captures.
- **Action:** Assert `0 < minChunk < maxChunk` at entry; clamp `cut >= cursor`.
- **Severity:** Low

---

## 6. Security

### 6.1 CloudKit *public*-DB sync overwrites other users' shared anchors
- **Location:** `EchoCore/Services/CloudKitSyncService.swift:70-79`
- **What:** On `.serverRecordChanged`, the code fetches the existing record and overwrites `anchorsPayload` with the local device's anchors. The record name is a deterministic hash of title+author+duration, so **every user of the same book writes the same public record**.
- **Why:** A device with a few anchors clobbers a well-aligned community payload — community data loss, and a vector for a malicious client to wipe shared alignments (the file header itself flags the public-write risk). *Escalates to Critical once public sync has real adoption.*
- **Action:** Merge anchors (union by block ID, prefer human/locked over auto) instead of overwrite, or move writes to `privateCloudDatabase`; at minimum never replace a larger payload with a smaller one.
- **Severity:** High

### 6.2 Downloaded CloudKit anchors aren't validated against local block IDs
- **Location:** `EchoCore/Services/CloudKitSyncService.swift:103-133`, ingested at `EchoCore/Services/EPUBAutoImportScanner.swift:179-183`
- **What:** Downloaded anchors are filtered only on time bounds; `epubBlockID` is upserted verbatim.
- **Why:** Block IDs are device-local (`epub-<audiobookID>-s…-b…`); a community payload's IDs won't match a differently-parsed local EPUB, so anchors point at nonexistent blocks and silently do nothing — sync "succeeds" but achieves nothing. (Same root cause as §5.1.)
- **Action:** Drop anchors whose `epubBlockID` isn't in the local `epub_block` set (and log the count); consider keying shared anchors on stable content offsets.
- **Severity:** Medium

### 6.3 Keychain items lack `ThisDeviceOnly` and `set` is non-atomic
- **Location:** `Shared/KeychainStore.swift:21-36`
- **What:** Items use `kSecAttrAccessibleAfterFirstUnlock` (no `ThisDeviceOnly`), so device-specific security-scoped bookmark blobs are eligible for iCloud Keychain/backups; `SecItemDelete` then `SecItemAdd` is non-atomic.
- **Why:** Restoring a backup can resurrect stale, meaningless bookmarks on another device; a failed `SecItemAdd` after a successful delete silently loses folder access (user must re-grant).
- **Action:** Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for non-portable data; prefer `SecItemUpdate` with add-fallback and check the status pair.
- **Severity:** Medium

### 6.4 DEBUG paywall-bypass lives in dead code (resurrection risk)
- **Location:** `EchoCore/Views/Components/TranscriptOverlayView.swift:~19-25`
- **What:** A `#if DEBUG return true #else hasUnlockedPro` gate sits in a view with **zero references** (confirmed dead, §12).
- **Why:** Harmless only because the view never renders; easy to accidentally resurrect with the gate disabled.
- **Action:** Delete the file (§2.2). If the iOS transcript overlay is wanted, rebuild it with the gate evaluated correctly.
- **Severity:** Low

---

## 7. Performance

### 7.1 Full-timeline recalculation runs once per chapter during auto-alignment
- **Location:** `EchoCore/Services/AutoAlignmentService.swift:429` → `EchoCore/Services/AlignmentService.swift:135-142,175-358`
- **What:** `runDTWPipeline` calls `insertAnchors` per chapter; `insertAnchors` calls `recalculateTimeline()`, which reloads all blocks + anchors and rewrites every `timeline_item` row in a fresh transaction.
- **Why:** For a 20–40 chapter book this re-reads/rewrites the whole timeline dozens of times per run — quadratic DB work that bloats alignment time and hammers the writer (plus per-candidate `anchorDAO.delete` as separate transactions).
- **Action:** Accumulate all chapter anchors, insert in one batched transaction, and call `recalculateTimeline()` exactly once after the loop.
- **Severity:** Medium

### 7.2 `model.hasPDF` does synchronous directory I/O when read in `body`
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:355-364`, read at `EchoCore/Views/RootTabView.swift:56`
- **What:** `hasPDF` calls `FileManager.contentsOfDirectory(atPath:)` every access and is read during `RootTabView` body evaluation. (`PlaylistView` already caches this into `@State` to dodge it; `RootTabView` does not.)
- **Why:** Disk enumeration on the main thread on every invalidation that re-reads the property.
- **Action:** Cache PDF presence in observable state at load time (like `hasEPUB`), and read the cached flag in `body`.
- **Severity:** Medium

### 7.3 Dashboard progress module re-renders on every playback tick
- **Location:** `EchoCore/Views/ListeningProgressModuleView.swift:7-9,18` (inside `DashboardShelf`)
- **What:** `progressFraction` reads `model.currentPlaybackTime` (updated several times/sec) directly in `body`.
- **Why:** Every tick invalidates this module and forces a diff of the surrounding shelf, though the displayed integer percentage changes ≤1 Hz.
- **Action:** Derive a coarse `Int(percent)` in the `@Observable` model so the view observes a ~1 Hz value; mark the module `Equatable`.
- **Severity:** Medium

### 7.4 UIKit cells synchronously decode full-size images during scroll
- **Location:** `EchoCore/Views/Cells/ImageAssetCell.swift:117-135`, `EchoCore/Views/Cells/ImageCardCell.swift:47-69`
- **What:** Both `configure(...)` paths call `UIImage(contentsOfFile:)` synchronously inside cell configuration (from `cellForItemAt`), decoding EPUB images on the main thread while scrolling.
- **Why:** Dropped frames in the reader feed for image-heavy books.
- **Action:** Decode off-main with a downsampled `CGImageSource` thumbnail, cache by path, assign on main, cancel on `prepareForReuse`; share one decoder/cache between the two cells.
- **Severity:** Medium

### 7.5 macOS reader tracks the active block via a 0.5 s SQL polling loop
- **Location:** `Echo macOS/Views/MacReaderFeedView.swift:108-137`
- **What:** A `while !Task.isCancelled { … sleep(0.5s) }` loop issues a `epub_block⋈timeline_item` JOIN twice/sec to find the active block.
- **Why:** Continuous DB round-trips + view invalidation even when nothing changed (the macOS analogue of the phone's push-driven model).
- **Action:** Drive block tracking from playback position with an in-memory O(log N) bisect over cached block ranges; query only on boundary crossings.
- **Severity:** Medium

### 7.6 `.apkg` `exportAll` issues one DB read per deck (N+1) with synchronous media copy
- **Location:** `EchoCore/Services/ApkgExportService.swift:73-86,266-291`
- **What:** `exportAll` loops decks, each a separate `db.read`; media copy does synchronous `FileManager` existence + copy on the calling thread.
- **Why:** Many decks → many round-trips; large media sets block the calling thread (UI stall if on the main actor).
- **Action:** Fetch all cards in one grouped query; move media copy off-main.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 Index-as-identity in mutable `ForEach` slots
- **Location:** `EchoCore/Views/Components/PlayerControlBar.swift:48`
- **What:** `ForEach(Array(…enumerated()), id: \.offset)` for mini-player slots keys rows by index; reassigning a slot reuses the old row's state.
- **Why:** Defeats SwiftUI identity diffing — changing slot 1 from "+30" to "speed" animates/diffs incorrectly.
- **Action:** Use a stable id (the `WatchAction` value or a composite).
- **Severity:** Low

### 8.2 `MacBlockCardView` leaf not `Equatable` in the polled reader feed
- **Location:** `Echo macOS/Views/MacReaderFeedView.swift` (cell ~line 142)
- **What:** Block cards re-evaluate on every `currentBlockID` change (twice/sec from §7.5) with no equatability gate.
- **Why:** Whole-list body re-evaluation though only two rows actually change.
- **Action:** Make `MacBlockCardView` `Equatable` on `(block.id, isActive)`.
- **Severity:** Low

### 8.3 Hardcoded RGB color ignores dark mode
- **Location:** `EchoCore/Views/Fidget/KineticSandView.swift:117`
- **What:** `Color(red: 0.76, green: 0.70, blue: 0.50)` literal with no light/dark variant (the only non-Metal hardcoded color found).
- **Why:** Renders identically in light and dark.
- **Action:** Move to an asset-catalog color with variants.
- **Severity:** Low

### 8.4 Custom scrubbers lack VoiceOver adjustable semantics
- **Location:** `EchoCore/Views/ManualAlignmentSheet.swift:50-53` (`ScrubberJoystick`), `EchoCore/Views/SettingsView.swift:397` (lookback `Slider`)
- **What:** The custom `ScrubberJoystick` exposes no `.accessibilityValue`/`.accessibilityAdjustableAction`.
- **Why:** Precision continuous controls are unusable to VoiceOver without adjustable semantics.
- **Action:** Add `.accessibilityElement()`, `.accessibilityValue(formattedTime)`, `.accessibilityAdjustableAction`.
- **Severity:** Low

### 8.5 (Demoted) "Perf bugs" in `TranscriptOverlayView` are in dead code
- **Location:** `EchoCore/Views/Components/TranscriptOverlayView.swift:141-148,183-190` (O(N²) active-segment scan), `:27-32` (`filteredSegments` re-filter), `TranscriptRowView.swift` (missing `Equatable`)
- **What:** Real inefficiencies, but the view has **zero references** (§12) and never renders.
- **Why:** Recorded so the analysis isn't lost — but the correct action is deletion, not optimization.
- **Action:** Delete (§2.2). _If_ revived, fix the O(N²) scan (precompute `activeSegmentID`), cache `filteredSegments`, and make the row `Equatable`.
- **Severity:** Low (deletion candidate)

---

## 9. Dead code / duplication / refactor

### 9.1 Orphaned "Timeline Feed prototype" + planner cluster (~1,500 LOC)
- **Location:** `EchoCore/ViewModels/TimelineFeedViewModel.swift`, `EchoCore/Views/TimelineFeedCollectionView.swift`, `TimelineContentView.swift`, `PlaylistTimelineView.swift`, `TimelineContentCard.swift`, `TimelineHeaderView.swift`, `ContentCardEditor.swift`, `EchoCore/Services/TimelineService.swift`, `PlaybackTimelineService.swift`, `EchoCore/Models/TimelineDisplayItem.swift` (+ reachable-only-from-here: `ContentCard`, `TimelineGroup`, `TimelineScope`, `ChapterSection`)
- **What:** `RootTabView.timeline → TimelineTab → PlaylistView` (verified); the above are referenced only by tests or not at all. The Reader feed replaced this prototype.
- **Why:** ~1,500+ LOC of UIKit collection-view, VM, and SwiftUI surface compile/ship but are unreachable, and the tests give false coverage signal.
- **Action:** Delete the dead views first, then cascade-remove the now-unreferenced services/models and their tests. Confirm `RealTimeEventDAO`/`RealTimeEventRecord` aren't needed elsewhere before removing.
- **Severity:** High

### 9.2 Dead `PlayerModel.timelineService` property
- **Location:** `EchoCore/ViewModels/PlayerModel.swift:520`
- **What:** `var timelineService: TimelineService?` is never assigned or read.
- **Action:** Remove with the §9.1 cluster.
- **Severity:** Low

### 9.3 Orphaned `TranscriptOverlayView` + `TranscriptDisplayMode`
- **Location:** `EchoCore/Views/Components/TranscriptOverlayView.swift:1-191`
- **What:** Generic view + enum with zero references (macOS has its own `TranscriptPane`).
- **Action:** Delete (see §2.2, §6.4).
- **Severity:** Medium

### 9.4 Time-formatting reimplemented ~15× across two incompatible families
- **Location:** Shared `Shared/TimeFormatting.swift:5` (`formatHMS`) + `Shared/TextAlignmentUtilities.swift:44` (`formatTimeHMS`, a byte-identical duplicate); private copies in `EchoCore/Services/NowPlayingController.swift:168`, `EchoCore/Views/ChapterPickerSheet.swift:45`, `EchoCore/Views/Cells/TextSegmentCell.swift:150`, `AnkiCardCell.swift:141`, `BookmarkCell.swift:141`, `ChapterMarkerCell.swift:154`, `ImageAssetCell.swift:164` (+ `PlayerModel+MarkedPassages.swift:45`, `CardInboxView.swift:157`, `StudyNotesExportService.swift:128`)
- **What:** Two shared formatters already exist, yet ~10 private copies reimplement HMS; one variant uses non-padded `%d:%02d`, so the same duration renders as `1:05` vs `01:05` in different surfaces.
- **Why:** Visibly inconsistent timestamps + every copy must be re-audited for the NaN guard only `formatHMS` has.
- **Action:** Keep one canonical `formatHMS` in `Shared/`, delete `formatTimeHMS`, route all copies through it; decide padding once.
- **Severity:** Medium

### 9.5 Tokenizer / Jaccard / normalize reimplemented 3–4× across matchers
- **Location:** Shared `Shared/TextAlignmentUtilities.swift:17,32`; reimplemented in `EchoCore/Services/ChapterTitleMatcher.swift:147,188,198` and `EchoCore/Services/AutoAlignmentTextMatcher.swift:135-162` (Mac matcher correctly delegates — proof the shared API suffices)
- **What:** Three subtly-divergent definitions of "token" and "overlap score" power the alignment pipeline.
- **Why:** A tuning fix in one matcher silently won't apply to the others.
- **Action:** Route `ChapterTitleMatcher`/`AutoAlignmentTextMatcher` through the shared helpers; keep only the genuinely-different number-token logic.
- **Severity:** Medium

### 9.6 ~25 raw security-scoped-resource sites bypass `SecurityScopeManager`
- **Location:** e.g. `EchoCore/ViewModels/PlayerModel+Bookmarks.swift:123,125,147,149`, `EchoCore/Views/Bookmarks.swift:370,698`, `EchoCore/Services/EPUBImportCoordinator.swift:21,24,32`, `PDFImportCoordinator.swift:16,19,27`, `EPUBAutoImportScanner.swift:42,277`, `Persistence.swift:292,303`, `ArtworkCache.swift:70,91` (~25 total incl. 6 Mac sites)
- **What:** A `SecurityScopeManager` wrapper exists, yet most sites hand-roll `startAccessingSecurityScopedResource()` + `defer`.
- **Why:** ~25 copies of balance-sensitive boilerplate; each a chance to leak the resource by forgetting `stop`.
- **Action:** Provide a closure-based `withSecurityScopedAccess(_:) { … }` and migrate the raw sites.
- **Severity:** Medium

### 9.7 Oversized functions concentrated in the alignment pipeline
- **Location:** `EchoCore/Services/AlignmentService.swift:175` `recalculateTimeline()` (~189 lines), `EchoCore/Services/AutoAlignmentService.swift:260` `runDTWPipeline()` (~177), `EchoCore/Services/TimelineIngestionFactory.swift:159` `ingest()` (~135), `Shared/EPUBXMLParsing.swift:410` `parser(...)` (~89)
- **What:** Four functions exceed 130 lines in core, hard-to-test logic.
- **Why:** A missed branch in `recalculateTimeline`/`runDTWPipeline` is a silent mis-alignment.
- **Action:** Extract cohesive phases (anchor-collection / interpolation / persistence; chunk-build / transcribe / DTW-match / anchor-write) into unit-testable private helpers.
- **Severity:** Medium

### 9.8 `AlignmentAnchorExport` wire-format struct defined twice in two targets
- **Location:** `EchoCore/Services/EPUBAutoImportScanner.swift:385` (private) and `Echo macOS/Services/MacGlobalAlignmentService.swift:6` (public)
- **What:** Both declare `{ blockId, timestamp, confidence }` and must stay byte-compatible, with no shared source of truth.
- **Why:** A field rename on either side breaks the sidecar handoff with no compile error (separate modules).
- **Action:** Move one `public Codable` definition into `Shared/`; import from both.
- **Severity:** Medium

### 9.9 Smaller duplications (consolidate into shared utilities)
- **Location:** `Color(hex:)` reimplemented ×3 (`Echo macOS/Views/MacContentView.swift:241`, `MacReaderFeedView.swift:241`, `Echo Watch App/Services/WatchViewModel.swift:958`); `formatDuration` "Nh MMm" ×5 (`PlaylistView.swift:61`, `StatsModuleView.swift:54`, `Cells/BookCardCell.swift:99`, `TimelineIngestionFactory.swift:391`, + dead `TimelineContentCard.swift:127`); `speedLabel` switch ×2 (`BottomToolbarView.swift:104`, `TransportControlsView.swift:270`); speed-preset list + watch/phone slot defaults hardcoded instead of reading `SettingsManager.Defaults` (`WatchViewModel.swift:86-107`, `PhonePlayerSettingsView.swift:285`); `CGImageSource` downsample block ×3 (`ArtworkCache.swift:20`, `Echo Widget/Views/Echo_Widget.swift:18`, `Bookmarks.swift:721`)
- **What:** Each is a small copy-pasted helper with drift risk (the `Color(hex:)` copies already sanitize differently; `formatDuration` copies round/pad differently).
- **Why:** Logic and magic-number policy scattered across targets.
- **Action:** Add `Color(hex:)`, `formatDurationCompact`, `speedLabel`, and a shared downsampler to `Shared/`; reference `SettingsManager.Defaults` for the preset/slot defaults.
- **Severity:** Low

### 9.10 `ARCHITECTURE.md` is stale: phantom files + dead cluster presented as live
- **Location:** `ARCHITECTURE.md` (lists nonexistent `AudioRingBuffer.swift`, `SilenceAnalyzer.swift`, `PlaybackStateDAO.swift`, `SettingsDAO.swift`; presents §9.1 files as current)
- **What:** The "auto-generated" doc is out of sync with the filesystem.
- **Action:** Run `make architecture` after the §9.1 deletion (see §2.4 and §10.5).
- **Severity:** Low

---

## 10. Cross-cutting recommendations

### 10.1 The protocol-oriented / DI design is aspirational — make it real or remove it
- **Location:** `Shared/MediaPlayable.swift`, `EchoCore/Protocols/*`, `EchoCore/ViewModels/PlayerModel.swift:522`, `EchoTests/Mocks/*`, `EchoTests/PlayerModelTests.swift:17-81`
- **What:** Six protocols + five mocks exist; **none** is an injection seam (verified: protocols appear only in their own conformance declarations). `PlayerModel` hard-constructs every service in a zero-arg `init()`. `MediaPlayable` (the `CLAUDE.md` flagship) has one conformer, zero polymorphic uses; `Chapter`/`Bookmark` don't conform. The five mocks are orphaned — `PlayerModelTests` instantiates them only to assert on themselves, never injecting them into a `PlayerModel`.
- **Why:** The "high testability via DI + mocks" goal is unrealized; the mocks give false confidence. Notably, the one well-injected dependency (`DatabaseService`, via constructor/closure + `inMemory:` in tests) proves the team already knows the right pattern — and it's **concrete-type + closure injection, not protocols**.
- **Action:** Pick one: (a) add a `PlayerModel.Dependencies` init so the existing mocks become real seams, or (b) delete the unused protocols/mocks and standardize on the `DatabaseService` closure-injection pattern. Either way, update `CLAUDE.md` (§10.5).
- **Severity:** High

### 10.2 Give `PlaybackState` a single writer per field
- **Location:** `EchoCore/State/PlaybackState.swift` (mutated by 9 types: `PlaybackController` ×17, `PlayerLoadingCoordinator` ×14, `BookmarkArtworkCoordinator` ×12, …)
- **What:** The shared `@Observable` is handed to every coordinator, each writing freely; correct only by convention (all `@MainActor`).
- **Why:** No source of truth — a new writer will collide with an existing one (e.g. artwork vs progress vs chapters).
- **Action:** Funnel mutation of each field through its designated owner (artwork→`BookmarkArtworkCoordinator`, progress→`PlaybackProgressPresenter`, chapters→`ChapterLoadingCoordinator`); expose read-only views elsewhere.
- **Severity:** Medium

### 10.3 Move the View/data boundary back into view models
- **Location:** `EchoCore/Views/ReaderTab.swift:334-378` + `ReaderTab+Alignment.swift:12-156`, `EchoCore/Views/CardInboxView.swift:77-155`, `Echo macOS/Views/MacReaderFeedView.swift:83-137`, `Echo macOS/Views/MacTOCTreeView.swift:103-169`, `EchoCore/Views/PlaylistView.swift:801-857`, `EchoCore/Views/Bookmarks.swift:681-735`
- **What:** Multiple SwiftUI views construct DAOs, run raw SQL, own alignment `Task`s, and do file IO/image resize — business logic in the View layer.
- **Why:** Breaks MVVM; the data layer can't be tested without a view, and the same logic gets re-implemented per platform (`MacReaderFeedView`/`MacTOCTreeView` have no VM at all).
- **Action:** Add thin VM methods (`vm.alignBlock`, `vm.audioStartTime(forBlock:)`, `vm.setCardColor`, a `CardInboxViewModel`, a `MacReaderFeedViewModel`) and have views call them; views should never touch `timeline_item`/`alignment_anchor` SQL.
- **Severity:** Medium

### 10.4 Unify the macOS surface with shared logic
- **Location:** `Echo macOS/Views/MacPlayerModel.swift` (+ `MacBookmark`), `Echo macOS/Services/MacEPUBParser.swift`, `MacGlobalAlignmentService.swift`
- **What:** macOS re-implements playback, a siloed `MacBookmark` (`mac.bookmarks.v1`, invisible to iOS/watch), EPUB parsing, and a **stale, inferior** alignment algorithm (uniform `duration/word.count` + Jaccard) that iOS replaced with real word-timestamps + gated DTW.
- **Why:** Mac bookmarks don't round-trip; Mac alignment is both worse *and* broken at handoff (§5.1); every shared fix must be ported by hand.
- **Action:** Make `PlaybackController`/`BookmarkStore` compile for macOS and have `MacPlayerModel` become a thin AppKit shell; extract the DTW pipeline core into a shared service both platforms call; unify `MacBookmark` with `Bookmark`.
- **Severity:** Medium

### 10.5 Bring living docs back in sync (CLAUDE.md rule)
- **Location:** `CLAUDE.md` (protocol-oriented claim vs §10.1), `ARCHITECTURE.md` (§9.10)
- **What:** Two docs now provably contradict the code.
- **Why:** The project's own documentation-sync rule requires updating them when architecture diverges.
- **Action:** Correct the `CLAUDE.md` protocol-oriented description to match reality (or fix the code to match the doc); regenerate `ARCHITECTURE.md`.
- **Severity:** Low

### 10.6 Introduce a shared, type-safe watch↔phone state contract
- **Location:** `EchoCore/Services/WatchStateContextBuilder.swift:124` ↔ `Echo Watch App/Services/WatchViewModel.swift:359-557`
- **What:** State crosses as a hand-keyed `[String: Any]` dictionary with no shared key enum; the builder emits fields the watch never reads, and defaults are hand-copied from `SettingsManager.Defaults`.
- **Why:** Fields drift silently — a typo or one-sided key just never syncs.
- **Action:** Add a shared `enum WatchContextKey: String` (and ideally a `Codable WatchPlaybackState`) in `Shared/`, used by both ends.
- **Severity:** Medium

---

## 11. What was NOT audited

- **Full macOS / watchOS / Widget build warnings.** Only the iOS `Echo` test build's warnings were captured (machine-constraint: one `xcodebuild` at a time on 16 GB). macOS/Watch concurrency was reviewed by reading, not by a per-scheme build.
- **Metal kernel algorithm correctness.** `VisualizerShaders.metal` and the FFT/visualizer math were reviewed only for concurrency of the render loop, not numerical correctness.
- **Third-party dependency internals.** GRDB, WhisperKit, ZIPFoundation, swift-transformers, swift-crypto are treated as black boxes.
- **Test-coverage depth.** Test targets got a light scan (enough to spot the orphaned-mock and dead-cluster-test issues); no coverage measurement.
- **Localization wording.** `Localizable.xcstrings` completeness/wording not assessed.
- **Instruments profiling.** Performance findings flag *potential* hot paths by inspection; no `.trace` capture. Use `swiftui-expert-skill` trace tooling for confirmation.
- **Build settings / scheme / signing config.** Beyond what shared schemes reveal.
- **FSRS/SRS scheduling math correctness.** Spot-checked only; session-2 rewrote it.

---

## 12. Verification

Every High was confirmed by opening the cited lines this session.

- **§3.1** — build log: `PlaybackSessionRecorder.swift:15,20,26,111`, `InlineFlashcardTriggerController.swift:57,133`, `PlayerModel.swift:848,857,869`, `ApkgImportService.swift:81,94`, `AudioEngine.swift:283`, `DefaultVisualizerTap.swift:35` all emit main-actor / non-Sendable warnings (several "error in the Swift 6 language mode").
- **§3.2** — `WatchSyncManager.swift:12` is `final class … WCSessionDelegate` (not `@MainActor`); `:40` declares mutable `lastSyncedArtworkKey`.
- **§3.3** — `PlayerModel.swift:893-911` deinit body read in full: no `continuousAlignmentService.stop()`; `SleepTimerManager.swift:18-20` and `TimelineService.swift:49-50` invalidate a `Timer` with no `assumeIsolated`.
- **§3.4** — spot-checked the closure assignments at `PlayerModel.swift:529-837`: `[weak self]` present; `delegate`/`playerModel` are `weak`. Clean (negative result).
- **§5.1** — `MacEPUBParser.swift:98` = `"epub-mac-s\(spineIdx)-b\(blockCount)"` vs `EPUBImportService.swift:196` = `"epub-\(audiobookID)-s\(i)-b\(blockIdx)"`; ingestion at `EPUBAutoImportScanner.swift:143-159`. Formats cannot match.
- **§5.2** — `AutoAlignmentService.swift:486` early-returns on `whisperKit != nil`; `:512` `release()` with no `whisperKit = nil`. Stale-reference confirmed.
- **§5.3** — `ApkgExportService.swift:231` `noteID = Int64(now*1000) + hashValue%1000`; `:246` `cardID = noteID + 1`. Collision + PK abort confirmed.
- **§5.4** — `DeckImportService.swift:60-85` inserts `Flashcard(audiobookID: deck.targetMediaID, …)` with no preceding `audiobook` insert.
- **§6.1** — `CloudKitSyncService.swift:70-79` fetch-then-overwrite of `anchorsPayload` against a title+author+duration-hashed public record.
- **§9.1 / dead-code demotions** — production-reference grep: `TimelineFeedCollectionView`/`TimelineFeedViewModel` → no production refs; `TranscriptOverlayView`/`TranscriptRowView` → **no refs at all**; `ContentCardEditor` → no refs. `RootTabView.swift:69-70` routes `.timeline → TimelineTab`; `TimelineTab.swift:11` hosts `PlaylistView`. This is why §8.5 was demoted from High to a deletion candidate.

---

_Generated by the `ios-code-audit` skill, architecture-first. ~65 findings. Prior snapshot preserved at `docs/CODE_AUDIT_2026-06-13_session2.md`._
