# Architecture Overview

<!-- ⚠️  AUTO-GENERATED — do not edit directly. -->
<!-- Regenerate with: `make architecture`                        -->

**Last generated:** 2026-05-30 (updated for simplified global interpolation, chapter hide, Echo rebrand, anchor label UX, playback time toolbar)

This document maps the source-tree layout of the Xcode targets and Shared/
module in the Echo: Audiobook Study Player project. Folders are shown in the order
returned by the filesystem; only source, configuration, and metadata files
are included (build artifacts, asset catalogs, and media files are filtered
out).

---

## EchoCore (iOS)

```
CarPlay/CarPlaySceneDelegate.swift
DailyPlanner/PlannedSession.swift
DailyPlanner/RealTimeProjectionService.swift
DailyPlanner/SchedulingSheet.swift
Development Assets/.gitkeep
Info.plist
Localizable.xcstrings
Models/AggregatedChapter.swift
Models/Chapter.swift
Models/ChapterSection.swift
Models/ContentCard.swift
Models/FlashcardDeckImport.swift
Models/M4BBook.swift
Models/Note.swift
Models/EchoPlaylistManifest.swift
Models/PlayerDeepLink.swift
Models/RealTimeEvent.swift
Models/SpeedSuggestion.swift
Models/TimelineDisplayItem.swift
Models/TimelineGroup.swift
Models/TimelineScope.swift
Models/Track.swift
Echo_AudioBooksApp.swift
EchoCore.entitlements
Protocols/PlayerModelComponentProtocols.swift
Protocols/SettingsManagerProtocol.swift
Protocols/StoreManagerProtocol.swift
Services/AlignmentService.swift
Services/ArtworkCache.swift
Services/AudioEngine.swift
Services/BookmarkArtworkCoordinator.swift
Services/BookmarkStore.swift
Services/BookPreferencesService.swift
Services/BookSettingsOverrideStore.swift
Services/ChapterGroupingService.swift
Services/ChapterLoadingCoordinator.swift
Services/ChapterService.swift
Services/DeckImportService.swift
Services/DeepLinkHandler.swift
Services/EPUBAssetStorage.swift
Services/EPUBAutoImportScanner.swift
Services/EPUBImportCoordinator.swift
Services/EPUBImportService.swift
Services/InlineFlashcardTriggerController.swift
Services/LoopMode.swift
Services/M4BParser.swift
Services/MockMediaProvider.swift
Services/NotificationNames.swift
Services/NowPlayingController.swift
Services/Persistence.swift
Services/PlaybackController.swift
Services/PlaybackEventLogger.swift
Services/PlaybackProgressPresenter.swift
Services/PlaybackTimelineService.swift
Services/PlayerLoadingCoordinator.swift
Services/PlayerTimelinePersistenceService.swift
Services/PlaylistManager.swift
Services/PlaylistManifestService.swift
Services/SecurityScopeManager.swift
Services/SettingsManager.swift
Services/SleepTimerManager.swift
Services/SleepTimerMode.swift
Services/SnippetPlayer.swift
Services/StoreManager.swift
Services/TimelineIngestionFactory.swift
Services/TimelineIngestionService.swift
Services/TimelineService.swift
Services/TranscriptService.swift
Services/WatchCommandRouter.swift
Services/WatchConnectivityCoordinator.swift
Services/WatchStateContextBuilder.swift
Services/WatchSyncManager.swift
State/PlaybackState.swift
Utilities/FolderPicker.swift
Utilities/ViewModifiers.swift
Utilities/WordFrequencyComputer.swift
ViewModels/DailyReviewViewModel.swift
ViewModels/PlayerModel.swift
ViewModels/PlayerModel+PlaybackControllerDelegate.swift
ViewModels/PlayerModel+PlaybackLogging.swift
ViewModels/PlayerModel+WatchState.swift
ViewModels/TimelineFeedViewModel.swift
Views/BookmarkCardView.swift
Views/Bookmarks.swift
Views/BookSettingsView.swift
Views/BottomToolbarView.swift
Views/ChapterTimeBlockView.swift
Views/Components/AlbumArtHeroView.swift
Views/Components/PlayerControlBar.swift
Views/Components/FlashcardCreationSheet.swift
Views/Components/FlashcardOverlayView.swift
Views/Components/TranscriptOverlayView.swift
Views/Components/TranscriptRowView.swift
Views/Components/WordCloudView.swift
Views/ContentCardEditor.swift
Views/DashboardShelf.swift
Views/FlashcardReviewCard.swift
Views/FlashcardReviewSession.swift
Views/HelpContent.swift
Views/HelpView.swift
Views/ListeningProgressModuleView.swift
Views/NoteEditorView.swift
Views/NowLineView.swift
Views/NowPlayingLayout.swift
Views/PhonePlayerSettingsView.swift
Views/NowPlayingTab.swift
Views/PlayerScrubberView.swift
Views/PlayheadLineView.swift
Views/PlaylistTimelineView.swift
Views/PlaylistView.swift
Views/RootTabView.swift
Views/SettingsView.swift
Views/SleepTimerCardView.swift
Views/SmartRewindSettingsView.swift
Views/SpeedCardView.swift
Views/SpeedSuggestionBanner.swift
Views/StatsModuleView.swift
Views/TimelineContentCard.swift
Views/TimelineContentView.swift
Views/TimelineFeedCollectionView.swift
Views/TimelineHeaderView.swift
Views/TimelineTab.swift
Views/TransportControlsView.swift
Views/UpcomingReviewsModuleView.swift
Views/VoiceMemoOverlayView.swift
Views/WatchAppSettingsView.swift
```

## Echo: Audiobook Study Player macOS

```
Info.plist
Echo_Audiobooks_macOS.entitlements
Echo_Audiobooks_macOSApp.swift
Views/MacContentView.swift
Views/MacPlayerModel.swift
Views/TranscriptionManager.swift
Views/TranscriptPane.swift
Views/TranscriptStore.swift
```

## Echo: Audiobook Study Player Watch App

```
Info.plist
Models/WatchBookmark.swift
EchoCoreWatchApp.swift
Services/WatchViewModel.swift
Services/WatchVoiceMemoRecorder.swift
Views/Bookmarks.swift
Views/Components/ToggleTraitModifier.swift
Views/ContentView.swift
Views/PlayerPage.swift
Views/WatchControlBackground.swift
Views/WatchReviewView.swift
Views/WordCloudPage.swift
```

## Shared (cross-target)

```
AppGroupDefaults.swift
Database/AlignmentAnchorRecord.swift
Database/BookmarkRecord.swift
Database/ChapterRecord.swift
Database/DAOs/AlignmentAnchorDAO.swift
Database/DAOs/AudiobookDAO.swift
Database/DAOs/BookmarkDAO.swift
Database/DAOs/ChapterDAO.swift
Database/DAOs/EPubBlockDAO.swift
Database/DAOs/FlashcardDAO.swift
Database/DAOs/NoteDAO.swift
Database/DAOs/PlannedSessionDAO.swift
Database/DAOs/PlaybackEventDAO.swift
Database/DAOs/PlaybackStateDAO.swift
Database/DAOs/RealTimeEventDAO.swift
Database/DAOs/SettingsDAO.swift
Database/DAOs/TimelineDAO.swift
Database/DAOs/TrackDAO.swift
Database/DAOs/TranscriptionDAO.swift
Database/DatabaseService.swift
Database/EPubBlockRecord.swift
Database/Flashcard.swift
Database/MigrationService.swift
Database/NoteRecord.swift
Database/PlannedSessionRecord.swift
Database/RealTimeEventRecord.swift
Database/Schema_V1.swift
Database/Schema_V2.swift
Database/Schema_V3.swift
Database/Schema_V4.swift
Database/Schema_V5.swift
Database/Schema_V6.swift
Database/Schema_V7.swift
Database/Schema_V8.swift
Database/TimelineItem.swift
Database/TrackRecord.swift
Database/TranscriptionRecord.swift
Database/TranscriptionWord.swift
EnhancedTranscriptionSegment.swift
LayoutPreset.swift
MediaPlayable.swift
SafeFileName.swift
SyncMarker.swift
TimeFormatting.swift
TranscriptionSegment.swift
WatchAction.swift
WatchFlashcard.swift
WordFrequency.swift
```

## Widget Extension

```
Info.plist
Models/AppIntent.swift
Views/Echo_Audiobooks_Widget.swift
Views/Echo_Audiobooks_WidgetBundle.swift
Views/Echo_Audiobooks_WidgetControl.swift
```

**Widget artwork handling:** The widget has a tight memory budget — archiving large images crashes the extension. Rather than discarding oversized album art, `safelyDownsampledData` in `Echo_Audiobooks_Widget.swift` uses `CGImageSourceCreateThumbnailAtIndex` (ImageIO) to downsample artwork larger than 60×60pt to retina-scale thumbnails encoded as JPEG at 0.75 quality. ImageIO is a streaming decoder that only reads enough of the encoded source data to produce the requested thumbnail size, so it avoids allocating a full-resolution bitmap. This ensures every book shows artwork on the widget, regardless of the source image dimensions.

## Tools & Pipeline

### EPUB-Audio Alignment (In-App)

> **Note:** The earlier `EchoTranscriptionCLI` tool (Swift CLI + Python/Whisper pipeline) has been **abandoned**. It remains in the `Tools/` directory for reference but is not part of the current user workflow.

Alignment is now performed entirely in-app, without any external tools or API calls:

1. **EPUB Import:** When the user adds an EPUB file alongside their audiobook, `EPUBImportService` parses it into `epub_block` records (headings, paragraphs, images) stored in the database.
2. **Global flat interpolation:** `AlignmentService.recalculateTimeline()` uses a simplified global interpolation approach. Synthetic anchors are placed at the first block (time 0.0) and last block (total duration from chapter markers). All blocks between locked anchors interpolate linearly by word-count-weighted position. This replaces the earlier chapter-aware approach with virtual boundary anchors at chapter start/end.
3. **Manual refinement:** The user long-presses any card in the Reader and chooses "Align to Now", "Align to 5s Ago", "Align to Chapter Start", or "Align to Chapter End" to lock that block to a specific timestamp. Each locked anchor improves the accuracy of neighboring blocks through proportional interpolation.
4. **Timeline recalculation:** `AlignmentService.recalculateTimeline()` runs in a single DB transaction, updating all affected `timeline_item` rows with new interpolated timestamps.
5. **Block/chapter hiding:** Users can mark individual blocks ("Not in Audio (This Paragraph)") or entire chapters ("Not in Audio (Whole Chapter)") as hidden when the EPUB contains content not present in the audiobook narration. Hidden blocks get `alignment_status = omitted`, `is_enabled = false`. The `hideChapter(chapterIndex:reason:)` method on `AlignmentService` batch-hides all blocks in a chapter.

**Word-count proportional interpolation (Schema V8):**

Earlier alignment used sequence-index-based linear interpolation, which assumed uniform spacing between blocks. Schema V8 introduces `word_count` on `epub_block` to weight block positions proportionally by content length. The current algorithm:

1. Computes a cumulative `wordPosition` for each block (running sum of half-word-counts, placing each block's "center" at its proportional position within the book).
2. Synthetic anchor points are placed at the first block (time 0.0) and last block (total duration from the last chapter marker's end time), ensuring the entire book is bounded.
3. Interpolation fraction = `(blockPos − prevPos) / (nextPos − prevPos)` using word positions between any two bracketing anchors (locked or synthetic).
4. This produces smooth timestamp estimates for uneven paragraph lengths (e.g., long prose followed by short dialogue) without requiring chapter boundary data.

**Key types:**

- `AlignmentService` — Creates anchors and recalculates timeline via word-count-weighted proportional interpolation between locked and synthetic boundary anchors. Supports `eraseAnchor(blockID:)`, `resetAlignment()`, `hideBlock(blockID:reason:)`, `hideChapter(chapterIndex:reason:)`, and `anchorChapterEnd(blockID:chapterIndex:time:)` for anchor and content management.
- `AlignmentAnchorRecord` — A user-created lock point tying an EPUB block to an audio time
- `EPubBlockRecord` — Database row for a parsed EPUB block (heading, paragraph, or image). Includes `wordCount` (V8) for proportional math.
- `TimelineItem` — Materialized row linking blocks to audio timestamps with `timestamp_source` and `alignment_status`
- `TimestampSource` — Enum: `.lockedAnchor`, `.interpolated`, `.estimated`, `.none`
- `AlignmentStatus` — Enum: `.lockedAnchor`, `.interpolated`, `.estimated`, `.unaligned`, `.omitted`

### EPUB Reader Feed (Current)

The Reader tab renders EPUB content as a feed of styled cards aligned to the audio playback position. It replaces the earlier Timeline Feed prototype with a simpler, purpose-built reader surface.

**Database tables:** The `timeline_item` materialized table continues to store alignment data linking `epub_block` records to audio timestamps, with the same purpose-built indexes for efficient range queries.

**Dual-write synchronization:** When `BookmarkDAO` or `FlashcardDAO` creates, updates, or deletes a record, it also writes to `timeline_item` with the corresponding source tracking columns. This keeps the feed in sync without polling or triggers.

**Schema evolution: EPUB block alignment**

| Schema | Change |
|---|---|
| V5 | `epub_block` and `alignment_anchor` tables; extends `timeline_item` with `epub_block_id`, `timestamp_source`, `alignment_status`, `alignment_confidence` |
| V6 | Minor schema refinements |
| V7 | `html_content` (TEXT) and `card_color` (TEXT) columns on `epub_block` — preserves inner HTML for rich text rendering and per-card tint overrides |
| V8 | `word_count` (INTEGER) column on `epub_block` — enables proportional interpolation weighted by paragraph word length instead of raw sequence index |

Key indexes: `idx_epub_block_sequence` (audiobook_id, sequence_index), `idx_epub_block_chapter` (audiobook_id, chapter_index), `idx_epub_block_hidden` (audiobook_id, is_hidden), `idx_alignment_anchor_time` (audiobook_id, audio_time), `idx_alignment_anchor_block` (audiobook_id, epub_block_id).

**Alignment pipeline:**

```
EPUB (directory or .epub file)
  └─ EPUBImportService
       ├── Parse container.xml → OPF spine order
       ├── Parse XHTML → paragraph-level blocks
       ├── Copy images → Application Support/EPUBAssets/<safeAudiobookID>/
       └── Write epub_block records → SQL

User anchors (manual)
  └─ AlignmentService
       ├── moveBlockToCurrentTime / anchorSearchResult / anchorChapterStart/End
       ├── eraseAnchor(blockID:) / resetAlignment()
       ├── hideBlock(blockID:reason:) / unhideBlock(blockID:)
       ├── hideChapter(chapterIndex:reason:)   ← batch chapter hide
       └── recalculateTimeline (global word-count-weighted proportional interpolation)
```

**Reader UI architecture:**

```
ReaderTab (SwiftUI)
  ├── ReaderHeaderView          ← search bar ("Find in book..."), scroll-to-active button, TOC button, settings button
  ├── Chapter/section title bar ← sticky context showing current chapter and section
  ├── Hint banners              ← context menu tip (one-time), alignment guidance (until first anchor)
  └── ReaderFeedCollectionView  ← UICollectionView via UIViewRepresentable
       ├── 4 cell types: HeadingCardCell, ParagraphCardCell, ImageCardCell, ChapterDividerCell
       ├── Anchor labels         ← green "locked" badge on manually-aligned cards (Heading/Paragraph)
       ├── Active block tracking — blue bar on the card matching current playback position
       ├── Auto-scroll — follows playhead via binary search on timeline cache; disengages on manual scroll
       ├── Force-scroll trigger  ← counter-based invalidation for repeated scroll-to-same-block
       ├── Context menu — long-press any card for:
       │    ├── Align to Now / Align to 5s Ago
       │    ├── Align to Chapter Start / Align to Chapter End (all blocks)
       │    ├── Not in Audio (This Paragraph) / Not in Audio (Whole Chapter) ← hide non-narrated content
       │    ├── Erase Anchor (if lockedAnchor) / Reset Alignment (all anchors)
       │    ├── Change Color / Save Bookmark / Copy Text / Save Image
       └── NSDiffableDataSourceSnapshot<String> — identity from ReaderCardItem.id
            └─ ReaderFeedViewModel (@Observable)
                 ├── Loads blocks from EPubBlockDAO, grouped by chapter
                 ├── Search: filters to matching blocks via blockDAO.searchBlocks()
                 ├── Active block: binary search on timelineCache for O(log N) lookup
                 ├── alignmentStatusByBlockID: [String: String] — per-block status for anchor badge display
                 ├── audioStartTimeByBlockID: [String: TimeInterval] — per-block timestamp for anchor labels
                 └── Data: [ReaderCardSection] — sections contain [ReaderCardItem] (chapterHeader or block)
```

**Key types:**

- `ReaderCardSection` — A group of cards under a heading hierarchy (e.g. ["Chapter 1", "Section 1.1"])
- `ReaderCardItem` — Enum with 2 cases: `.chapterHeader(title, index)` and `.block(EPubBlockRecord)`
- `EPubBlockRecord` — Database row for a parsed EPUB block (heading, paragraph, or image)
- `ReaderSettings` — Font size, line spacing, and card tint color for the reader

### UI Architecture (3-Tab)

The iOS app uses a 3-tab layout managed by `RootTabView`:

```
RootTabView
├── Tab 0: NowPlayingTab   ← pure media consumption (album art, scrubber, transport)
├── Tab 1: ReaderTab        ← EPUB reader with search, alignment, and TOC (only when EPUB is loaded)
└── Tab 2: TimelineTab      ← playlist, track/chapter list, bookmarks
```

**NowPlayingTab** focuses entirely on active playback: `AlbumArtHeroView`, `PlayerScrubberView`, and `TransportControlsView`. It is strictly play/pause/scrubbing — all auxiliary controls (speed, sleep timer, bookmarks, loop mode) live in the `BottomToolbarView` and `DashboardShelf`.

**ReaderTab** (available only when `model.hasEPUB` is true) is the EPUB-backed reading surface. It renders the book as a feed of styled cards — headings, paragraphs, and images — aligned to the audio playback position. The header auto-hides on scroll-down and reveals on scroll-up. It includes:
- A search bar for full-text search across the EPUB with inline match highlighting
- A Table of Contents sheet for structural navigation
- Auto-scroll that follows the audio playhead, highlighting the active paragraph with a blue bar
- Long-press context menus on every card for fixing alignment, changing card colors, creating bookmarks, and copying text
- Per-card alignment anchors that lock EPUB blocks to exact audio timestamps

**TimelineTab** currently hosts `PlaylistView` for track/chapter browsing and reordering (with `.onMove` drag handles and per-item toggle controls).

When a book is loaded, a `PlayerControlBar` mini-player appears above the `BottomToolbarView`,
showing artwork, title/chapter metadata, and play/pause — tapping it opens the full NowPlaying view.
```

### PlayerModel Decomposition

`PlayerModel` has been decomposed from a ~2,900-line god class into a thin coordinator (~1,200 lines) that owns and wires together 20+ focused services. Each service has a single responsibility:

| Service | Responsibility |
|---|---|
| `PlaybackController` | Core playback logic, track-end handling, enabled-state enforcement, navigation |
| `PlaybackState` | Shared mutable state (tracks, chapters, progress, artwork, chapterSections) as `@Observable` |
| `BookmarkStore` | Bookmark CRUD, voice memo playback, file cleanup, enabled-state toggling |
| `SleepTimerManager` | Countdown, fade-out, pause-on-end |
| `NowPlayingController` | MPNowPlayingInfoCenter, MPRemoteCommandCenter |
| `ChapterGroupingService` | Detects and collapses Libation-style sub-section chapter atoms into logical chapters, retaining section boundaries for scrubber tick marks |
| `ChapterLoadingCoordinator` | Chapter parsing, transcript loading, word cloud computation, invokes `ChapterGroupingService` |
| `PlaybackProgressPresenter` | Progress updates, elapsed time formatting, Now Playing info |
| `PlayerLoadingCoordinator` | Folder/track loading, audio session setup, persistence, seek-on-load |
| `BookmarkArtworkCoordinator` | Artwork generation, caching, Now Playing artwork updates |
| `PlayerTimelinePersistenceService` | Timeline item ingestion, EPUB presence checks |
| `InlineFlashcardTriggerController` | SRS flashcard popover detection and trigger logic |
| `EPUBImportCoordinator` | EPUB file import and block ingestion |
| `BookSettingsOverrideStore` | Per-book font, volume boost, and bookmarks-inline overrides |
| `BookPreferencesService` | Resolution logic for per-book + global preference merging |
| `WatchStateContextBuilder` | Builds the watch connectivity state dictionary |
| `WatchCommandRouter` | Routes incoming watch commands to the appropriate facade method |
| `PlaylistManager` | Track/chapter ordering, enabled-state toggling, reset |
| `PlaylistManifestService` | `.orbitplaylist.json` manifest read/write/migration |
| `Persistence` | UserDefaults and on-disk state persistence |
| `SecurityScopeManager` | Security-scoped resource access grants |
| `TranscriptService` | Transcript JSON loading, word cloud computation |

PlayerModel wires these via coordinator closures in `init()` and exposes thin pass-through computed properties for view binding. The decomposition uses two patterns:

1. **Direct injection** (data-access services): `PlaylistManager`, `TranscriptService`, `SecurityScopeManager` receive `PlaybackState` and `Persistence` directly.
2. **Coordinator closures** (behavioral services): `PlaybackController`, `BookmarkStore`, `ChapterLoadingCoordinator`, etc. communicate back to `PlayerModel` through `@ObservationIgnored` closure variables wired in `init()`.

### Player Layout Styles

The iOS player supports two layout variants, selected via **Settings > Player Layout Style**:

| Style | Scrubber | Transport Controls | Target |
|---|---|---|---|
| **Default** | Slider above time labels (vertical stack) | Full-size (76pt play/pause, 64pt others) | Standard experience |
| **Compact** | Slider between time labels (horizontal row) | Reduced-size (60pt play/pause, 50pt others) | Minimalist, one-handed use |

The layout style is persisted in `SettingsManager.playerLayoutStyle` (UserDefaults key `playerLayoutStyle`) and drives conditional rendering in `PlayerScrubberView` and `TransportControlsView`.

Each transport button now supports a **dual-action model**: a tap executes the primary action (configured via `PhonePlayerSettingsView` under "Tap Actions"), while a long-press (>0.5s) executes a secondary action (configured under "Long Press"). The `TransportButton` component uses a custom `PrimitiveButtonStyle` (`TransportPrimitiveButtonStyle`) to layer both gestures onto a single control without the gesture conflicts that arise from stacking `.onTapGesture` + `.onLongPressGesture` on a standard SwiftUI `Button`. Both action sets are persisted in `SettingsManager.phonePage` and `SettingsManager.phoneLongPressPage`, and saved/loaded in `PhonePreset` data models.

### Chapter Sections & Section Navigation

Libation-ripped M4B audiobooks encode chapters as fine-grained sub-section atoms with shared base titles (e.g. "Chapter 11. A", "Chapter 11. B"). `ChapterGroupingService` collapses these into logical chapters and retains the original atoms as **sections** in `PlaybackState.chapterSections` (a `[Int: [Chapter]]` map keyed by logical chapter index).

**Section ticks on scrubber:** `PlayerScrubberView` overlays a `SectionTickOverlay` (`Canvas`-based, `allowsHitTesting(false)`) that draws hairline tick marks at each sub-section boundary. While scrubbing, the slider snaps to these boundaries with haptic feedback (`UIImpactFeedbackGenerator`), limited to a maximum of 20 visible ticks per chapter to avoid visual clutter.

**Section navigation:** Two `WatchAction` cases — `.nextSection` and `.previousSection` — are available on both phone and watch button layouts. They mirror chapter-level navigation but operate at the section level:
- `nextSection()`: seeks to the next section boundary within the current logical chapter, falling back to the next chapter.
- `previousSectionOrRestart()`: seeks to the previous section boundary (or restarts the current section if > 5 seconds in), falling back to the previous chapter.

These actions are routed through `PlaybackController` → `WatchCommandRouter` → `WatchConnectivityCoordinator` for watch-initiated commands, and directly for phone transport controls (either as tap or long-press secondary actions).

**Watch page layout:** The watch app supports up to 5 customizable pages of action slots (25 total), synced from the phone via `SettingsManager.watchPage1` through `watchPage5` App Group keys. Pages whose slots are all `.empty` are automatically hidden from the watch `TabView`. Configuration is managed in `WatchAppSettingsView` using a swipeable `TabView` with page indicators.

**Playlist disclosure groups:** In `PlaylistView`, logical chapters with section data render as `DisclosureGroup` rows, expanding to reveal tappable section rows that seek to each section boundary. A play icon indicates the currently active section.

### Reader Interaction Model

The Reader uses a tap/long-press interaction model on card cells:

| Gesture | Target | Action |
|---|---|---|
| **Tap** | Paragraph / heading card | Seek playback to the block's audio timestamp |
| **Tap** | Image card | Open image in system viewer |
| **Long press** | Any card | Context menu: Align to Now, Align to 5s Ago, Align to Chapter Start, Align to Chapter End, Not in Audio (This Paragraph), Not in Audio (Whole Chapter, if in a chapter), Erase Anchor (locked anchors), Reset Alignment (all anchors), Change Color, Save Bookmark, Copy Text, Save Image (images only) |

**Active block tracking:** The paragraph currently matching the audio playback position is highlighted with a blue leading bar (`activeBar`) on its card. The ReaderFeedViewModel performs a binary search on a cached `[(start, end, blockID)]` array for O(log N) lookup each time the playback position changes.

**Auto-scroll:** When enabled, the collection view auto-scrolls to keep the active block centered. Scrolling manually pauses auto-scroll; tapping the scroll-to-active button (↓) in the header re-engages it with an immediate forced scroll to the current playback position. The header auto-hides on scroll-down and reappears on scroll-up.

**Bookmark lifecycle:** Bookmarks created via `BottomToolbarView.addBookmarkButton` flow through `BookmarkStore.appendBookmark` → `BookmarkDAO.syncToTimeline` → `timeline_item` table. The `.bookmarksDidChange` notification triggers a feed refresh, ensuring bookmarks appear inline immediately.

**Playlist management:** `PlaylistView` (embedded in `TimelineTab`) provides track/chapter reordering via drag handles in edit mode, per-item enable/disable toggles, and bookmark browsing with swipe-to-edit. The backend is handled by `PlaylistManager` (track/chapter ordering and enabled-state persistence) and `PlaylistManifestService` (`.orbitplaylist.json` manifest I/O).

### EPUB-to-Audio Data Model: Handling Mismatches

The in-app alignment system estimates block timestamps from chapter boundaries and user-created anchors. When the EPUB contains content that has **no corresponding audio** — images, footnotes, skipped prose, tables — it is preserved in the feed for visual browsing.

**Un-timestamped items:**

| Property | Timestamped Segment | Un-timestamped (EPUB-only) Block |
|---|---|---|
| `startTime` (Enhanced) | `TimeInterval` (e.g. 12.5) | `nil` |
| `endTime` (Enhanced) | `TimeInterval` (e.g. 15.2) | `nil` |
| `audioStartTime` (TimelineItem) | Valid `TimeInterval` | `-1` (sentinel) |
| `sequenceIndex` (Enhanced) / `epubSequenceIndex` (TimelineItem) | Monotonic, shared with un-timestamped items | Monotonic, interleaved by EPUB position |
| `markers` | `[SyncMarker]?` from alignment | Contains the source marker (`.image`, `.footnote`, etc.) |
| `isTimestamped` | `true` | `false` |

The ingestion layer (`TimelineIngestionFactory`) converts `nil` timestamps from `EnhancedTranscriptionSegment` to `-1` in `TimelineItem.audioStartTime`. The `isTimestamped` computed property on `TimelineItem` checks `audioStartTime >= 0`, centralizing the sentinel convention.

**Ordering:** Timestamped segments sort by `startTime`. Un-timestamped blocks sort by their source marker's `epubCharOffset`. The pipeline merges both into a single `[EnhancedTranscriptionSegment]` array, assigns consecutive `sequenceIndex` values, and writes the output as enhanced transcript JSON.

**Feed behavior:**
- **Tapping** a timestamped segment seeks the audio playhead to `startTime`.
- **Tapping** an un-timestamped block (image, footnote) opens it in the system viewer — no seek occurs.
- Both types render inline in correct EPUB reading order, preserving the author's intended structure even when the audiobook narration skips content.

**Orphan threshold:** A marker is classified as "orphaned" (un-timestamped) when its `epubCharOffset` is more than 50 characters from the nearest alignment range boundary. This threshold prevents spurious un-timestamped items from minor alignment jitter while catching genuinely unmatched EPUB content.

### Reader-Specific Toolbar Controls

When the user is on the Reader tab (`selectedTab == .read`), `BottomToolbarView` switches from the standard transport layout (loop, speed, sleep timer) to a simplified playback control set optimized for reading with audio:

```
BottomToolbarView (Reader mode)
├── skipBackwardButton  ← configurable duration (e.g., "gobackward.15")
├── playPauseButton     ← centered play/pause toggle
├── skipForwardButton   ← configurable duration (e.g., "goforward.30")
├── timelineButton      ← quick access to full timeline
└── addBookmarkButton   ← bookmark at current position
```

The skip durations are read from `SettingsManager.seekBackwardDuration` / `seekForwardDuration` and displayed with dynamic SF Symbol naming (`gobackward.\(duration)` / `goforward.\(duration)`).

### Anchor Status Indicators on Cards

**Reader feed cards:**
- `HeadingCardCell` and `ParagraphCardCell` include an `anchorLabel` (top-right corner) that always displays the block's audio timestamp (or "None" if unaligned). Locked-anchor timestamps render in **red** (`.systemRed`); estimated/interpolated timestamps render in **secondary label color**. The `setManuallyAligned(_:timeString:)` method controls both visibility and color.
- The alignment status and audio start time caches are maintained in `ReaderFeedViewModel` (`alignmentStatusByBlockID`, `audioStartTimeByBlockID`) and passed through `ReaderFeedCollectionView` to the coordinator for cell configuration.

**Timeline feed cells:**
- `TextSegmentCell`, `ChapterMarkerCell`, and `ImageAssetCell` each include an `anchorIcon` (`UIImageView` with `link.circle` SF Symbol, tinted green) in their header stack. The icon is shown when `item.alignmentStatus == "lockedAnchor"`.
- Context menus on locked-anchor items include "Erase Anchor" (destructive); all items offer "Reset Alignment" (destructive, clears all anchors).

### Debug Development Assets

The project includes a development assets bundle for testing the EPUB reader pipeline:

```
EchoCore/Development Assets/macbeth_m4b/
├── macbeth.epub           ← Shakespeare's Macbeth (EPUB)
└── William Shakespeare - Macbeth.m4b  ← matching audiobook
```

In `#if DEBUG` builds, `SettingsView` exposes a "Load Development Assets" button under a "Debug Menu" section. This invokes `PlayerModel.loadFolder()` with the main bundle URL, loading the Macbeth audiobook and EPUB for immediate testing of the reader, alignment, and search features without requiring external file selection.

