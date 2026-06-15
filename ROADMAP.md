# Echo: Audiobook Study Player — Roadmap

<!-- Last updated: 2026-06-14 (added Phase 9: Audiobookshelf Integration — sequenced after narration/Kokoro, before WS9 release; download-to-local approach. Prior: Phases 1-3 complete, Phase 4 90%, Phase 5 complete, Phase 6 core complete, Phase 7 not started, Phase 8 partially started) -->

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
- [x] **Fix `EchoPlaylistManifest` Codable fragility** — struct declares defaults (`var version: Int = 1`) but `Decodable` synthesis ignores them. Missing keys in JSON cause decode failure. Implement custom `init(from:)` with fallback values.

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

- [x] **Fix hardcoded layout constants** — ✅ GeometryReader pushed down to relevant views only. Dynamic Type via @ScaledMetric on dashboard cards.
- [x] **Add Dynamic Type support** to `ListeningProgressModuleView` (fixed 140pt width), `ChapterTimeBlockView` (hardcoded 28pt bar), `StatsModuleView`, dashboard cards — ✅ replaced with @ScaledMetric.
- [x] **Add `.accessibilityAddTraits(.isButton)`** to custom-styled buttons on macOS and watchOS — ✅ added to 15+ buttons across 8 files.
- [x] **Audit all `UIImpactFeedbackGenerator` calls** for overuse — ✅ created `Haptic` utility gated behind `isHapticFeedbackEnabled`; replaced 20+ call sites.
- [x] **Fix `SpeedCardView` speed cycle inconsistency** — ✅ `SettingsManager.Defaults.speedPresets` as single source of truth; watch synced to 5 speeds.
- [x] **Extract reusable `InlineStepperRow`** — ✅ promoted to `Views/Components/InlineStepperRow.swift`.
- [x] **Push `GeometryReader` down in `NowPlayingTab`** — ✅ restricted to `playerContent` only.
- [x] **Decompose large view bodies**: ✅ `loadFolder` split into 6 helpers, `prepareToPlay` into 5 helpers, `play()` smart rewind into 4 helpers.
- [x] **Fix `playlistRows` performance** — ✅ already memoized via `@State` + `.onChange` (Phase 1.90).
- [x] **Add empty states** to timeline feed, bookmarks list, and review queue — ✅ timeline feed gets `ContentUnavailableView`; playlist and review already covered.
- [x] **Add error states** to flashcard creation, note editing, and content card editor — ✅ save failures now show alert dialogs with localized error messages.
- [x] **Make volume boost gain configurable** — ✅ `SettingsManager.volumeBoostGain` (default 9.0 dB), plumbed through PlaybackController → AudioEngine.
- [x] **Make NowPlaying skip intervals respect user settings** — ✅ `NowPlayingController` reads `seekForwardDuration`/`seekBackwardDuration`.
- [x] **Fix macOS hardcoded audio extensions** — ✅ added `aiff`, `aac`, `ogg`, `opus`, `wma`, `flac`.
- [x] **Fix `NowPlayingTab` chapter/track progress text duplication** — ✅ extracted shared `bookProgressParts()` helper.

---

## Phase 4: Spaced Repetition System (SRS)

Goal: fix existing Anki/flashcard code, then implement proper SM-2 scheduling.

### 4.1 — Fix Existing Flashcard Code ✅

- [x] **Fix silent flashcard grade failures** — ✅ `PlayerModel.gradeFlashcard` now uses `do/catch` with `os_log`. `InlineFlashcardTriggerController` and `DailyReviewViewModel` already hardened in Phase 1.
- [x] **Fix silent flashcard load failures** — ✅ watch state and `TimelineTab.refreshDueCount` now use `do/catch` with error logging.
- [x] **Fix `SnippetPlayer` silent completion failure** — ✅ all failure paths (file read, zero-length, engine start) already call `onPlaybackDidEnd?()`.
- [x] **Fix flashcard `created_at`/`modified_at` dead columns** — ✅ set on creation (`FlashcardCreationSheet`, `DeckImportService`) and on grading (`SpacedRepetitionService.apply`).
- [x] **Fix `flashcardDeckImport.triggerTiming` as free-form String** — ✅ introduced `FlashcardTriggerTiming` String-backed enum with `.beginning`, `.end`, `.manualOnly` cases.
- [x] **Fix `logFlashcardReviewed` silent logging failures** — ✅ already uses `do/catch` with `logger.error` (Phase 1).
- [x] **Fix `DailyReviewViewModel` error swallowing** — ✅ `loadDueCards`, `gradeCard`, and `logFlashcardReviewed` all use `do/catch` with logging (Phase 1).
- [x] **Fix stale `SnippetPlayer` generation counter** — ✅ generation guard `generation == self.currentGeneration` prevents stale callbacks.

### 4.2 — Implement SM-2 Algorithm ✅

- [x] **Design SM-2 data model** — ✅ `Flashcard` already includes easeFactor, intervalDays, repetitions, nextReviewDate, lastGrade, lastReviewedAt.
- [x] **Implement SM-2 core algorithm** — ✅ `SpacedRepetitionService.apply(grade:to:)` implements full SM-2 (interval progression, lapse handling, ease factor).
- [x] **Build daily review queue** — ✅ `FlashcardDAO.allDueCards()` queries by `next_review_date <= now`, used by `DailyReviewViewModel`.
- [x] **Add review session UI** — ✅ `FlashcardReviewSession` + `FlashcardReviewCard` with graded review flow.
- [x] **Add review statistics** — ✅ `FlashcardDAO.reviewStats()` returns dueCount, reviewedToday, totalCards. Wired into `UpcomingReviewsModuleView`.
- [x] **Add push notification trigger** — ✅ `ReviewNotificationService` schedules daily local notification when due cards exist.

### 4.3 — Inline Recall During Playback

- [x] **Fix inline flashcard trigger tolerance** — ✅ tolerances centralized as constants in `InlineFlashcardTriggerController`; trigger logic hardened in Phase 1.
- [ ] **Improve trigger detection** — current approach checks `currentSeconds` against card timestamps. Consider matching against timeline position ranges for robustness. (Deferred: requires timeline-anchored triggering model.)
- [ ] **Fix watch review session sync** — ensure `WatchReviewView` stays in sync with phone-side review state. (Deferred: requires WatchConnectivity review state channel.)

---

## Phase 5: EPUB Viewing

Goal: a dedicated EPUB reader experience integrated with the audiobook timeline.

### 5.1 — Dedicated Reader Tab (Option A) ✅

- [x] **Add 3rd tab to `RootTabView`** — "Read" tab alongside NowPlaying and Timeline. Implemented as `ReaderTab` with 3-tab navigation managed by `RootTabView`.
- [x] **Build paginated EPUB renderer** — Feed-based `UICollectionView` (`ReaderFeedCollectionView`) rendering heading, paragraph, image, and chapter divider cards with CSS-styled attributed text. 4 cell types: `HeadingCardCell`, `ParagraphCardCell`, `ImageCardCell`, `ChapterDividerCell`.
- [x] **Implement font controls** — `ReaderSettings` bundle: font size, line spacing, card background tint color (hex). Persisted per-app-session via `@State` in `ReaderTab`.
- [x] **Add reading position sync** — Active block tracking via binary search on `timelineCache` (O(log N) lookup). Active paragraph highlighted with blue leading bar (`activeBar`). Auto-scroll follows playhead and disengages on manual scroll.
- [x] **Add tap-to-seek** — Tap any paragraph or heading card to seek playback to the block's interpolated audio timestamp. Tap image cards to open in system viewer.
- [x] **Add offline reading** — EPUB blocks rendered from local database (`EPubBlockDAO`). Images copied to Application Support on import. No network dependency for reading.
- [x] **Full-text search** — Search bar in reader header with inline match highlighting. `EPubBlockDAO.searchBlocks()` with escaped LIKE wildcards for safe user-input matching.
- [x] **Table of Contents** — `ChapterPickerSheet` for structural navigation through the EPUB spine.
- [x] **Per-card color override** — Long-press → "Change Color" → `CardColorPickerSheet` for highlighting passages.
- [x] **Bookmark creation from reader** — Long-press any card → "Save Bookmark" creates a timestamped bookmark at the block's audio position.

### 5.2 — Integrated Timeline Reader ✅ (converged with 5.1)

- [x] **Add EPUB content cells to `TimelineFeedCollectionView`** — `TimelineFeedCollectionView` renders paragraphs, chapters, and images as `TimelineItem` rows alongside bookmarks and flashcards, with anchor status icons on aligned items.
- [x] **Implement highlight-tracking** — Timeline feed supports active position tracking with inline anchored-content display.
- [x] **Leverage existing `EPubBlock`/`AlignmentAnchor` data** — Schema V5 tables used throughout. Timeline items linked to EPUB blocks via `epub_block_id` foreign key with `alignment_status` and `timestamp_source` columns.
- [x] **Dual surface support** — Both dedicated Reader tab (card-feed UX) and Timeline tab (list-feed UX) surfaces are live, each offering alignment management and context menus. The Reader tab is the primary reading surface; the Timeline tab shows aligned content in its heterogeneous feed.

### 5.3 — Decision Gate ✅ (resolved)

- [x] Prototype both approaches with a single-book test. → Decided on Option A (dedicated Reader tab) with Timeline feed retaining EPUB-aware cells.
- [x] Measure scroll performance with full EPUB content (thousands of blocks). → `UICollectionView` with `NSDiffableDataSourceSnapshot` handles large datasets performantly via cell reuse.
- [x] Evaluate: does the timeline feed handle EPUB-length content without performance degradation? → Yes, with efficient cell reuse and section grouping.
- [x] Evaluate: does a dedicated reader tab create undesirable context-switching during listening? → No; the Reader tab provides a focused reading experience that complements (not competes with) the NowPlaying tab. Transport controls remain accessible via the `BottomToolbarView`.
- [x] **Decide and commit to one approach.** → Option A: Dedicated Reader tab as primary reading surface; Timeline feed as secondary EPUB-aware surface.

---

## Phase 6: EPUB Manual Alignment ✅ (core complete)

Goal: let users create and edit alignment anchors between EPUB blocks and audio timestamps.

- [x] **Build anchor creation UI** — "Align to Now" / "Align to 5s Ago" context menu actions on every card in both Reader and Timeline feeds. Writes `alignment_anchor` records via `AlignmentAnchorDAO`.
- [x] **Build chapter boundary anchors** — "Align to Chapter Start/End" on heading cards for bulk chapter anchoring.
- [x] **Implement interpolation recalculation** — `AlignmentService.recalculateTimeline()` uses word-count-based proportional interpolation between locked and virtual boundary anchors, replacing the earlier sequence-index-based approach for more accurate positioning (Schema V8).
- [x] **Add visual anchor indicators** — Locked-anchor cards show a green "link" label (Reader) or 🔗 icon (Timeline) with the anchored timestamp. Interpolated/estimated items show appropriate status text.
- [x] **Add anchor management** — "Erase Anchor" to remove a single anchor, "Reset Alignment" to clear all anchors for a book. Both trigger timeline recalculation and UI refresh.
- [x] **Handle edge cases** — Virtual boundary anchors at chapter starts/ends, block-level word-count weighting for proportional distribution, sentinel values (`-1`) for un-timestamped items.
- [ ] **Add anchor import/export** — share alignment data between devices or users. (Deferred: requires export format design.)
- [ ] **Word-count weighting for automatic alignment hints** — use `wordCount` column (Schema V8) for smarter initial estimates without manual anchors. (Deferred: auto-alignment heuristics beyond current proportional interpolation.)

---

## Phase 7: Testing & CI Infrastructure

Goal: prevent regressions as the codebase grows.

- [~] **Expand unit test coverage** — current test files exist but are sparse. Added tests for `PlaybackSessionRecorder` and `PlaybackSegmentBuilder` state machine.
- [ ] **Add snapshot tests** for critical UI — NowPlayingTab, TimelineFeed cells, PlayerScrubberView section ticks.
- [x] **Add database migration tests** — verify each schema version upgrade path with realistic data. (Added SchemaV14Tests covering stats/bookmark columns and backfills).
- [ ] **Add pipeline integration tests** — end-to-end EPUB → align → enhanced transcript with known fixtures.
- [ ] **Set up CI** (GitHub Actions or Xcode Cloud) — build all 4 targets, run tests, enforce Swift 6 concurrency checking.
- [ ] **Add performance regression tests** — timeline feed scroll FPS, database query latency with large datasets.
- [ ] **Add accessibility audit to CI** — flag missing accessibility labels/traits.

---

## Phase 8: Study Workflow & Polish

Priority items for the Echo rebrand and study-player positioning, plus stretch goals.

### 8.1 — Study Workflow Foundation (P0)

- [ ] **Interactive onboarding tutorial** — first-launch walkthrough demonstrating the core study workflow: load audiobook → add EPUB → search → align a paragraph → create bookmark → create flashcard. A 4-step interactive guide that teaches the mental model. The Read tab should always be visible (not hidden behind `hasEPUB`), showing an educational empty state: "Add an EPUB alongside your audiobook to unlock searchable text, alignment, and flashcards."
- [ ] **Reader toolbar speed controls** — add speed adjustment (at minimum) and loop mode to the reader-specific bottom toolbar. Studying means variable playback speed — slowing down for dense passages, speeding up through familiar material. Requiring a tab switch to change speed breaks the study flow.
- [ ] **Alignment as achievement, not chore** — show "% aligned" progress per chapter and per book. Celebrate when a chapter is fully aligned. After creating an anchor, offer contextual actions: "Create flashcard from this passage?" / "Add bookmark with this text?" Anchors are study waypoints — the UI should treat them that way.
- [ ] **Replace inline flashcard popups with mark-later model** — remove `InlineFlashcardTriggerController` auto-popovers that interrupt playback. Replace with: tag passages during listening → review tagged passages and create flashcards in a dedicated session later. Listening should be immersive; flashcard creation should be intentional and separate. (The trigger controller logic was hardened in Phase 1/4; this item is about UX redesign, not code health.)
- [~] **iCloud sync for study state** — sync bookmarks, alignment anchors, flashcards, and playback position across devices via CloudKit (leveraging the existing GRDB database layer). This is the single biggest infrastructure gap blocking the multi-device study workflow. A user who aligns 200 paragraphs on iPhone should see those anchors on iPad and Mac. **Progress:** `CloudKitSyncService` infrastructure in place with deterministic SHA-256 record names and `NSNumber`-based predicates. Sync currently covers alignment anchors. Full bookmark/flashcard/position sync still needed.
- [~] **Ship the Echo rebrand** — update app display name, bundle identifiers, App Store Connect metadata, screenshots, and marketing site. The name "Echo" reflects the core value: your spoken words echoing back as searchable, referenceable knowledge. Screenshots must demonstrate the study workflow within 10 seconds (search → align → bookmark → flashcard). **Progress:** Documentation (README, ARCHITECTURE, CHANGELOG) and the website use Echo branding. Xcode project bundle identifiers and the app group are now migrated to `com.echo.*` (entitlements, code, and `project.pbxproj`). The Fastlane `Appfile` still references `com.orbit.*` (flagged with TODO markers) pending coordinated App Store Connect changes and provisioning-profile regeneration (see `docs/provisioning-rebrand.md`).

### 8.2 — Polish & Stretch Goals

- [ ] **Localization completeness audit** — Dutch localization exists; verify coverage across all user-facing strings.
- [ ] **iPad layout optimization** — current layout targets iPhone; iPad gets a scaled-up version. Consider split-view or sidebar for TimelineTab on iPad.
- [ ] **CarPlay enhancements** — `CarPlaySceneDelegate` exists but is minimal. Add Now Playing template, browse-by-chapter, Siri intents.
- [ ] **Widget enhancements** — multiple widget families (`.accessoryRectangular`, `.accessoryInline`), playback progress complications.
- [ ] **Siri Shortcuts integration** — "Resume my audiobook", "Add a bookmark", "Start daily review."
- [ ] **Stats & insights dashboard** — listening time, books completed, speed trends, review streaks.
- [ ] **Social/sharing features** — share bookmark with quote, export reading progress, book club sync.
- [ ] **Audio effects** — equalizer presets, silence trimming, chapter-level volume normalization.
- [ ] **Accessibility: VoiceOver audit** — full pass through every screen with VoiceOver enabled.
- [ ] **macOS polish** — proper menu bar integration, Touch Bar support, keyboard shortcuts for all transport actions.

---

## Phase 9: Audiobookshelf Integration

Goal: connect a self-hosted **Audiobookshelf (ABS)** server as a first-class library source so a self-hosted collection flows into Echo's study pipeline.

**Sequencing:** lands **after the on-device narration (Kokoro) workstream**, **before WS9 "Polish & release"** (README → *The Road to v1.0*; this is WS8b). Targeted for 1.0. Full design rationale + verified source citations: the 2026-06-14 assessment.

**Central decision — download, don't stream.** Echo's audio engine reads bytes via `AVAudioFile(forReading:)` (local-only; `AudioEngine.swift:333`) and a book's identity *is* its folder URL. Once ABS bytes land in a folder the book is indistinguishable from a local import and **every differentiator keeps working** (alignment, phrase search, EPUB sync, flashcards). Streaming would fork the audio engine (XL) and disable those features — it is **deferred post-1.0** (§9.5).

### 9.1 — Foundation: connect & browse (size: M)

- [ ] **`AudiobookshelfService`** — concrete service, sibling to `CloudKitSyncService`; the app's first networked-account code. Minimal async/await `URLSession` client in the `MacAnkiExportView` house style. No new protocol (matches the concrete-type DI style — see §10.1 history).
- [ ] **Auth** — JWT login + refresh-with-rotation (persist the rotated refresh token *every time*; serialize refreshes to avoid self-invalidation). Tolerate self-signed certs, LAN `http`, and non-standard ports (homelab reality).
- [ ] **Credential storage** — per-server token in `KeychainStore` (new key; owner runs multiple servers). New `abs_server` table (`id, baseURL, username, defaultLibraryId`); the token never goes in SQLite.
- [ ] **Settings UI** — a "Connections" section in `SettingsView` following the existing `NavigationLink` sub-screen pattern. One server is enough for v1; multi-server is a fast-follow.
- [ ] **Browse** — list libraries → items → item detail; covers via `/api/items/{id}/cover?token=`.

### 9.2 — Download-to-local — the core (size: L)

- [ ] **"Add from Audiobookshelf"** action beside the existing `.fileImporter` in `PlaylistView`.
- [ ] **Background, resumable downloads** — `URLSessionConfiguration.background` (net-new; only `audio`/`fetch` background modes today, `Info.plist:46`). De-risk by shipping a foreground download first, then add background once the happy path works.
- [ ] **Managed library folder** — land audio into app-owned `Application Support/ABSLibrary/{remoteItemID}/`; the security-scoped `start/stopAccessingSecurityScopedResource` calls become no-ops for this folder (it's already ours).
- [ ] **Pull the bundled EPUB** — if `media.ebookFile` exists, download it into the *same* folder so `EPUBAutoImportScanner` auto-discovers the sibling `.epub` (`EPUBAutoImportScanner.swift:55`) — alignment/flashcards/search then fire with zero pipeline changes. The single cleanest synergy in the project.
- [ ] **Hand off to the existing pipeline** — call `PlayerLoadingCoordinator.loadFolder` unchanged; `M4BParser` parses chapters locally; anchors seed.
- [ ] **Identity (option B)** — keep `id = folderURL.absoluteString` for downloaded books; merely stamp `sourceType`/`serverID`/`remoteItemID` onto `AudiobookRecord` (migration v18). Because a downloaded book has a real folder, almost no `file://`-assuming call site breaks.
- [ ] **Anchor-reuse win** — `CloudKitSyncService.downloadAnchors` keys shared anchors on `title+author+duration` and *ignores* `audiobookID`, so a downloaded copy inherits WhisperKit anchors another device already computed (skips transcription on device 2). Verify end-to-end.

### 9.3 — Library discovery: search by topic (size: S–M)

- [ ] **Browse & search the connected ABS library by topic** — filter/search items by genre, tag, series, narrator, and author (ABS exposes all of these per item). This is *library-level* discovery — distinct from Echo's existing *within-book* phrase search (`EPubBlockDAO.search`).
- [ ] **Carry topic metadata onto import** — persist ABS genres/tags on the imported book so the local library is filterable by topic too (complements Echo's embedded topic tags).

### 9.4 — Two-way progress sync — Tier 3-lite (size: M, fast-follow)

- [ ] **Push/pull playback position** — wire ABS media-progress into the existing closures (`PlayerModel.coordinator_saveProgress` / `coordinator_persistAndSync` and the restore-on-load path, `PlayerModel.swift:711`); throttle pushes to ~15–30 s while playing. (CloudKit syncs only alignment anchors, **not** progress — so the only conflict is Echo-local vs ABS.)
- [ ] **Conflict policy** — add `updatedAt(ms)` to `Persistence` / `ManifestPlaybackState`; compare against ABS `lastUpdate` on open; ABS is authoritative for ABS-backed books; local sidecar is offline cache. Reuse WS8's conflict-rules thinking.
- [ ] **Offline reconciliation** — accumulate offline, reconcile via `POST /api/session/local-all` on reconnect. (Deferrable within the phase.)

### 9.5 — Deferred (post-1.0)

- [ ] **Tier 1 streaming (XL)** — a parallel `AVPlayer` backend that re-implements pitch-corrected speed / EQ / soundscape / visualizer / progress-tick and re-validates CarPlay + Watch. Revisit only if no-download casual listening becomes a hard, user-validated requirement. On a streamed book the study differentiators are disabled — gate them behind the existing "Coming"-style CTA so the tradeoff is legible.
- [ ] **ABS bookmark / finished-state round-trip** — best-effort and lossy (ABS bookmarks are title+time only, no voice memo).
- [ ] **Multi-server** beyond the v1 single connection.

---

## Summary by Phase

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Stability & Correctness Fixes | ✅ Complete |
| 2 | Strip Unimplemented References | ✅ Complete |
| 3 | UI Polish & Accessibility | ✅ Complete |
| 4 | Spaced Repetition System | ✅ 4.1–4.2 complete; 4.3 1/3 (2 deferred) |
| 5 | EPUB Viewing | ✅ Complete (dedicated Reader tab + Timeline integration) |
| 6 | EPUB Manual Alignment | ✅ Core complete (6/8 items); 2 deferred (anchor import/export, word-count alignment hints) |
| 7 | Testing & CI | ~7 items remaining |
| 8 | Study Workflow & Polish | ~17 items remaining (6 P0, 11 stretch); Accent Contrast Safety ✅, Now Playing redesign ✅, Watch Connectivity hardened ✅, Pomodoro timer ✅, CloudKit sync infrastructure in place |
| 9 | Audiobookshelf Integration | 🔜 Planned — after narration (Kokoro), before WS9 release (download-to-local + topic search + progress sync; streaming deferred post-1.0) |

**Completed: 5/9 phases (+ Phase 6 core, substantial Phase 8 foundations) | Remaining: ~26 items + Phase 9 (Audiobookshelf) planned**

### June 2026 Highlights (since last update)

- **Accent Contrast Safety Pipeline** — `ColorMetrics` (WCAG/CIELAB), `AccentSafetyNet` (A→B→C rescue ladder), `extractPalette` (shared histogram pass), artwork-derived accent color with legibility guarantees
- **Now Playing UI Redesign** — `UnifiedTopHeader`, `UnifiedBottomDock`, full-bleed artwork split layout, adaptive theming
- **Watch Connectivity Hardened** — Durable application context for significant state, transport commands never ride background queue, stale `userInfo` handling, timer suspension cap
- **Pomodoro Timer** — Hours support, multi-wheel picker, thicker progress indicator, dynamic formatting, persistent alarm
- **Watch Enhancements** — Fullscreen cover art viewer, configurable date overlay
- **Swift Concurrency Modernized** — `MainActor.assumeIsolated` across 9 service files, `nonisolated(unsafe)` annotations, `@preconcurrency import AVFoundation` project-wide
- **Bug Fixes** — Pause on output device disconnect, progress save before track change, EPUB auto-import security scope, security scope URL reuse, TokenDTW gap-cost initialization
