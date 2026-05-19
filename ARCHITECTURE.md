# Architecture Overview

<!-- ⚠️  AUTO-GENERATED — do not edit directly. -->
<!-- Regenerate with: `make architecture`                        -->

**Last generated:** 2026-05-18 08:54:53

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
Models/TimelineGroup.swift
Models/TimeScale.swift
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
Services/TimelineService.swift
Services/TranscriptService.swift
Services/WatchSyncManager.swift
State/PlaybackState.swift
Utilities/FolderPicker.swift
Utilities/ViewModifiers.swift
Utilities/WordFrequencyComputer.swift
ViewModels/PlayerModel.swift
Views/Bookmarks.swift
Views/BottomToolbarView.swift
Views/ChapterTimeBlockView.swift
Views/Components/AlbumArtHeroView.swift
Views/Components/TranscriptOverlayView.swift
Views/Components/WordCloudView.swift
Views/ContentCardEditor.swift
Views/ContentView.swift
Views/DashboardShelf.swift
Views/FlashcardReviewCard.swift
Views/FlashcardReviewSession.swift
Views/HelpContent.swift
Views/HelpView.swift
Views/LibraryTab.swift
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
Database/TimelineItem.swift
Database/TrackRecord.swift
Database/TranscriptionRecord.swift
Database/TranscriptionWord.swift
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

---

## Dual-Path Timeline Feed

The "Twitter-style" scrolling feed is the universal interface for consuming content. It handles two distinct scenarios through a single unified `TimelineItem` schema.

### Dense vs. Sparse Feeds

| | **Dense Feed** | **Sparse Feed** |
|---|---|---|
| **Data source** | EPUB text aligned to Whisper timestamps | M4B chapter markers + user content |
| **Item density** | Hundreds/thousands of `textSegment`s, 5–30s apart | A handful of items, potentially 45+ min apart |
| **Text content** | Full paragraph text from EPUB | Chapter titles, bookmark notes, flashcard text |
| **Images** | From EPUB `<img>` tags in XHTML | From M4B embedded chapter artwork |
| **EPUB references** | Present (`epubReference` + `epubSequenceIndex`) | `nil` — no EPUB exists |

Both feeds use the same `TimelineItem` struct, the same `timeline` VIEW, and the same SwiftUI feed view. The difference is purely in *which optional fields are populated* and *how densely items are spaced in time*.

### Unified `TimelineItem` Schema (V4)

**`TimelineItemType` enum:**
`track`, `chapterMarker`, `bookmark`, `ankiCard`, `textSegment`, `note`, `imageAsset`

**Key fields:**

| Field | Type | Purpose |
|---|---|---|
| `audioStartTime` | `TimeInterval` | When the item begins in the audio timeline |
| `audioEndTime` | `TimeInterval?` | When it ends (`nil` for point-in-time items like bookmarks) |
| `textPayload` | `String?` | Full text body (paragraphs for `textSegment`, answer for `ankiCard`, note for `bookmark`) |
| `imagePath` | `String?` | Local path to image asset (populated for `imageAsset`, chapter artwork) |
| `epubReference` | `String?` | EPUB locator (e.g. `"ch3/para42"`). `nil` for audio-only items |
| `epubSequenceIndex` | `Int?` | Monotonic ordering from EPUB spine. Provides stable sort when timestamps overlap |

**Schema migration** (`Schema_V4`):
- New `image_asset` table for embedded artwork and EPUB images
- `epub_reference` and `image_path` columns added to `chapter`
- `epub_reference` and `epub_sequence_index` columns added to `transcription_segment`
- `timeline` VIEW recreated with renamed `item_type` values and new columns

**Sort order:** `playlist_position` (user override) → `audio_start_time` (temporal) → `epub_sequence_index` (structural). The structural sort ensures text renders in correct EPUB reading order even when Whisper timestamps are noisy or overlapping.

### Sparse Audio-Only Feed Example

A 3-chapter M4B with no EPUB produces a feed like:

```
chapterMarker  "Introduction"   0:00 → 45:00
chapterMarker  "Main Content"   45:00 → 1:45:00
bookmark       "Key insight"    52:30
ankiCard       "Define X?"      1:02:00
chapterMarker  "Conclusion"     1:45:00 → 2:30:00
```

The large gaps between items (e.g., 45 minutes between chapters) are rendered in the UI as proportional vertical whitespace with a moving playhead indicator (see Phase 3).

### Ingestion Strategies (Phase 2)

An `IngestionStrategy` factory generates `TimelineItem` rows based on available assets:
- **Strategy A (Rich):** EPUB + Whisper JSON → dense text-heavy feed with EPUB references
- **Strategy B (Audio-Only):** M4B only → sparse feed from chapter markers and artwork
- **Graceful Degradation:** If alignment confidence drops below threshold, text segments are stored without timestamps and rendered as a "read-along" companion rather than an auto-scrolling feed

