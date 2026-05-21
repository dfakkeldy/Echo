# Architecture Overview

<!-- ⚠️  AUTO-GENERATED — do not edit directly. -->
<!-- Regenerate with: `make architecture`                        -->

**Last generated:** 2026-05-19 (updated: 2-tab refactor)

This document maps the source-tree layout of the Xcode targets and Shared/
module in the Orbit Audiobooks project. Folders are shown in the order
returned by the filesystem; only source, configuration, and metadata files
are included (build artifacts, asset catalogs, and media files are filtered
out).

---

## OrbitAudioBooks (iOS)

```
Info.plist
Localizable.xcstrings
Models/Chapter.swift
Models/ContentCard.swift
Models/Note.swift
Models/PlannedSession.swift
Models/PlayerDeepLink.swift
Models/RealTimeEvent.swift
Models/SpeedSuggestion.swift
Models/TimelineDisplayItem.swift
Models/TimelineGroup.swift
Models/TimelineScope.swift
Models/Track.swift
Orbit_AudioBooksApp.swift
OrbitAudioBooks.entitlements
Protocols/PlayerModelComponentProtocols.swift
Protocols/SettingsManagerProtocol.swift
Protocols/StoreManagerProtocol.swift
Services/ArtworkCache.swift
Services/AudioEngine.swift
Services/BookmarkStore.swift
Services/ChapterService.swift
Services/DeepLinkHandler.swift
Services/MockMediaProvider.swift
Services/NowPlayingController.swift
Services/Persistence.swift
Services/PlaybackController.swift
Services/PlaylistManager.swift
Services/RealTimeProjectionService.swift
Services/SecurityScopeManager.swift
Services/SettingsManager.swift
Services/SleepTimerManager.swift
Services/StoreManager.swift
Services/TimelineIngestionFactory.swift
Services/TimelineService.swift
Services/TranscriptService.swift
Services/WatchSyncManager.swift
State/PlaybackState.swift
Utilities/FolderPicker.swift
Utilities/ViewModifiers.swift
Utilities/WordFrequencyComputer.swift
ViewModels/PlayerModel.swift
ViewModels/TimelineFeedViewModel.swift
Views/Bookmarks.swift
Views/BottomToolbarView.swift
Views/ChapterTimeBlockView.swift
Views/Components/AlbumArtHeroView.swift
Views/Components/TranscriptOverlayView.swift
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
Views/NowPlayingTab.swift
Views/PlayerScrubberView.swift
Views/PlayheadLineView.swift
Views/PlaylistTimelineView.swift
Views/PlaylistView.swift
Views/RootTabView.swift
Views/SchedulingSheet.swift
Views/SettingsView.swift
Views/SmartRewindSettingsView.swift
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

## Orbit Audiobooks macOS

```
Info.plist
Orbit_Audiobooks_macOS.entitlements
Orbit_Audiobooks_macOSApp.swift
Views/MacContentView.swift
Views/MacPlayerModel.swift
Views/TranscriptionManager.swift
Views/TranscriptPane.swift
Views/TranscriptStore.swift
```

## Orbit Audiobooks Watch App

```
Info.plist
Models/WatchBookmark.swift
OrbitAudioBooksWatchApp.swift
Services/WatchViewModel.swift
Services/WatchVoiceMemoRecorder.swift
Views/Bookmarks.swift
Views/Components/ToggleTraitModifier.swift
Views/ContentView.swift
Views/PlayerPage.swift
Views/WatchControlBackground.swift
Views/WordCloudPage.swift
```

## Shared (cross-target)

```
AppGroupDefaults.swift
Database/BookmarkRecord.swift
Database/ChapterRecord.swift
Database/DAOs/AudiobookDAO.swift
Database/DAOs/BookmarkDAO.swift
Database/DAOs/ChapterDAO.swift
Database/DAOs/FlashcardDAO.swift
Database/DAOs/NoteDAO.swift
Database/DAOs/PlannedSessionDAO.swift
Database/DAOs/PlaybackEventDAO.swift
Database/DAOs/RealTimeEventDAO.swift
Database/DAOs/SettingsDAO.swift
Database/DAOs/TimelineDAO.swift
Database/DAOs/TrackDAO.swift
Database/DAOs/TranscriptionDAO.swift
Database/DatabaseService.swift
Database/Flashcard.swift
Database/MigrationService.swift
Database/NoteRecord.swift
Database/PlannedSessionRecord.swift
Database/RealTimeEventRecord.swift
Database/Schema_V1.swift
Database/Schema_V2.swift
Database/Schema_V3.swift
Database/Schema_V4.swift
Database/TimelineItem.swift
Database/TrackRecord.swift
Database/TranscriptionRecord.swift
Database/TranscriptionWord.swift
EnhancedTranscriptionSegment.swift
MediaPlayable.swift
SyncMarker.swift
TimeFormatting.swift
TranscriptionSegment.swift
WatchAction.swift
WordFrequency.swift
```

## Widget Extension

```
Info.plist
Models/AppIntent.swift
Views/Orbit_Audiobooks_Widget.swift
Views/Orbit_Audiobooks_WidgetBundle.swift
Views/Orbit_Audiobooks_WidgetControl.swift
```

## Tools & Pipeline

### EPUB-Audio Alignment Pipeline (`Tools/OrbitTranscriptionCLI/`)

The ingest pipeline separates heavy data processing from the client apps. Instead of the iOS/watchOS devices computing alignment at runtime, a Swift CLI tool pre-computes an "Enhanced Sync Map".

**The Pipeline Flow:**
1. **Audio → Whisper:** Audio file is transcribed to a standard Whisper JSON (contains words and timestamps).
2. **EPUB → Raw Text + Markers:** The EPUB is unzipped. `content.opf` dictates the reading order. `.xhtml` files are parsed into raw text, extracting structural markers for headings, images, blockquotes, and inline formatting.
3. **The Aligner (Sliding Window):** A hybrid sentence/word-level alignment algorithm slides the transcribed text across the EPUB text, using NLTokenizer for sentence splitting and Levenshtein distance for similarity scoring.
4. **Enhanced Sync Map Generation:** Once aligned, the structural markers from the EPUB are injected into the Whisper JSON timeline.
5. **Client Ingestion:** The Apple platforms read this pre-processed `EnhancedTranscript.json` to render images and headings at the correct playback timestamps.

**Subcommands:**
- `transcribe` (default): Audio → Whisper transcript JSON
- `align`: EPUB + transcript → Enhanced Sync Map JSON

**Key Types:**
- `EnhancedTranscriptionSegment`: Extended `TranscriptionSegment` with optional `markers: [SyncMarker]?` and `formatting: [TextFormat]?`
- `SyncMarker`: Structural element (`.chapterStart`, `.image`, `.blockquote`, etc.) with `payload` and `epubCharOffset`
- `TextFormat`: Inline formatting span (`.bold`, `.italic`, `.underline`) with character `range`

```
OrbitTranscriptionCLI (executable)
├── TranscribeCommand.swift        # Audio → Whisper transcript
├── AlignCommand.swift             # EPUB + transcript → Enhanced Sync Map
├── Models.swift                   # TranscriptionSegment, CLIWordFrequency
├── TranscriptionCLIEvent.swift    # JSON-line event emitter
│
OrbitEPUBAligner (library)
├── EPUBAlignmentPipeline.swift    # Orchestrator
├── EPUBParsing/
│   ├── EPUBUnpacker.swift         # ZIP extraction + mimetype validation
│   ├── OPFParser.swift            # content.opf → spine reading order
│   └── XHTMLParser.swift          # Tag stripping + marker/format extraction
├── Alignment/
│   ├── TextAlignmentService.swift # Protocol
│   ├── SlidingWindowAligner.swift # Hybrid sentence/word alignment
│   └── NLPProcessor.swift         # NLTokenizer wrapper
├── Markers/
│   └── MarkerInjector.swift       # Maps EPUB markers to audio timestamps
├── Models/                        # Data models
└── Utils/
    └── String+Levenshtein.swift   # Wagner-Fischer edit distance
```

### Dual-Path Timeline Feed (V4)

The timeline feed replaces the legacy `PlaylistTimelineView` with a performant, Twitter-style chronological feed. It supports two ingestion paths — **rich** (EPUB + transcription) and **sparse** (audio-only chapters) — rendered in a single unified scroll.

**V4 Schema: materialized `timeline_item` table**

Previously, the timeline was a SQL VIEW unioning rows from multiple normalized tables (`track`, `chapter`, `bookmark`, `flashcard`, etc.). While flexible, VIEWs cannot be indexed for range queries. V4 introduces a materialized `timeline_item` table that is a flattened copy of all feed-relevant data, with six purpose-built indexes:

| Index | Columns | Purpose |
|---|---|---|
| `idx_timeline_time_range` | audiobook_id, audio_start_time, audio_end_time | "What's playing at position X?" |
| `idx_timeline_epub_order` | audiobook_id, epub_sequence_index | Structural EPUB ordering |
| `idx_timeline_granularity` | audiobook_id, granularity_level | Chapter vs. sentence filtering |
| `idx_timeline_playlist` | audiobook_id, playlist_position, audio_start_time | Custom playlist reorder |
| `idx_timeline_source` | source_table, source_rowid | Back-link to normalized source rows |

**Dual-write synchronization:** When `BookmarkDAO` or `FlashcardDAO` creates, updates, or deletes a record, it also writes to `timeline_item` with the corresponding source tracking columns. This keeps the feed in sync without polling or triggers.

**V5 Schema: EPUB block alignment**

Schema_V5 introduces two new tables and extends `timeline_item` with alignment metadata:

| Table | Purpose |
|---|---|
| `epub_block` | Parsed EPUB structure — headings, paragraphs, sentences, images in reading order |
| `alignment_anchor` | User-created lock points tying EPUB blocks to audio timestamps |

New `timeline_item` columns: `epub_block_id`, `timestamp_source`, `alignment_status`, `alignment_confidence`.

Indexes: `idx_epub_block_sequence` (audiobook_id, sequence_index), `idx_epub_block_chapter` (audiobook_id, chapter_index), `idx_epub_block_hidden` (audiobook_id, is_hidden), `idx_alignment_anchor_time` (audiobook_id, audio_time), `idx_alignment_anchor_block` (audiobook_id, epub_block_id).

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
       ├── hideBlock / unhideBlock
       └── recalculateTimeline (linear interpolation between locked anchors)
```

**Ingestion strategies:**

```
TimelineIngestionFactory.strategy(hasTranscript:hasEnhancedTranscript:hasEPUB:)
├── EPUBBlockIngestionStrategy  ← EPUB blocks + anchors → V1 primary path
├── RichIngestionStrategy       ← EPUB + transcription → dense feed with text segments
└── SparseIngestionStrategy     ← audio-only → chapter markers with elastic scrubber gaps
```

**Feed UI architecture:**

```
TimelineTab
  └─ TimelineFeedCollectionView (UICollectionView via UIViewRepresentable)
       ├── 9 cell types: TextSegment, ChapterMarker, ImageAsset, Bookmark,
       │     AnkiCard, BookCard, ElasticScrubber (gap indicator), NowLine (playback position),
       │     StickyReviewHeader (supplementary view, pinned to top)
       └── NSDiffableDataSourceSnapshot<String> — identity from TimelineDisplayItem.id
            └─ TimelineFeedViewModel (@Observable, push-driven)
                 ├── FollowState: following → browsing (on user scroll) → following (5s tripwire or "Go to Now")
                 ├── Granularity: chapter-level above 1.5× speed, sentence-level otherwise
                 ├── Scope: .book → AudiobookDAO.all(), .chapter/.transcription → TimelineDAO.feedWindow
                 └── Data: [TimelineDisplayItem] wrapping audiobook cards, timeline items, nowLine, scrubberGap
```

**Key types in Shared/:**

- `TimelineDisplayItem` — Enum with 4 cases (`.audiobookCard`, `.timelineItem`, `.nowLine`, `.scrubberGap`) for heterogeneous feed content
- `TimelineItem` — `MutablePersistableRecord`, the materialized row with `GranularityLevel`
- `EnhancedTranscriptionSegment` — Whisper segment with optional `SyncMarker` array
- `SyncMarker` — EPUB structural marker (chapter start, image, blockquote, etc.)
- `MediaPlayable` — Protocol for timeline-renderable items (forward-looking for video)

### UI Architecture (2-Tab)

The iOS app uses a strict 2-tab layout managed by `RootTabView`:

```
RootTabView
├── Tab 0: NowPlayingTab   ← pure media consumption (album art, scrubber, transport)
└── Tab 1: TimelineTab     ← unified library + feed + planner + review
```

**NowPlayingTab** focuses entirely on active playback: `AlbumArtHeroView`, `PlayerScrubberView`, and `TransportControlsView`. It is strictly play/pause/scrubbing — all auxiliary controls (speed, sleep timer, bookmarks, loop mode, and library browsing) live in the Timeline's `DashboardShelf` and feed. The standalone `PlaylistView` sheet has been removed; bookmarks and playlist functionality are now integrated into the Timeline feed. Transcript overlays and voice memo playback are overlaid conditionally.

**TimelineTab** is the unified hub for all content browsing, library management, and annotation review:

```
TimelineTab
├── TimelineHeaderView        ← TimelineScope zoom control ("Library" / "Ch" / "Trans") + "Go to Now"
├── DashboardShelf            ← stats, speed, sleep timer, review count, progress, add bookmark
├── SpeedSuggestionBanner     ← real-time completion projection
├── dueReviewBanner           ← pending flashcard count with tap-to-review
└── TimelineFeedCollectionView ← UICollectionView-backed feed with heterogeneous TimelineDisplayItem types
```

### TimelineScope (Structural Zoom)

`TimelineScope` (formerly `TimeScale`) controls the feed's structural depth. The user cycles through three levels:

| Scope | Label | Data Source | Behavior |
|---|---|---|---|---|
| `.book` | "Library" | `AudiobookDAO.all()` | Shows all audiobooks in the user's library as `BookCardCell` items. Tapping a book loads it and switches to `.chapter` scope. Functions as the unified playlist/library browser. |
| `.chapter` | "Ch" | `TimelineDAO.feedWindow(granularity: .chapter)` | Chapter markers, bookmarks, and flashcards for the currently playing audiobook. Bookmarks appear inline at their timestamps. |
| `.transcription` | "Trans" | `TimelineDAO.feedWindow(granularity: .sentence)` | Individual transcript sentences, bookmarks, and image assets at full detail. Smooth auto-scroll follows the NowLine playhead. |

Contrast with `GranularityLevel` (database-side enum: `.chapter`, `.paragraph`, `.sentence`, `.word`) — `TimelineScope` is the user-facing zoom control, while `GranularityLevel` is the query-level filter that also auto-adjusts based on playback speed (>1.5× → chapter-level).

### Timeline Interaction Model

The feed uses a physical, audio-anchored interaction model:

| Gesture | Target | Action |
|---|---|---|
| **Tap** | Text segment / chapter marker / bookmark | Seek playhead to `item.audioStartTime` |
| **Tap** | Audiobook card (`.book` scope) | Load the selected audiobook and switch to `.chapter` scope |
| **Tap** | Image asset | Open image in system viewer |
| **Tap** | Anki card | Launch flashcard review session |
| **Long press** | Bookmark item | Context menu with "Edit" and "Delete" actions |
| **Long press** | Other feed item | Context menu with "Edit" action |

**Now Line demarcation:** The feed is split at the current playback position by a visible `NowLineCell` — a red divider line with a "NOW" label that renders between history and future items. Items *above* (before) the playhead represent history — listened segments, completed reviews — and render at reduced opacity (0.65). Items *below* (after) the playhead represent future content at full opacity. The active item (whose time range contains `currentPosition`) is highlighted with a blue leading bar.

**Follow state & smooth scrolling:** The feed auto-scrolls to track playback ("following") using `CADisplayLink`-driven interpolation. Each frame, the content offset eases 15% closer to the target position where the NowLine is centered in the viewport. When the user manually scrolls, the display link disengages and follow mode is suspended. A "Go to Now" floating button appears, and a 5-second tripwire re-engages follow mode if the user stops scrolling.

### Sticky Anki Reviews

Due Anki flashcards appear sequentially inline in the Timeline feed at their source timestamp (the moment in the audiobook where the card was created, or a scheduled review time). Their behavior is **sticky**:

- When a due card is visible in the viewport, it "pins" to the top of the feed via a `StickyReviewHeaderView` — a `UICollectionReusableView` registered as a section header with `pinToVisibleBounds = true`.
- The sticky header shows the card's front/back text with 6 grade buttons (0–5) and a dismiss button.
- The header is bound to the first due `TimelineItem` (itemType `.ankiCard`) in the visible range via `dueAnkiCard` on the `TimelineFeedCollectionView`.
- Once reviewed, the card transitions to a completed state and the sticky header hides (height collapses to zero).
- If multiple cards are due at the same timestamp, they stack sequentially in the sticky header.

This design ensures reviews never scroll out of sight — they demand attention at the moment of consumption, mirroring the physical experience of a bookmark or note flagging a page.

### Timeline Structural Zoom (3 Levels)

The Timeline feed operates at three levels of structural depth, controlled by `TimelineScope`:

| Level | Scope Case | Content Displayed | Use Case |
|---|---|---|---|
| **Library** | `.book` | All audiobooks in the user's library as `BookCardCell` items with cover placeholder, title, author, and duration | Browsing the full library, switching between books (unified playlist) |
| **Chapter** | `.chapter` | Chapter markers, bookmarks, and flashcards for the current audiobook | Navigating chapters, reviewing bookmarks inline |
| **Transcription** (Sentence) | `.transcription` | Individual transcript sentences with word-level timestamps; bookmarks and images inline | Following along word-by-word, precise seeking, detailed review |

The user cycles through these levels with the `TimelineHeaderView` cycle button. `GranularityLevel` (the database query filter) auto-adjusts based on playback speed — above 1.5× it switches to `.chapter` to reduce visual noise at high speed.

### Unified Timeline Paradigm

The app now uses a **Unified Timeline Paradigm** where all content browsing, library management, and annotation review happens in a single feed:

**`TimelineDisplayItem` enum**: The feed renders heterogeneous item types from a single `[TimelineDisplayItem]` array. This replaces the previous ad-hoc system of `[TimelineItem]` + string-identified gap/nowline sentinels.

| Case | Source | Cell Type |
|---|---|---|
| `.audiobookCard(AudiobookCardInfo)` | `AudiobookDAO.all()` → view model | `BookCardCell` |
| `.timelineItem(TimelineItem)` | `TimelineDAO` queries | `TextSegmentCell`, `ChapterMarkerCell`, `BookmarkCell`, `AnkiCardCell`, `ImageAssetCell` |
| `.nowLine` | Inserted at current position boundary | `NowLineCell` |
| `.scrubberGap(TimeInterval, String)` | Inserted for gaps > 60s | `ElasticScrubberCell` |

**Bookmark lifecycle**: Bookmarks created via `BottomToolbarView.addBookmarkButton` flow through `BookmarkStore.appendBookmark` → `BookmarkDAO.syncToTimeline` → `timeline_item` table. The `.bookmarksDidChange` notification triggers a feed refresh in `TimelineTab`, ensuring bookmarks appear inline immediately.

**Playlist migration**: The standalone `PlaylistView` sheet and `BottomToolbarView.playlistButton` have been removed. Browsing and selecting audiobooks now happens at `.book` scope in the Timeline feed.

### EPUB-to-Audio Data Model: Handling Mismatches

The NLP alignment pipeline (`OrbitEPUBAligner`) compares the EPUB spine text against Whisper transcript JSON. When the EPUB contains content that has **no corresponding audio** — images, footnotes, skipped prose, tables, blockquotes — the pipeline preserves it rather than discarding it.

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

