# CODE_AUDIT.md Remediation Plan (Wave-2 + Architecture)

**Generated:** 2026-06-13 (session 3)
**Source:** `CODE_AUDIT.md` (65 findings, architecture-first)
**Branch:** `claude/thirsty-mendel-c19a03`
**Prior plan:** archived at `docs/CODE_AUDIT_REMEDIATION_PLAN_2026-06-09.md`

Findings are grouped into phases by risk/effort/dependency. Each item lists the `CODE_AUDIT.md` §-ref, exact `file:line`, the change, and a Conventional Commit message. **Build-verify every phase** with `make build-tests` (then `make test`) — capped jobs only, never two `xcodebuild`s at once on the 16 GB machine.

> **Scope note:** Phase 0's dead-code deletion removed several files the audit cited as "live." Findings now **moot/reduced**: §7.4 (`ImageAssetCell` deleted → only `ImageCardCell` remains), §9.4 (the cell `formatHMS` copies in `TextSegmentCell`/`AnkiCardCell`/`BookmarkCell`/`ChapterMarkerCell`/`ImageAssetCell` are gone), §9.9 (`BookCardCell`/`TimelineContentCard` `formatDuration` copies gone). Adjusted counts below.

---

## Phase 0 — DONE this session ✅

- **§9.1 / §9.2 / §9.3 / §2.2 — dead Timeline-Feed cluster deleted.** 30 files removed (the prototype views/VM/services/models + 10 orphaned `Views/Cells/*` the dead collection view owned + `TranscriptOverlayView`/`TranscriptRowView`), `PlayerModel.timelineService` + the `PlaybackTimelineItem` protocol removed, two test files trimmed of dead-VM tests. **Net −3,868 LOC.** Live `RealTimeEventType` rescued into `EchoCore/Models/RealTimeEventType.swift` (it was co-located with the dead `RealTimeEvent` struct). `** TEST BUILD SUCCEEDED **`.
- **§2.4 / §9.10 — `ARCHITECTURE.md` regenerated** via `make architecture` (reflects the deletion; phantom files gone).
- **§10.5 — `CLAUDE.md` protocol-oriented claim corrected** to mark it aspirational and point at the `DatabaseService` injection pattern.
- **Audit committed** (`4cea8db`); session-2 audit + plan archived under `docs/`.

---

## Phase 1 — Verified Highs (user-facing bugs + compiler regressions) 🔴

> These are the bugs a user/contributor hits. Each was confirmed at file:line in §12.

### 1.1 — §3.1 Swift-6 main-actor isolation regressions
- **Files:** `PlaybackSessionRecorder.swift:15,20,26,111`; `InlineFlashcardTriggerController.swift:57,133`; `PlayerModel.swift:848,857,869` (CarPlay handlers); `ApkgImportService.swift:81,94`; `CoverThemeBuilder.swift:194`; `DefaultVisualizerTap.swift:35`; `AudioEngine.swift:283`
- **Change:** Annotate the delegate/recorder types `@MainActor`; hop framework-callback bodies onto the main actor (the session-2 Widget-intent pattern); capture a Sendable token, not the `Timer`, in `AudioEngine:283`.
- **Commit:** `fix(concurrency): resolve Swift-6 main-actor isolation regressions in Wave-2 code`

### 1.2 — §5.2 WhisperKit stale-model reference
- **File:** `AutoAlignmentService.swift:486,503,512`
- **Change:** Set `whisperKit = nil` in the unload/`release()` path; acquire once per run, release once at completion (not per chunk).
- **Commit:** `fix(alignment): nil the WhisperKit reference on model unload so re-alignment reloads`

### 1.3 — §5.3 `.apkg` export PRIMARY KEY collision
- **File:** `ApkgExportService.swift:231,246`
- **Change:** Allocate monotonic `notes.id`/`cards.id` from separate non-overlapping sequences; drop `hashValue`/`+1` derivation.
- **Commit:** `fix(apkg): allocate non-colliding note/card IDs on export`

### 1.4 — §5.4 Deck-import FK abort
- **File:** `DeckImportService.swift:60-85`
- **Change:** `INSERT OR IGNORE` a placeholder `audiobook` row for `targetMediaID` in the same transaction before inserting cards (mirror `ApkgImportService`).
- **Commit:** `fix(import): ensure audiobook row exists before inserting JSON-deck flashcards`

### 1.5 — §6.1 CloudKit public-DB clobber
- **File:** `CloudKitSyncService.swift:70-79`
- **Change:** Merge anchors (union by block ID, prefer locked/human) on `.serverRecordChanged`, or move writes to `privateCloudDatabase`; never replace a larger payload with a smaller one.
- **Commit:** `fix(cloudkit): merge instead of overwrite shared anchor payloads`

### 1.6 — §3.2 WatchSyncManager off-main race
- **File:** `WatchSyncManager.swift:12,40`
- **Change:** Mark the type `@MainActor`; funnel all `WCSession` access + `lastSyncedArtworkKey` mutation through the main actor.
- **Commit:** `fix(watch): isolate WatchSyncManager to the main actor`

### 1.7 — §3.3 PlayerModel teardown gaps
- **Files:** `PlayerModel.swift:893-911`, `SleepTimerManager.swift:18-20`, `TimelineService.swift:49-50` *(TimelineService deleted in Phase 0 — apply only to `SleepTimerManager` + any remaining `@MainActor` deinit invalidating a Timer)*
- **Change:** Add `continuousAlignmentService?.stop(); continuousAlignmentService = nil` to `PlayerModel.deinit`; wrap the `SleepTimerManager` timer invalidation in `MainActor.assumeIsolated` (match `AudioEngine`/`PlayerModel`). **Do NOT** convert to `isolated deinit` (§3.9 — the iOS 26.2 runtime bug is in isolated-deinit).
- **Commit:** `fix(playback): stop continuous alignment + isolate timer teardown in deinit`

---

## Phase 2 — Concurrency mediums 🟠

- **2.1 §3.5** `ContinuousAlignmentService.swift:59-116` — `await transcriptionTask?.value` before `release()` in `stop()`. → `fix(alignment): balance WhisperSession refcount on continuous-align stop`
- **2.2 §3.6** `AutoAlignmentService.swift:52,507-515` — add `deinit` invalidating `modelUnloadTimer`; prefer cancellable `Task.sleep`. → `fix(alignment): cancel the model-unload timer on dealloc`
- **2.3 §3.7** `NowPlayingController.swift:7` — mark `@MainActor`. → `refactor(nowplaying): isolate NowPlayingController to the main actor`
- **2.4 §3.8** `LocationCaptureService.swift:38-80,108-123` — build/drive CoreLocation via a `@MainActor` helper; `cancelGeocode()` on timeout. → `fix(location): drive CoreLocation clients on the main actor`
- **2.5 §3.10** `StandaloneTranscriptionService.swift:59-77` — thread `Task.checkCancellation()` into `transcribeChapter`. → `fix(transcription): honor cancellation mid-chapter`
- **2.6 §3.11** `ContinuousAlignmentService.swift:59-64`, `WatchViewModel.swift:175-186,848-924` — replace `Timer`+`assumeIsolated` with cancellable `Task.sleep` loops. → `refactor(timers): replace assumeIsolated Timers with structured async loops`
- **2.7 §3.12** `CarPlaySceneDelegate.swift:3-23` — annotate `@MainActor`. → `refactor(carplay): make CarPlaySceneDelegate main-actor explicit`

---

## Phase 3 — Bug / logic mediums 🟠

- **3.1 §5.5** `AudioSegmentReader.swift:93-99` — signal `.endOfStream` on the converter's 2nd input-block call. → `fix(alignment): correct AVAudioConverter input-block EOS handling`
- **3.2 §5.6** `AutoAlignmentService.swift:460` — clamp the window *end*, guard `duration <= maxTime`. → `fix(alignment): keep end-of-file capture windows in range`
- **3.3 §5.7** `AlignmentService.swift:204-211,253-262` — fall back to known audio duration, not `1.0`. → `fix(alignment): use real duration for synthetic end anchor`
- **3.4 §5.8** `SilenceDetectionService.swift:39-80` — break on a 0-frame read; guard `windowSize > 0`. → `fix(alignment): prevent silence-detection spin on damaged audio`
- **3.5 §5.9** `AudioEngine.swift:359-381` — re-register route/interruption observers in `play()` when missing. → `fix(audio): re-arm route/interruption observers after stop()`
- **3.6 §5.10** `MigrationService.swift:33-37` — `INSERT OR IGNORE`/upsert the migration path. → `fix(db): make the V11 UserDefaults→SQL migration idempotent`
- **3.7 §5.11** `TokenDTW.swift:224-230` — clamp `max(0, lastTime-firstTime)`; validate token-time monotonicity. → `fix(dtw): guard against non-monotonic WhisperKit word times`
- **3.8 §5.12** `AlignmentChunkPlanner.swift:41-47` — assert `0 < minChunk < maxChunk`. → `fix(alignment): guard chunk-planner bounds`
- **3.9 §4.2** `CarPlaySceneDelegate.swift:17` — fix the `didDisconnect` near-match to the real `CPTemplateApplicationSceneDelegate` requirement. → `fix(carplay): correct disconnect delegate signature`

---

## Phase 4 — Security mediums 🟠

- **4.1 §6.2** `CloudKitSyncService.swift:103-133` + `EPUBAutoImportScanner.swift:179-183` — drop downloaded anchors whose `epubBlockID` isn't in the local `epub_block` set; log the count. → `fix(cloudkit): validate downloaded anchor block IDs against local blocks`
- **4.2 §6.3** `KeychainStore.swift:21-36` — use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; `SecItemUpdate` with add-fallback. → `fix(keychain): device-only accessibility + atomic set`

---

## Phase 5 — Performance 🟡

- **5.1 §7.1** `AutoAlignmentService.swift:429` → `AlignmentService.swift:135-142` — batch all anchors, call `recalculateTimeline()` once after the loop. → `perf(alignment): single timeline recalc per run, not per chapter`
- **5.2 §7.2** `PlayerModel.swift:355-364`, read at `RootTabView.swift:56` — cache PDF presence in observable state. → `perf(player): cache hasPDF instead of directory I/O in body`
- **5.3 §7.3** `ListeningProgressModuleView.swift:7-9,18` — derive a ~1 Hz `Int(percent)` in the model; make module `Equatable`. → `perf(dashboard): coarse progress observation`
- **5.4 §7.4** `ImageCardCell.swift:47-69` *(ImageAssetCell deleted in Phase 0)* — off-main downsampled decode + cache. → `perf(reader): async-decode reader image cells`
- **5.5 §7.5** `MacReaderFeedView.swift:108-137` — event-driven block tracking + O(log N) bisect, not 0.5 s SQL polling. → `perf(macos): replace reader poll loop with position-driven tracking`
- **5.6 §7.6** `ApkgExportService.swift:73-86,266-291` — one grouped query; off-main media copy. → `perf(apkg): batch deck export query + async media copy`

---

## Phase 6 — SwiftUI / UI / accessibility 🟡

- **6.1 §8.1** `PlayerControlBar.swift:48` — stable `ForEach` id, not `\.offset`. → `fix(ui): stable identity for mini-player slots`
- **6.2 §8.2** `MacReaderFeedView.swift` (`MacBlockCardView`) — `Equatable` on `(block.id, isActive)`. → `perf(macos): equatable reader block cells`
- **6.3 §8.3** `KineticSandView.swift:117` — asset-catalog color with dark variant. → `fix(ui): dark-mode-aware sand color`
- **6.4 §8.4** `ManualAlignmentSheet.swift:50-53`, `SettingsView.swift:397` — `.accessibilityValue`/`.accessibilityAdjustableAction` on custom scrubbers. → `a11y: adjustable semantics for scrubber controls`

---

## Phase 7 — API modernity 🟡

- **7.1 §4.1** `CarPlayManager.swift:37` — `setRootTemplate(_:animated:completion:)`. → `refactor(carplay): use non-deprecated setRootTemplate`
- **7.2 §4.4** `AlignmentTranscript.swift:115`, `StandaloneTranscriptionService.swift:134`, `MacGlobalAlignmentService.swift:207` — throwing single-array WhisperKit API; distinguish failure from silence. → `fix(alignment): surface transcription errors instead of treating them as silence`
- **7.3 §4.3** `LocationCaptureService.swift:32,68` — consider `MKReverseGeocodingRequest`. → `refactor(location): adopt MKReverseGeocodingRequest`
- **7.4 §4.5** `DefaultChimePlayer.swift:67` — async `scheduleFile` variant. → `refactor(audio): async chime scheduling`

---

## Phase 8 — Dead code / duplication (remaining) 🟢

- **8.1 §9.4** Consolidate `formatHMS` — keep one in `Shared/TimeFormatting.swift`, delete `formatTimeHMS`, route remaining copies (`NowPlayingController:168`, `ChapterPickerSheet:45`, `PlayerModel+MarkedPassages:45`, `CardInboxView:157`, `StudyNotesExportService:128`) through it. *(cell copies deleted in Phase 0)* → `refactor(format): single shared HMS formatter`
- **8.2 §9.5** `ChapterTitleMatcher.swift:147,188,198` + `AutoAlignmentTextMatcher.swift:135-162` — route through shared `tokenizeForAlignment`/`jaccardScore`. → `refactor(alignment): share tokenizer + Jaccard across matchers`
- **8.3 §9.6** ~25 raw security-scope sites — add `withSecurityScopedAccess(_:) {}` and migrate. → `refactor(security): closure-based security-scoped access helper`
- **8.4 §9.7** Extract oversized functions (`AlignmentService.recalculateTimeline` ~189, `AutoAlignmentService.runDTWPipeline` ~177) into testable phases. → `refactor(alignment): decompose oversized pipeline functions`
- **8.5 §9.8** Move `AlignmentAnchorExport` into `Shared/`; import from both targets. → `refactor: share AlignmentAnchorExport wire format`
- **8.6 §9.9** Consolidate `Color(hex:)` (×3), `formatDuration` (`PlaylistView:61`, `StatsModuleView:54`, `TimelineIngestionFactory:391`), `speedLabel` (×2), preset/slot default literals → `Shared/` + `SettingsManager.Defaults`. → `refactor: consolidate duplicated UI helpers into Shared`

---

## Phase 9 — Architecture decisions (need your call before coding) 🧭

These aren't mechanical fixes — they need a direction decision first.

- **9.1 §10.1 Protocol/DI direction.** Either (a) add a `PlayerModel.Dependencies` init so the 5 orphaned mocks become real seams, or (b) delete the unused protocols/mocks and standardize on `DatabaseService`-style injection. **Decide before any further "testability" work.**
- **9.2 §10.2** Give `PlaybackState` a single writer per field (artwork→artworkCoordinator, progress→progressPresenter, …).
- **9.3 §10.3** Move View/data logic into VMs (`ReaderTab`, `CardInboxView`, `MacReaderFeedView`/`MacTOCTreeView` need VMs; views shouldn't run `timeline_item`/`alignment_anchor` SQL).
- **9.4 §10.4** Unify macOS with shared logic — make `PlaybackController`/`BookmarkStore` compile for macOS; extract the DTW pipeline core to a shared service; unify `MacBookmark` with `Bookmark`. **(Also fixes §5.1, the broken Mac alignment handoff.)**
- **9.5 §10.6** Shared `enum WatchContextKey: String` (+ `Codable WatchPlaybackState`) for the watch↔phone contract.

---

## Phase 10 — Quick-win warnings 🟢

- **§2.3** `ContentCardEditor.swift:105` *(file deleted in Phase 0 — n/a)*, `DefaultSoundscapeMixer.swift:48` (unused `engine`), `SnippetPlayer.swift:87` (`self` written never read), `AlignmentService.swift:406` (unused `write` result), `PlayerModel+MarkedPassages.swift:25` (unused `insert` result), `:40` (optional interpolation). → `chore: clear trivial compiler warnings`
- **§2.5** `RootTabView.swift:146-151`/`167-169` — merge duplicate `.onAppear`. → `refactor(ui): single onAppear on RootTabView`

---

_Plan tracks `CODE_AUDIT.md` §-numbers 1:1. Re-run `make build-tests` after each phase; never two `xcodebuild`s concurrently (16 GB machine)._
