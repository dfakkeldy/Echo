# Orbit Audiobooks — Roadmap

<!-- Last updated: 2026-05-29 (Phase 1 & 2 complete!) -->
<!-- Based on thorough code review of 169 findings across 6 code areas -->

---

## Phase 1: Stability & Correctness Fixes

Goal: eliminate crashes, data races, silent failures, and memory leaks before adding features.
### 1.1 — Concurrency Safety (data race prevention)

- [x] **Add `@MainActor` to `@Observable` classes** — `BookmarkArtworkCoordinator`, `BookmarkStore`, `PlaybackProgressPresenter`, `PlaybackTimelineService`, `TimelineService` all mutate observable state without main-actor isolation. Observed: data races when properties are read from Task continuations or timer callbacks.
- [x] **Add `Sendable` conformance to all model types** — 29 files across Models/ and Shared/ lack explicit `Sendable`. Under Swift 6 strict concurrency, these types cannot safely cross actor boundaries. Every struct (Note, Chapter, Track, TimelineItem, ContentCard, etc.) and protocol needs it.
- [x] **Add `@MainActor` to UI-facing protocols** — `BookmarkStoreProtocol`, `PlaybackControllerProtocol`, `SleepTimerManagerProtocol`, `SettingsManagerProtocol`, `StoreManagerProtocol` all expose UI-bound state without isolation guarantees.
- [x] **Fix `MainActor.assumeIsolated` in migration closures** (`DatabaseService.swift:73-96`) — GRDB runs migrations on internal writer queues (not main actor). If `DatabaseService.init()` is ever called off the main thread, this crashes. Replace with synchronous `try db.write` inside the migration block without the assumeIsolated wrapper.
- [x] **Audit all `DispatchQueue.main.async` inside `@MainActor` classes** — `PlaybackController` has 13+ redundant main-queue dispatches since the class is already `@MainActor`. These mask the actor guarantee and add unnecessary overhead.

### 1.2 — Crash Elimination

- [x] **Replace `fatalError` in `EPUBAssetStorage.rootDirectory`** (line 23) — crashes the app if Application Support is unavailable. Return an optional or throw.
- [x] **Replace force-downcasts in `TimelineFeedCollectionView`** (lines 276, 324) — `as! ElasticScrubberCell` and `as! StickyReviewHeaderView` will hard-crash if cell registration falls out of sync with the data source. Use `guard let` with a fallback cell + log.
- [x] **Fix `TranscriptStore` missing `deinit`** (macOS) — `NotificationCenter.addObserver` in `init()` with no `removeObserver` in `deinit`. Dangling pointer crash on deallocation. Switch to block-based observation or add deinit.
- [x] **Fix `SettingsDAO.getAll()` trap on duplicate keys** — `Dictionary(uniqueKeysWithValues:)` crashes if duplicates exist. Use `Dictionary(_:uniquingKeysWith:)` with a conflict resolver.
- [x] **Fix `OrbitPlaylistManifest` Codable fragility** — struct declares defaults (`var version: Int = 1`) but `Decodable` synthesis ignores them. Missing keys in JSON cause decode failure. Implement custom `init(from:)` with fallback values.

### 1.3 — Memory Leaks & Resource Management

- [x] **Fix `AudioEngine.fadeGain` leaking Timer** (lines 201-210) — `Timer.scheduledTimer(withTimeInterval:repeats:true)` is never stored or invalidated. Multiple calls accumulate concurrent timers fighting over gain. Store the timer as a property; invalidate in `stop()`/`cleanup()` and before starting a new fade.
- [x] **Fix `TranscriptStore` NotificationCenter leak** (macOS) — same as crash fix above, also a memory leak.
- [x] **Audit `PlayerModel.deinit` Task capture** (line 626-638) — captures `audioEngine` and `bookmarkStore` in a `Task` during deinit. If deinit runs off-main, the `@MainActor` dispatch races against teardown.

### 1.4 — Silent Failure Remediation

- [x] **Replace `try?` in `InlineFlashcardTriggerController`** (lines 52, 87) — flashcard loading and grading failures silently return empty/no-op. Add `os_log` error logging at minimum; surface failures to UI where appropriate.
- [x] **Replace `try?` in `SnippetPlayer`** (lines 20, 24) — silent failure when audio file unreadable or segment zero-length. Caller never knows playback didn't start. Invoke `onPlaybackDidEnd` with a failure flag.
- [x] **Replace empty `catch` blocks in `FlashcardCreationSheet`** (line 87) and `NoteEditorView` (line 72) — database insert failures silently discarded. Show a user-visible error or at minimum log with `os_log`.
- [x] **Fix `try?` in `DailyReviewViewModel.logFlashcardReviewed`** (line 68) — review history silently lost on logging failure.
- [x] **Fix `try?` in migration `ensureAudiobookExists`** (MigrationService) — genuine failures (disk full, constraint) silently ignored; child records may insert without parent.
- [x] **Fix macOS `try?` transcription/export errors** (`MacContentView:75`, `TranscriptPane:196`) — transcription and export failures disappear with zero user feedback.
- [x] **Replace `print()` with `os_log`** across ~15 locations — `AudioEngine`, `ArtworkCache`, `BookmarkStore`, `Persistence`, `TranscriptService`, `WatchSyncManager`, `WatchCommandRouter` all use `print()` for errors. In production, these go to a console no one reads.

### 1.5 — Database Integrity & Performance

- [x] **Add missing indexes**: `audiobook.added_at` (full scan on every library listing), `playback_state.last_played_at` (same), `transcription_word.segment_id` (zero indexes on this table).
- [x] **Fix LIKE wildcard injection in `EPubBlockDAO.search`** (line 76) — user input `%` and `_` characters act as SQL wildcards. Escape them or use a different matching strategy.
- [x] **Fix JSON injection in `BookmarkDAO` metadataJSON** (line 84) — `voiceMemoPath` interpolated directly into a JSON string. Paths containing `"` or `\` produce invalid JSON. Use `JSONEncoder` or proper escaping.
- [x] **Fix `transcription_word` table** — no primary key, no unique constraint, no indexes. `MutablePersistableRecord` semantics are unreliable without an explicit PK.
- [x] **Fix `flashcard` dead columns** — `created_at`/`modified_at` exist in schema but the `Flashcard` struct has no matching properties. Columns never updated; feature non-functional.
- [x] **Make V4 migration atomic** — individual bookmark/speed/setting migration failures are caught and logged but leave the DB in partial state. Wrap in a single transaction.
- [x] **Fix `speed` type mismatch** — `PlaybackEventDAO` parameter is `Float` but schema column is `Double`. Inconsistent with rest of codebase where speed is `Double`.le`. Inconsistent with rest of codebase where speed is `Double`.

### 1.6 — Pipeline Tooling Fixes

- [x] **Fix hardcoded "OEBPS" base path** (`EPUBAlignmentPipeline.swift:83`) — breaks alignment for EPUBs with non-standard directory layouts (EPUB/, content/, flat). Now derives base path from OPF file location via `opfPath.deletingLastPathComponent()`.
- [x] **Fix XHTMLParser silent XML parse failures** (line 37) — return value of `parser.parse()` discarded; partial/malformed data silently propagated. Now checks the return value and throws `AlignmentError.corruptXHTML` on failure.
- [x] **Fix XHTMLParser silent UTF-8 conversion failure** (line 34) — `guard let data = ... else { return }` silently drops entire spine items. Now throws `AlignmentError.corruptXHTML` with a descriptive reason.
- [x] **Fix orphaned markers appended at end** (`MarkerInjector.swift:117`) — un-timestamped segments always placed after all timestamped segments, breaking EPUB reading order. Now interleaves by `epubCharOffset` between the correct alignment boundaries.
- [x] **Make alignment threshold configurable** (`SlidingWindowAligner.swift:75`) — hardcoded 0.40 match acceptance. Added `matchAcceptanceThreshold` parameter to the initializer (defaults to 0.40).
- [x] **Validate Whisper model name before init** (`TranscribeCommand.swift:56`) — typos like "Base" instead of "base" produce late, cryptic errors. Added `validate()` method checking against known WhisperKit model identifiers.
- [x] **Python: support GPU/MPS device** (`transcription_generator.py:175`) — hardcoded `device="cpu"`. Added `--device` flag with `auto` default that detects CUDA availability; uses `float16` compute on GPU for better throughput.

### 1.7 — View & UI Model Fixes

- [x] **Fix `TransportButton` accessibility** — the custom `PrimitiveButtonStyle` never calls `configuration.trigger()`, breaking VoiceOver, keyboard navigation, and standard press-and-release. Added `configuration.trigger()` calls in both tap and long-press gesture handlers.
- [x] **Fix `NowPlayingTab.formatHhMm` rounding** (line 90-99) — `Int((seconds / 60.0).rounded())` rounds up, causing "2m" at 89.6s instead of "1m". Changed to truncation (`Int(seconds / 60.0)`).
- [x] **Fix `TimelineGroup.id` collision** — `ISO8601Format()` without fractional seconds; two groups in the same second get identical IDs violating `Identifiable`. Now uses `.iso8601(includingFractionalSeconds: true)`.
- [x] **Fix `TranscriptionSegment.id` float precision** — `"\(startTime)-\(endTime)"` can produce different strings for logically identical timestamps (`0.1` vs `0.10000000000000001`). Now uses integer milliseconds.
- [x] **Fix `Note.id` mutability** — `var id: String` violates `Identifiable` stability contract. Already `let` — no fix needed.
- [x] **Add missing `Equatable`/`Hashable`** to `AggregatedChapter`, `M4BBook`, `Chapter` — prevents use in Sets/Dictionary keys and causes unnecessary SwiftUI re-renders. Added compiler-synthesized conformances.

### 1.8 — watchOS Critical Fixes

- [x] **Fix stale `watchQuickBookmarkTimeoutSeconds`** — closure-initialized stored property read once at init. `applyState` writes new UserDefaults value but the property never updates. Changed to computed property with getter/setter backed by App Group defaults.
- [x] **Fix voice memo payload size** — `sendMessage` (65KB limit) and `transferUserInfo` (~65KB) both fail for voice memos. Now uses `WCSession.transferFile(_:metadata:)` which has no payload limit and is handled by existing `handleFile` on the phone side.
- [x] **Fix widget timeline spam** (WatchViewModel:473) — `WidgetCenter.shared.reloadTimelines` called on every WCSession state update (0.5-1s during playback). Now debounced to at most once per 30 seconds.
- [x] **Fix haptic hailstorm** (WatchViewModel:529, 552-558) — haptics fire on every command reply + optimistically before confirmation. Multiple rapid haptics desensitize. Added centralized `playHaptic(_:)` helper gated behind `isHapticFeedbackEnabled`; all 8 haptic call sites now respect the user preference.

### 1.9 — macOS Critical Fixes

- [x] **Fix `process.waitUntilExit()` blocking** (`TranscriptionManager:246`) — synchronous blocking inside `withTaskGroup` blocks a cooperative thread. Replaced with `withCheckedContinuation` + `process.terminationHandler` for proper async suspension.
- [x] **Fix hardcoded 300ms delay** (`MacPlayerModel:300-303`) — `Task.sleep(nanoseconds: 300_000_000)` waiting for duration to load. Replaced with `waitForReadyToPlay()` using KVO on `AVPlayerItem.status` with a 10s safety timeout.
- [x] **Fix `UserDefaults.standard` vs `AppGroupDefaults`** — macOS uses isolated UserDefaults for bookmarks; invisible to iOS/watchOS. Switched to `AppGroupDefaults.shared` with a one-time migration from `UserDefaults.standard`.

### 1.10 — Performance: Hot Path Allocations

- [x] **Cache `DateFormatter`/`ISO8601DateFormatter`** — `SpeedSuggestion.formattedDate` (new formatter every access), `TimelineScope.format()` (new formatter per call), `Note.init(from:)` (3 formatters per record), `RealTimeEvent.init(from:)` (1 per record). Made static lets on the respective types.
- [x] **Batch `AlignmentService.recalculateTimeline` SQL writes** — individual `updateAlignment` calls in a loop; thousands of separate transactions for large books. Wrapped all writes in a single `db.write` transaction via a new fileprivate `writeAlignment(db:...)` overload.
- [x] **Optimize `PlaylistView.playlistRows`** — computed property iterates all chapters/filters/sorts bookmarks on every body recomputation. Cached to `@State` and recomputed only on dependency changes via `.onChange` observers.

---

## Phase 2: Strip Unimplemented Feature References ✅

Goal: remove dead code and forward-looking references that mislead contributors.

- [x] **Remove all video/future-media references** — `MediaPlayable` protocol doc ("future video features"), property names `audioStartTime`/`audioEndTime` (rename to `startTime`/`endTime` since there's no video to disambiguate), any "forward-looking for video" comments.
- [x] **Remove stale `.claude/plans/` directory** — 29 plan files dating back to early refactoring phases. Already staged for deletion (shown in git status). Complete the removal.
- [x] **Remove `ALPHA_OVERNIGHT_NOTES.md` and `neededfixes.md`** — already staged for deletion. Complete.
- [x] **Remove dead code**: `timelineDAO` property on `BookmarkDAO` and `FlashcardDAO` (declared but never assigned), unused `Combine`/`CryptoKit` imports in `TranscriptStore` and `TranscriptionManager`, redundant `Identifiable` conformance on `ContentCard`.
- [x] **Remove `ContentCardEditor.saveChanges()` stub** — empty function with "Phase 6 note: actual DB save wired in later iteration". Either implement or remove the Save button.
- [x] **Remove `contentCard.cardType` default case** — shows "Not Editable" view while still offering a Save button. Misleading UX.
- [x] **Remove single-case `PlayerDeepLink` enum** — convert to struct with optional `time` property.
- [x] **Remove `Optional.isNil` extension** (macOS TranscriptPane) — pollutes global namespace; `== nil` already exists.
- [x] **Remove redundant V3 index registrations** — V3 re-creates indexes V1 already made. `ifNotExists: true` makes this safe but indicates sloppy versioning.
- [x] **Remove macOS `ObjCBool` usage** — use modern `Bool` with new API or `resourceValues(forKeys:)`.
- [x] **Remove duplicated SHA256 hashing** (macOS ×3) — `MacContentView`, `TranscriptionManager`, `TranscriptPane` all have identical hashing. Extract to `Shared/`.
- [x] **Remove `SpeedSuggestion.Scenario.insufficient(Double)` unused associated value** — switch case ignores the payload. Remove or use the value.
- [x] **Remove `ContentCard.isSummaryItem` default case** — use exhaustive switch so compiler catches new enum additions.
- [x] **Remove dead `.transcription` check in `ContentCard.init(from: RealTimeEvent)`** — `isEditable` checks for `.transcription` but the switch never produces that case.

---

## Phase 3: UI Polish & Accessibility

Goal: improve fit-and-finish, Dynamic Type support, and accessibility compliance.

- [ ] **Fix hardcoded layout constants** — `NowPlayingLayout` static properties don't adapt to safe areas or device sizes. iPhone SE may produce negative heights. Use `GeometryReader` or `@Environment(\.dynamicTypeSize)`.
- [ ] **Add Dynamic Type support** to `ListeningProgressModuleView` (fixed 140pt width), `ChapterTimeBlockView` (hardcoded 200pt max bar), `StatsModuleView`, dashboard cards.
- [ ] **Add `.accessibilityAddTraits(.isButton)`** to custom-styled buttons on macOS and watchOS — `.buttonStyle(.plain)` removes default accessibility mapping.
- [ ] **Audit all `UIImpactFeedbackGenerator` calls** for overuse — `BottomToolbarView` fires haptics on every non-navigational tap (loop, speed cycle). Make configurable or reduce.
- [ ] **Fix `SpeedCardView` speed cycle inconsistency** — cycling uses `[1.0, 1.25, 1.5, 2.0]` but `TransportControlsView` uses `[1.0, 1.25, 1.5, 2.0, 3.0]`. Reconcile to a single source of truth.
- [ ] **Extract reusable `InlineStepperRow`** — duplicated in `SmartRewindSettingsView` and `WatchAppSettingsView`. Promote to `Components/`.
- [ ] **Push `GeometryReader` down in `NowPlayingTab`** — currently wraps entire body, causing potential layout loops. Restrict to views that need the proxy.
- [ ] **Decompose large view bodies**: `PlayerLoadingCoordinator.loadFolder` (163 lines), `PlayerLoadingCoordinator.prepareToPlay` (113 lines), `PlaybackController.play()` (78 lines). Break into private well-named methods.
- [ ] **Fix `playlistRows` performance** — computed property that iterates all chapters/bookmarks on every render. Memoize or use view model caching.
- [ ] **Add empty states** to timeline feed, bookmarks list, and review queue — currently blank when data is absent.
- [ ] **Add error states** to flashcard creation, note editing, and content card editor — errors currently swallowed silently.
- [ ] **Make volume boost gain configurable** — hardcoded +9.0 dB in `AudioEngine.setGain`. Surface in settings.
- [ ] **Make NowPlaying skip intervals respect user settings** — `MPRemoteCommandCenter` skip intervals hardcoded to 30s instead of using `seekForwardDuration`/`seekBackwardDuration` from SettingsManager.
- [ ] **Fix macOS hardcoded audio extensions** — missing `aiff`, `aac`, `ogg`, `opus`, `wma`.
- [ ] **Fix `NowPlayingTab` chapter/track progress text duplication** — `chapterProgressText()` and `trackProgressText()` are near-identical. Single parameterized method.

---

## Phase 4: Spaced Repetition System (SRS)

Goal: fix existing Anki/flashcard code, then implement proper SM-2 scheduling.

### 4.1 — Fix Existing Flashcard Code

- [ ] **Fix silent flashcard grade failures** — `try? FlashcardDAO.grade()` in `InlineFlashcardTriggerController` swallows errors. Add logging and user feedback.
- [ ] **Fix silent flashcard load failures** — `try? FlashcardDAO.flashcards()` returns `[]` on error, appearing as "no cards due."
- [ ] **Fix `SnippetPlayer` silent completion failure** — when audio unreadable or segment zero-length, `onPlaybackDidEnd` never fires. Caller remains in "playing" state.
- [ ] **Fix flashcard `created_at`/`modified_at` dead columns** — columns exist in schema but struct ignores them. Wire up properly.
- [ ] **Fix `flashcardDeckImport.triggerTiming` as free-form String** — should be a String-backed enum (`beginning`, `end`, `manualOnly`).
- [ ] **Fix `logFlashcardReviewed` silent logging failures** — review history silently lost.
- [ ] **Fix `DailyReviewViewModel` error swallowing** — both JSON serialization and DAO logging use `try?`.
- [ ] **Fix stale `SnippetPlayer` generation counter** — race condition noted in CHANGELOG (generation counter for stale completion). Verify fix is complete.

### 4.2 — Implement SM-2 Algorithm

- [ ] **Design SM-2 data model** — ease factor, interval, repetitions, next review date, grade history. New `SRSReview` table or extend existing `flashcard` columns.
- [ ] **Implement SM-2 core algorithm** — `quality: 0...5` → compute new ease factor, interval, and next review date. Handle lapses (quality < 3) with interval reset.
- [ ] **Build daily review queue** — query due cards sorted by priority (overdue first, then scheduled). Respect daily review limits.
- [ ] **Add review session UI** — graded review flow with show-answer-then-grade pattern. Leverage existing `FlashcardReviewSession`/`FlashcardReviewCard` views.
- [ ] **Add review statistics** — cards reviewed today, retention rate, forecast. Wire into `DashboardShelf`/`UpcomingReviewsModuleView`.
- [ ] **Add push notification trigger** — local notification when daily reviews are due.

### 4.3 — Inline Recall During Playback

- [ ] **Fix inline flashcard trigger tolerance** — hardcoded 0.75s tolerance and 5s dedup threshold. Make configurable per-deck.
- [ ] **Improve trigger detection** — current approach checks `currentSeconds` against card timestamps. Consider matching against timeline position ranges for robustness.
- [ ] **Fix watch review session sync** — ensure `WatchReviewView` stays in sync with phone-side review state.

---

## Phase 5: EPUB Viewing

Goal: a dedicated EPUB reader experience integrated with the audiobook timeline.

### 5.1 — Dedicated Reader Tab (Option A)

- [ ] **Add 3rd tab to `RootTabView`** — "Read" tab alongside NowPlaying and Timeline.
- [ ] **Build paginated EPUB renderer** — render XHTML content with CSS styling, respect spine reading order.
- [ ] **Implement font controls** — size adjustment, font family (Lexend/OpenDyslexic/system), line spacing, margins.
- [ ] **Add reading position sync** — track current EPUB block; highlight corresponding text as audio plays (based on existing alignment anchors or enhanced transcript).
- [ ] **Add tap-to-seek** — tap a paragraph to seek audio to the nearest alignment anchor.
- [ ] **Add offline reading** — preload EPUB assets; render without audio playback active.

### 5.2 — Integrated Timeline Reader (Option B)

- [ ] **Add EPUB content cells to `TimelineFeedCollectionView`** — render paragraphs/sentences inline in the existing feed alongside bookmarks and flashcards.
- [ ] **Add reading-mode toggle** — switch timeline between "audio timeline" (current behavior) and "reading view" (EPUB-first ordering with audio sync).
- [ ] **Implement highlight-tracking** — highlight the currently-playing paragraph in the feed with auto-scroll.
- [ ] **Leverage existing `EPubBlock`/`AlignmentAnchor` data** — already in Schema V5. Use for positioning and sync.

### 5.3 — Decision Gate (do before implementing)

- [ ] Prototype both approaches with a single-book test.
- [ ] Measure scroll performance with full EPUB content (thousands of blocks).
- [ ] Evaluate: does the timeline feed handle EPUB-length content without performance degradation?
- [ ] Evaluate: does a dedicated reader tab create undesirable context-switching during listening?
- [ ] **Decide and commit to one approach.**

---

## Phase 6: EPUB Manual Alignment

Goal: let users create and edit alignment anchors between EPUB blocks and audio timestamps.

- [ ] **Build anchor creation UI** — "Pin this paragraph to current playback time" button/gesture. Writes `alignment_anchor` record via `AlignmentAnchorDAO`.
- [ ] **Build anchor editor** — list all anchors for a book; edit timestamp, delete, reorder.
- [ ] **Implement interpolation recalculation** — existing `AlignmentService.recalculateTimeline` stub. Given locked anchors, interpolate positions for all un-anchored blocks between them.
- [ ] **Add visual anchor indicators** — in the reader/timeline, show which blocks are manually anchored vs. auto-positioned.
- [ ] **Handle edge cases** — anchor at chapter boundaries, overlapping anchors, anchors with zero-duration blocks.
- [ ] **Add anchor import/export** — share alignment data between devices or users.

---

## Phase 7: Testing & CI Infrastructure

Goal: prevent regressions as the codebase grows.

- [ ] **Expand unit test coverage** — current test files exist but are sparse. Add tests for: `ChapterGroupingService`, `PlaybackController` state transitions, `BookmarkStore` CRUD, `DatabaseService` migration paths, `AlignmentService` interpolation math.
- [ ] **Add snapshot tests** for critical UI — NowPlayingTab, TimelineFeed cells, PlayerScrubberView section ticks.
- [ ] **Add database migration tests** — verify each schema version upgrade path with realistic data.
- [ ] **Add pipeline integration tests** — end-to-end EPUB → align → enhanced transcript with known fixtures.
- [ ] **Set up CI** (GitHub Actions or Xcode Cloud) — build all 4 targets, run tests, enforce Swift 6 concurrency checking.
- [ ] **Add performance regression tests** — timeline feed scroll FPS, database query latency with large datasets.
- [ ] **Add accessibility audit to CI** — flag missing accessibility labels/traits.

---

## Phase 8: Polish & Future

Stretch goals and ideas beyond the core roadmap.

- [ ] **Localization completeness audit** — Dutch localization exists; verify coverage across all user-facing strings.
- [ ] **iPad layout optimization** — current layout targets iPhone; iPad gets a scaled-up version. Consider split-view or sidebar for TimelineTab on iPad.
- [ ] **CarPlay enhancements** — `CarPlaySceneDelegate` exists but is minimal. Add Now Playing template, browse-by-chapter, Siri intents.
- [ ] **Widget enhancements** — multiple widget families (`.accessoryRectangular`, `.accessoryInline`), playback progress complications.
- [ ] **Siri Shortcuts integration** — "Resume my audiobook", "Add a bookmark", "Start daily review."
- [ ] **Stats & insights dashboard** — listening time, books completed, speed trends, review streaks.
- [ ] **Social/sharing features** — share bookmark with quote, export reading progress, book club sync.
- [ ] **Audio effects** — equalizer presets, silence trimming, chapter-level volume normalization.
- [ ] **Multi-device sync** — iCloud sync for bookmarks, playback position, flashcards (beyond current WatchConnectivity).
- [ ] **Accessibility: VoiceOver audit** — full pass through every screen with VoiceOver enabled.
- [ ] **macOS polish** — proper menu bar integration, Touch Bar support, keyboard shortcuts for all transport actions.

---

## Summary by Phase

| Phase | Focus | Est. items |
|-------|-------|-----------|
| 1 | Stability & Correctness Fixes | ✅ Complete |
| 2 | Strip Unimplemented References | ✅ Complete |
| 3 | UI Polish & Accessibility | ~15 |
| 4 | Spaced Repetition System | ~14 |
| 5 | EPUB Viewing | ~10 |
| 6 | EPUB Manual Alignment | ~6 |
| 7 | Testing & CI | ~7 |
| 8 | Polish & Future | ~11 |

**Completed: 2/8 phases | Remaining: ~63 items**
