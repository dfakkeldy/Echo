# Changelog

All notable changes to Orbit Audiobooks.

## [Unreleased]

### Added
- **PDF companion document support:** Import PDF files alongside audiobooks for page-level alignment and bookmarking. `PDFDocumentView` wraps `PDFKit.PDFView` with auto-scale, continuous vertical scroll, and long-press context menus for alignment. `PDFViewState` (page index, zoom, scroll offset) persists in bookmarks via `pdf_view_state_json` column (Schema V11). `PDFImportCoordinator` handles security-scoped file copy with same-folder no-op prevention. PDF bookmark screenshots render the current page to JPEG for thumbnail images.
- **Manual alignment with scrubber joystick:** `ManualAlignmentSheet` provides fine-tuned alignment with play/pause, ±5s skip, and a `ScrubberJoystick` — a horizontal drag-track control with spring-return and exponential mapping (small pulls = slow, big pulls = fast) for precise scrubbing. Audio snippet preview plays during scrub for real-time feedback.
- **Hierarchical chapter titles:** `PlaylistView.computeHierarchicalTitles(for:)` detects parent-child relationships between consecutive chapter titles via prefix matching, formatting nested chapters with leading dots (e.g., "Part 1", ".Chapter 1", "..Section A") for visually scannable playlist hierarchies.
- **Reader tab three-level header:** Sticky reader header now displays Part → Chapter → Section hierarchy. When a part title exists, the chapter title renders smaller and in secondary color, creating visual depth. `ReaderFeedCollectionView` receives a `$topPartTitle` binding alongside existing title bindings.
- **Watch title scroll speed setting:** `watchTitleScrollSpeed` (Double, defaults to 30.0) controls the pixels-per-second scrolling rate for long titles in the watch player, configurable in `WatchAppSettingsView`.
- **Schema V11:** `pdf_view_state_json` (TEXT) columns added to `bookmark` and `timeline_item` tables for PDF view state persistence.
- **Proportional word-count alignment (Schema V8):** `word_count` column on `epub_block` enables alignment interpolation weighted by paragraph content length rather than raw sequence index. Longer paragraphs get proportionally wider time ranges; shorter ones are more tightly positioned. Improves accuracy for chapters with uneven prose/dialogue mixing.
- **Anchor management:** "Erase Anchor" removes a single locked anchor from a block; "Reset Alignment" clears all anchors for the current audiobook. Both trigger timeline recalculation. Available via context menu on locked-anchor cards in both the Reader and Timeline feeds.
- **Reader-specific bottom toolbar:** When the Read tab is active, `BottomToolbarView` switches to reader-optimized controls (skip back, play/pause, skip forward, timeline, bookmark) instead of the standard transport layout. Skip durations use configurable seek settings with dynamic SF Symbol naming.
- **Anchor status indicators:** Locked-anchor cards show a green badge — a timestamp label (Reader feed) or 🔗 icon (Timeline feed) — distinguishing manually-aligned items from interpolated/estimated ones.
- **Debug development assets:** Macbeth audiobook + EPUB bundle (`macbeth_m4b/`) under Development Assets, loadable via a `#if DEBUG` "Load Development Assets" button in Settings for instant reader pipeline testing.
- Mini-player control bar (`PlayerControlBar`) on the Timeline tab — appears above the bottom toolbar when a book is loaded, showing artwork, title/chapter metadata, and play/pause. Tap to open the full NowPlaying player.
- Configurable seek forward/backward durations (5–60s), synced between phone and watch.
- **Watch expanded to 5 pages** — up to 25 customizable action slots (5 pages × 5 slots) with per-page configuration and TabView-style page swiping in settings. Empty pages auto-hide on the watch.
- **Phone transport long-press actions** — each of the 5 transport buttons now supports a configurable long-press secondary action (`TransportButton` / `TransportPrimitiveButtonStyle`) with haptic feedback, configurable via a "Tap Actions" / "Long Press" segmented picker in `PhonePlayerSettingsView`.
- Customizable watch button layout presets — drag-and-drop configuration from the phone via `WatchAppSettingsView`.
- `LayoutPreset` data model (`WatchPreset`, `PhonePreset`) with WatchConnectivity sync and UserDefaults persistence. `WatchPreset` supports optional `page3`/`page4`/`page5` fields; `PhonePreset` supports optional `longPressSlots`.
- Configurable default playback speed per-book and globally.
- Theme accent color setting.
- Local watch playback timer with independent progress tracking.
- `os.log` migration for structured logging across all targets.
- GitHub Pages marketing site and privacy policy page.
- Timeline freeze mode for EPUB browsing with sync-and-resume anchoring.
- **Chapter grouping service** (`ChapterGroupingService`): detects and collapses Libation-style sub-section chapter atoms into logical chapters. Handles patterns like "Chapter 11. A" / "Chapter 11. B" → single "Chapter 11" spanning the full time range, with original sub-sections retained for scrubber tick marks.
- **Section navigation**: new `.nextSection` and `.previousSection` `WatchAction` cases for skipping between sub-section boundaries within chapters. Available on both phone transport controls and watch button layouts.
- **Section scrubber ticks**: `SectionTickOverlay` renders hairline tick marks on the scrubber rail at each sub-section boundary, with magnetic snapping and haptic feedback (`UIImpactFeedbackGenerator`) while dragging.
- **Compact player layout**: "Compact" layout style option in player settings, reducing transport button sizes and placing the scrubber inline between time labels for a minimalist, one-handed-friendly look.
- **Section disclosure groups in playlist**: logical chapters with sub-section data render as expandable `DisclosureGroup` rows, with tappable section rows and now-playing indicators.

### Changed
- **Playlist document import unified:** The "Import EPUB" button now accepts both EPUB and PDF files, with automatic routing to the appropriate importer. The Reader tab falls back from EPUB to PDF to empty state based on available companion documents.
- **Reader tab routing:** `RootTabView` now checks `model.hasPDF` when `model.hasEPUB` is false, routing to `PDFDocumentView` instead of `ReaderEmptyState`.
- **Alignment interpolation now uses word-count-weighted proportional math** (Schema V8) instead of sequence-index-based linear interpolation. Results in more accurate timestamp estimates for paragraphs of varying lengths.
- Settings, Book Settings, and Help toolbar buttons consolidated into a single "More" (`ellipsis.circle`) menu on both the NowPlaying tab and the NowPlaying top toolbar.
- Simplified scrubber layout: time labels always below the slider.
- Watch communication reliability improvements and playlist toggle UI polish.
- Artwork handling simplified; oversized widget artwork now downsampled via ImageIO instead of discarded.
- Timeline feed action buttons (bookmark, flashcard, etc.) now use `UIButton.Configuration` with larger content insets for improved hit targets while maintaining 14pt icon size.

### Fixed
- Watch skip forward/backward fallback SF Symbols corrected from nonexistent `goforward`/`gobackward` to valid `arrow.clockwise`/`arrow.counterclockwise`.
- Auto-resume after audio interruption when playback was paused.
- Digital crown deadzone to prevent accidental scrubbing on watch.
- Out-of-range crashes and settings view layout crash.
- Security-scoped URL access permissions for EPUB auto-import.
- Destructive file operations in EPUB import replaced with copy-only approach.
- EPUB heading hierarchy bug where explicit HTML header tags (e.g., `<h1>`) on sub-sections incorrectly overwrote active chapter and part context.

---

## [0.6] — 2026-05-10 (Build 8)

### Added
- Per-book settings overrides (font, volume boost, bookmarks-inline) via `BookSettingsOverrideStore`.
- EPUB import flow with `EPUBImportCoordinator` and auto-import scanner.
- Twitter-style timeline cards with materialized `timeline_item` table (Schema V4).
- `TimelineDisplayItem` enum for unified heterogeneous feed rendering (audiobook cards, timeline items, NowLine, scrubber gaps).
- Dual-path timeline ingestion: rich (EPUB + transcription) and sparse (audio-only chapters).
- `MediaPlayable` protocol for forward-looking video support.
- Playlist manifest (`.orbitplaylist.json`) for portable playlist state.

### Changed
- **PlayerModel decomposed** from ~2,900-line god class into a thin coordinator (~1,200 lines) wiring 20+ focused services: `PlaybackController`, `PlaybackState`, `BookmarkStore`, `SleepTimerManager`, `NowPlayingController`, `ChapterLoadingCoordinator`, `PlaybackProgressPresenter`, `PlayerLoadingCoordinator`, `BookmarkArtworkCoordinator`, `PlayerTimelinePersistenceService`, `InlineFlashcardTriggerController`, `EPUBImportCoordinator`, `BookSettingsOverrideStore`, `BookPreferencesService`, `WatchStateContextBuilder`, `WatchCommandRouter`, `PlaylistManager`, `PlaylistManifestService`, `Persistence`, `SecurityScopeManager`, `TranscriptService`.
- **Strict 2-tab UI**: NowPlayingTab (pure media consumption) + TimelineTab (unified library, feed, planner, review).
- NowPlaying layout redesigned with top toolbar and compact scrubber.
- Timeline feed rebuilt as hierarchical, speed-aware scroll with structural zoom (Library → Chapter → Transcription).

### Fixed
- Timeline ingestion pipeline now always fires regardless of chapter count.
- Swift 6 concurrency errors and deprecation warnings resolved.
- Infinite duration on chapters without chapter markers fixed.
- `@MainActor` isolation on `Observable` classes to prevent data races.
- SQLite `DEFAULT` syntax and in-memory test database configuration.
- Anki flashcard: generation counter to prevent stale SnippetPlayer completion races.
- Database: composite indexes on `audiobook_id` columns for query performance.
- Database: UTC ISO8601 date serialization for bookmarks and flashcards.

---

## [0.5] — 2026-05-05

### Added
- **SQL database foundation** with GRDB.swift: `DatabaseService`, `MigrationService`, and DAOs for all domain types.
- **V5 Schema**: `epub_block` and `alignment_anchor` tables for EPUB-audio alignment.
- **EPUB-Audio Alignment Pipeline** (`Tools/OrbitTranscriptionCLI/`): Swift CLI with `transcribe` and `align` subcommands. Includes `OrbitEPUBAligner` library with EPUB parsing, XHTML marker extraction, sliding-window NLP alignment, and marker injection.
- **Anki Spaced Repetition**: Inline flashcard recall during playback, daily review UI with SM-2 grading, snippet media playback (`SnippetPlayer`), JSON deck import, and watchOS hands-free review.
- **CarPlay** support with `CarPlaySceneDelegate`, browse template, and remote commands.
- Multi-file M4B folder support with aggregated chapters.
- Tab navigation: `RootTabView` with `NowPlayingTab` and `TimelineTab`.
- **Localization** with Dutch language support.
- Accessibility labels, values, and Dynamic Type support across iOS, macOS, and watchOS.
- Siri App Intents for dictated bookmarks.
- App Group persistence and WatchConnectivity state sync.

### Changed
- UI simplified to strict 2-tab architecture: NowPlaying (consumption) + Timeline (browsing).
- Playlist view rebuilt as hierarchical, speed-aware timeline.
- Watch app redesigned with immersive full-screen artwork and configurable layout.
- Classic watch background setting preserved as toggle.
- Settings centralized in `SettingsManager` with protocol-based mock support.

### Fixed
- Watch complication update frequency improved.
- Circular ring animation lock-up on background wake.
- Chapter-looping cascade and first-open silence resolved.
- 1× speed dead-zone eliminated.
- `AVAudioUnitVarispeed` replaced with `AVAudioUnitTimePitch` to preserve pitch at >1×.
- Security-scoped access lifetime extended across folder scan and image load.
- Optimistic state updates with rollback on Watch for reliability.

---

## [0.4] and earlier

### Added
- **AVAudioEngine** playback backend replacing AVPlayer for volume boost and granular audio control.
- **Smart Rewind**: adaptive rewind logic based on pause duration (seconds/minutes/hours).
- **Sleep timer** with countdown, fade-out, and pause-on-end modes.
- **Bookmarks with voice memos** that play inline at the saved position.
- Bookmark looping mode (loop between consecutive bookmarks).
- **Transcription overlay** with live auto-scroll, tap-to-seek, and word cloud visualization.
- macOS companion app with `NavigationSplitView`, bookmark sidebar, and transcript pane.
- Python and Swift CLI transcription tools (Whisper integration).
- Watch app with play/pause, skip, scrub, volume, loop mode, sleep timer, and bookmark commands.
- Widget extension with circular progress ring and `TogglePlaybackIntent`.
- Sidecar JSON persistence for bookmarks and playback state.
- Markdown export and deep linking for bookmarks.
- Dyslexia-optimized typography (Lexend, OpenDyslexic fonts).
- Haptic feedback toggle via App Group.

### Changed
- Project reorganized into MVVM folder structure per target.
- Legacy `BookLoop`/`LoopPlayer` projects removed.
- Relicensed from GPL-3.0 to MIT.

### Fixed
- Watch bookmark HIG compliance.
- Memory issues in widget and complication rendering.
- Bookmark looping boundary logic and chapter boundary detection.
