# Architecture Overview

<!-- ⚠️  AUTO-GENERATED — do not edit directly. -->
<!-- Regenerate with: `make architecture`                        -->

**Last generated:** 2026-06-09 21:34:26

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
Development Assets/aliceinwonderland_1102_librivox/Alice's Adventures in Wonderland.epub
EchoCore.entitlements
EchoCoreApp.swift
Info.plist
Localizable.xcstrings
Models/AggregatedChapter.swift
Models/Chapter.swift
Models/ChapterSection.swift
Models/ContentCard.swift
Models/EchoPlaylistManifest.swift
Models/FlashcardDeckImport.swift
Models/M4BBook.swift
Models/Note.swift
Models/PlayerDeepLink.swift
Models/ReaderCardItem.swift
Models/RealTimeEvent.swift
Models/SpeedSuggestion.swift
Models/TimelineDisplayItem.swift
Models/TimelineGroup.swift
Models/TimelineScope.swift
Models/Track.swift
PrivacyInfo.xcprivacy
Protocols/PlayerModelComponentProtocols.swift
Protocols/SettingsManagerProtocol.swift
Protocols/StoreManagerProtocol.swift
Services/AccentSafetyNet.swift
Services/AlignmentService.swift
Services/ArtworkCache.swift
Services/AudioEngine.swift
Services/AudioRingBuffer.swift
Services/AudioSnippetPlayer.swift
Services/AutoAlignmentService.swift
Services/AutoAlignmentState.swift
Services/AutoAlignmentTextMatcher.swift
Services/BookmarkArtworkCoordinator.swift
Services/BookmarkStore.swift
Services/BookPreferencesService.swift
Services/BookSettingsOverrideStore.swift
Services/ChapterGroupingService.swift
Services/ChapterLoadingCoordinator.swift
Services/ChapterService.swift
Services/ChapterTitleMatcher.swift
Services/CloudKitSyncService.swift
Services/ContinuousAlignmentService.swift
Services/DeckImportService.swift
Services/DeepLinkHandler.swift
Services/DominantColorExtractor.swift
Services/EPUBAssetStorage.swift
Services/EPUBAutoImportScanner.swift
Services/EPUBHeuristicEngine.swift
Services/EPUBImportCoordinator.swift
Services/EPUBImportService.swift
Services/InlineFlashcardTriggerController.swift
Services/LoopMode.swift
Services/M4BParser.swift
Services/MockMediaProvider.swift
Services/ModelRetainBox.swift
Services/NotificationNames.swift
Services/NowPlayingController.swift
Services/PDFImportCoordinator.swift
Services/Persistence.swift
Services/PlaybackController.swift
Services/PlaybackEventLogger.swift
Services/PlaybackProgressPresenter.swift
Services/PlaybackTimelineService.swift
Services/PlayerLoadingCoordinator.swift
Services/PlayerTimelinePersistenceService.swift
Services/PlaylistManager.swift
Services/PlaylistManifestService.swift
Services/ReviewNotificationService.swift
Services/SecurityScopeManager.swift
Services/SettingsManager.swift
Services/SilenceDetectionService.swift
Services/SleepTimerManager.swift
Services/SleepTimerMode.swift
Services/SnippetPlayer.swift
Services/StoreManager.swift
Services/TimelineIngestionFactory.swift
Services/TimelineIngestionService.swift
Services/TimelineService.swift
Services/TokenDTW.swift
Services/TranscriptService.swift
Services/WatchCommandRouter.swift
Services/WatchConnectivityCoordinator.swift
Services/WatchStateContextBuilder.swift
Services/WatchSyncManager.swift
Services/WhisperSession.swift
State/PlaybackState.swift
Utilities/ColorMetrics.swift
Utilities/FolderPicker.swift
Utilities/SilenceAnalyzer.swift
Utilities/UIImage+Color.swift
Utilities/ViewModifiers.swift
Utilities/WordFrequencyComputer.swift
ViewModels/DailyReviewViewModel.swift
ViewModels/PlayerModel.swift
ViewModels/PlayerModel+Bookmarks.swift
ViewModels/PlayerModel+PlaybackControllerDelegate.swift
ViewModels/PlayerModel+PlaybackLogging.swift
ViewModels/PlayerModel+WatchState.swift
ViewModels/ReaderFeedViewModel.swift
ViewModels/TimelineFeedViewModel.swift
Views/AudiobookPlayerUIArchitect.swift
Views/AutoAlignmentProgressView.swift
Views/BookmarkCardView.swift
Views/Bookmarks.swift
Views/BookSettingsView.swift
Views/BottomToolbarView.swift
Views/CardColorPickerSheet.swift
Views/Cells/AnkiCardCell.swift
Views/Cells/BookCardCell.swift
Views/Cells/BookmarkCell.swift
Views/Cells/CellHelpers.swift
Views/Cells/ChapterMarkerCell.swift
Views/Cells/ElasticScrubberCell.swift
Views/Cells/HeadingCardCell.swift
Views/Cells/ImageAssetCell.swift
Views/Cells/ImageCardCell.swift
Views/Cells/NowLineCell.swift
Views/Cells/ParagraphCardCell.swift
Views/Cells/StickyReviewHeaderView.swift
Views/Cells/TextSegmentCell.swift
Views/Cells/TimelineCellDelegate.swift
Views/ChapterPickerSheet.swift
Views/ChapterTimeBlockView.swift
Views/Components/AdaptiveBackground.swift
Views/Components/AlbumArtHeroView.swift
Views/Components/CircularProgressPlayButton.swift
Views/Components/FlashcardCreationSheet.swift
Views/Components/FlashcardOverlayView.swift
Views/Components/Haptic.swift
Views/Components/InlineStepperRow.swift
Views/Components/MarqueeText.swift
Views/Components/PlayerControlBar.swift
Views/Components/TranscriptOverlayView.swift
Views/Components/TranscriptRowView.swift
Views/Components/UnifiedBottomDock.swift
Views/Components/UnifiedTopHeader.swift
Views/Components/WordCloudView.swift
Views/ContentCardEditor.swift
Views/DashboardShelf.swift
Views/EPUBHeadingPickerSheet.swift
Views/FlashcardReviewCard.swift
Views/FlashcardReviewSession.swift
Views/HelpContent.swift
Views/HelpView.swift
Views/ListeningProgressModuleView.swift
Views/ManualAlignmentSheet.swift
Views/NoteEditorView.swift
Views/NowLineView.swift
Views/NowPlayingLayout.swift
Views/NowPlayingTab.swift
Views/PDFDocumentView.swift
Views/PhonePlayerSettingsView.swift
Views/PlayerScrubberView.swift
Views/PlayheadLineView.swift
Views/PlaylistTimelineView.swift
Views/PlaylistView.swift
Views/ReaderEmptyState.swift
Views/ReaderFeedCollectionView.swift
Views/ReaderHeaderView.swift
Views/ReaderSettingsSheet.swift
Views/ReaderTab.swift
Views/ReaderTab+Alignment.swift
Views/RootTabView.swift
Views/ScrubberJoystick.swift
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
Views/TransportControlsView+LongPress.swift
Views/UpcomingReviewsModuleView.swift
Views/VoiceMemoOverlayView.swift
Views/WatchAppSettingsView.swift
```

## Echo macOS

```
Echo_macOS.entitlements
Echo_macOSApp.swift
Info.plist
PrivacyInfo.xcprivacy
Services/AudioExtractor.swift
Services/MacEPUBParser.swift
Services/MacGlobalAlignmentService.swift
Views/MacContentView.swift
Views/MacPlayerModel.swift
Views/TranscriptionManager.swift
Views/TranscriptPane.swift
Views/TranscriptStore.swift
```

## Echo Watch App

```
EchoCoreWatchApp.swift
Info.plist
Models/WatchBookmark.swift
PrivacyInfo.xcprivacy
Services/WatchViewModel.swift
Services/WatchVoiceMemoRecorder.swift
Views/Bookmarks.swift
Views/Components/PomodoroButton.swift
Views/Components/ToggleTraitModifier.swift
Views/ContentView.swift
Views/PlayerPage.swift
Views/PomodoroTimerPickerView.swift
Views/WatchControlBackground.swift
Views/WatchReviewView.swift
```

## Shared (cross-target)

```
AnimationDurations.swift
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
Database/Migrations/Schema_V11.swift
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
Database/Schema_V9.swift
Database/TimelineItem.swift
Database/TrackRecord.swift
Database/TranscriptionRecord.swift
Database/TranscriptionWord.swift
EnhancedTranscriptionSegment.swift
EPUBXMLParsing.swift
FileLocations.swift
KeychainStore.swift
LayoutPreset.swift
Logger+Subsystem.swift
MediaPlayable.swift
Models/PDFViewState.swift
ReaderSettings.swift
SafeFileName.swift
String+Levenshtein.swift
SyncMarker.swift
TabSelection.swift
TimeFormatting.swift
TranscriptionSegment.swift
URL+SHA256.swift
WatchAction.swift
WatchFlashcard.swift
WordFrequency.swift
```

## Echo Widget

```
Info.plist
Models/AppIntent.swift
PrivacyInfo.xcprivacy
Views/Echo_Widget.swift
Views/Echo_WidgetBundle.swift
Views/Echo_WidgetControl.swift
```


<!-- MANUAL BELOW -->

## Tools & Pipeline

### EPUB-Audio Alignment (In-App)

> **Note:** The earlier `EchoTranscriptionCLI` tool (Swift CLI + Python/Whisper pipeline) has been **abandoned and removed**. It is not part of the current user workflow.

Alignment is now performed entirely in-app, without any external tools or API calls:

1. **EPUB Import:** When the user adds an EPUB file alongside their audiobook, `EPUBImportService` parses it into `epub_block` records (headings, paragraphs, images) stored in the database.
2. **Auto-Alignment (4-tier pipeline, on-device):** `AutoAlignmentService` runs a progressive 4-tier pipeline using on-device speech recognition (WhisperKit + CoreML) and dynamic time warping (TokenDTW) to automatically align EPUB blocks to audio timestamps:
   - **Tier 0 — Metadata Title Matching:** `ChapterTitleMatcher` compares audiobook chapter titles (from M4B metadata) to EPUB heading blocks using composite Levenshtein + Jaccard fuzzy scoring. High-confidence matches (≥0.85) create immediate anchors and skip DTW entirely for those chapters.
   - **Tier 1 — VAD Chunking + DTW:** For chapters not matched in Tier 0, uses `SilenceDetectionService` to split audio into VAD-guided chunks, transcribes each with WhisperKit, then `TokenDTW.align()` matches transcribed audio tokens against EPUB tokens at word-level granularity to insert correction anchors.
   - **Tier 2 — Drift Detection:** Compares interpolated block positions against chapter boundaries to detect chapters that have drifted out of alignment (planned).
   - **Tier 3 — Drift Repair:** Bisects flagged chapters to locate the drift point and inserts correction anchors (planned).
   - **Fine-Tuning:** `fineTuneManualAlignment(blockID:around:)` captures a 10s window (±5s) around a user-specified time and returns a refined timestamp for manual alignment improvements.
3. **Global flat interpolation:** `AlignmentService.recalculateTimeline()` uses dynamic CPS (characters-per-second) computed from existing locked anchors to project synthetic boundary positions, rather than hardcoding time 0.0 and total duration. This produces more accurate extrapolation when anchors exist near but not at the book's edges.
4. **Manual refinement:** The user long-presses any card in the Reader and chooses "Align to Now", "Align to 5s Ago", "Align to Chapter Start", or "Align to Chapter End" to lock that block to a specific timestamp. Each locked anchor improves the accuracy of neighboring blocks through proportional interpolation.
5. **Timeline recalculation:** `AlignmentService.recalculateTimeline()` runs in a single DB transaction, updating all affected `timeline_item` rows with new interpolated timestamps, including `audioEndTime` computed from the next visible block's start time.
6. **Block/chapter hiding:** Users can mark individual blocks ("Not in Audio (This Paragraph)") or entire chapters ("Not in Audio (Whole Chapter)") as hidden when the EPUB contains content not present in the audiobook narration. Hidden blocks get `alignment_status = omitted`, `is_enabled = false`. The `hideChapter(chapterIndex:reason:)` method on `AlignmentService` batch-hides all blocks in a chapter.
7. **Continuous Alignment:** `ContinuousAlignmentService` (opt-in via `continuousAutoAlignmentEnabled` setting) runs background transcription during playback to detect and repair alignment drift in real time.
8. **CloudKit Sync:** `CloudKitSyncService` synchronizes alignment anchors across devices via CloudKit, ensuring manual and auto-alignment work is shared.

**Dynamic CPS projection (AlignmentService):**

Synthetic anchor placement now uses the average speaking rate derived from existing locked anchors rather than assuming the book starts at 0.0 and ends at `totalDuration`:

1. When ≥2 anchored blocks exist, compute `averageCPS = totalChars / totalTime` from the word-position distances and time deltas between them.
2. Project the first block's time backward from the first locked anchor: `firstTime = anchorTime − (wordDistance / averageCPS)`, clamped to ≥0.
3. Project the last block's time forward from the last locked anchor: `lastTime = anchorTime + (wordDistance / averageCPS)`, clamped to ≤totalDuration.
4. Falls back to 15 CPS (~155 WPM) when fewer than 2 anchors exist.

**Word-count proportional interpolation (Schema V8):**

Earlier alignment used sequence-index-based linear interpolation, which assumed uniform spacing between blocks. Schema V8 introduces `word_count` on `epub_block` to weight block positions proportionally by content length. The current algorithm:

1. Computes a cumulative `wordPosition` for each block (running sum of word counts, placing each block at its proportional start position within the book). Hidden blocks and image blocks receive weight 0.0 so they don't skew interpolation.
2. Synthetic anchor points are placed at the first block (time 0.0) and last block (total duration from the last chapter marker's end time), ensuring the entire book is bounded.
3. Interpolation fraction = `(blockPos − prevPos) / (nextPos − prevPos)` using word positions between any two bracketing anchors (locked or synthetic).
4. This produces smooth timestamp estimates for uneven paragraph lengths (e.g., long prose followed by short dialogue) without requiring chapter boundary data.

**Key types:**

- `AlignmentService` — Creates anchors and recalculates timeline via word-count-weighted proportional interpolation between locked and synthetic boundary anchors. Uses dynamic CPS projection for synthetic boundary placement. Supports `eraseAnchor(blockID:)`, `resetAlignment()`, `hideBlock(blockID:reason:)`, `hideChapter(chapterIndex:reason:)`, and `anchorChapterEnd(blockID:chapterIndex:time:)` for anchor and content management.
- `ChapterTitleMatcher` — Tier 0 metadata-based matcher that compares audiobook chapter titles (from M4B metadata) to EPUB headings using composite Levenshtein + Jaccard fuzzy scoring. Runs before any ML model loading — high-confidence matches (≥0.85) create anchors immediately and skip DTW transcription for those chapters.
- `AutoAlignmentService` — Progressive 4-tier WhisperKit-based auto-alignment orchestrator. Runs Tier 0 (metadata title matching), Tier 1 (VAD chunking + TokenDTW), Tier 2 (drift detection), Tier 3 (drift repair), and manual fine-tuning. Reports progress via `AutoAlignmentState` for UI binding.
- `AutoAlignmentTextMatcher` — Fuzzy text matching engine for auto-alignment. Uses Levenshtein distance and word-level Jaccard similarity to match transcribed audio against EPUB paragraphs. Provides `projectedBlockStart()` for time-offset calculation from match position within a block.
- `TokenDTW` — Dynamic Time Warping aligner that matches EPUB tokens against audio transcription tokens at word-level granularity. Uses flat `Int32` cost and `Int8` direction arrays for memory-efficient alignment (Levenshtein-like fuzzy matching with prefix/suffix matching). Replaces the earlier Tier 0 silence-mapping approach with precise token-level alignment for drift repair (Tier 3).
- `SilenceDetectionService` — Scans audio files for silence gaps using `AVAudioFile` + `Accelerate` buffer processing. Returns `[SilenceGap]` (start/end/duration). Retained for potential future use; no longer part of the active auto-alignment pipeline.
- `ContinuousAlignmentService` — Background alignment drift detection during playback. Samples 15-second audio windows, transcribes via WhisperKit, and inserts alignment anchors on-the-fly. Uses a re-entry guard to prevent overlapping transcription tasks. Opt-in via `continuousAutoAlignmentEnabled` setting. Uses single-pass O(N) timeline scan instead of O(N log N) sort to prevent main-thread stalls every 15 seconds.
- `WhisperSession` — Reference-counted, shared WhisperKit model manager (`@MainActor`). Prevents duplicate ~40 MB model loads when both `AutoAlignmentService` and `ContinuousAlignmentService` are active. Uses `acquire(model:)` / `release()` / `forceUnload()` lifecycle.
- `AudioSnippetPlayer` — Lightweight, single-use audio player for voice-memo previews and bookmark playback. Eliminates the ad-hoc `AVAudioEngine` setup previously duplicated across `BookmarkStore`, `Bookmarks`, and `SnippetPlayer`.
- `CloudKitSyncService` — Cross-device alignment anchor synchronization via CloudKit. Uses deterministic SHA-256 record names instead of `hashValue` for cross-device record matching. Uses `NSNumber`-based predicates to avoid floating-point precision loss.
- `MacGlobalAlignmentService` — macOS-specific streaming alignment orchestrator with EPUB picker UI and match threshold slider. Shares `WhisperSession` with iOS services. Precomputes word arrays to avoid per-sliding-window allocations.
- `AlignmentAnchorRecord` — A user-created or auto-generated lock point tying an EPUB block to an audio time. Includes `anchorKind` (chapterStart/chapterEnd/correction) and `source` (manual/auto/imported).
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
| V9 | `markers` (TEXT) and `text_formats` (TEXT) columns on `epub_block` — stores JSON-encoded `[SyncMarker]` and `[TextFormat]` arrays extracted during unified EPUB parsing for richer reader display |
| V11 | `pdf_view_state_json` (TEXT) columns on `bookmark` and `timeline_item` — persists PDF page/zoom/scroll state for PDF bookmarks and alignment anchors |

Key indexes: `idx_epub_block_sequence` (audiobook_id, sequence_index), `idx_epub_block_chapter` (audiobook_id, chapter_index), `idx_epub_block_hidden` (audiobook_id, is_hidden), `idx_alignment_anchor_time` (audiobook_id, audio_time), `idx_alignment_anchor_block` (audiobook_id, epub_block_id).

**Alignment pipeline:**

```
EPUB (directory or .epub file)
  └─ EPUBImportService
       ├── Parse container.xml → OPF spine order
       ├── Parse XHTML → paragraph-level blocks
       ├── Copy images → Application Support/EPUBAssets/<safeAudiobookID>/
       └── Write epub_block records → SQL

Auto-alignment (4-tier pipeline, on-device)
  └─ AutoAlignmentService
       ├── Tier 0: ChapterTitleMatcher.matchChapterTitles() → title → heading anchors (microseconds, no ML)
       ├── Tier 1: SilenceDetectionService → captureAndTranscribe → TokenDTW.align() → word-level DTW anchors
       ├── Tier 2: compare interpolated positions → flag drifted chapters (planned)
       ├── Tier 3: bisect flagged chapters → insert correction anchors (planned)
       └── fineTuneManualAlignment(blockID:around:) → refine manual anchor time

User anchors (manual)
  └─ AlignmentService
       ├── moveBlockToCurrentTime / anchorSearchResult / anchorChapterStart/End
       ├── eraseAnchor(blockID:) / resetAlignment()
       ├── hideBlock(blockID:reason:) / unhideBlock(blockID:)
       ├── hideChapter(chapterIndex:reason:)   ← batch chapter hide
       └── recalculateTimeline (word-count-weighted interpolation + dynamic CPS projection)

Code organization (June 2026):
  ├─ TokenDTW: new word-level DTW alignment engine replacing Tier 0 silence mapping
  │   └── Uses flat Int32/Int8 arrays for memory-efficient 3000×3000 token grid alignment
  ├─ TimelineFeedCollectionView: 1,825 → 627 lines — 11 cell subclasses
  │   extracted to Views/Cells/ (BookCardCell, TextSegmentCell, ChapterMarkerCell,
  │   BookmarkCell, AnkiCardCell, ImageAssetCell, NowLineCell, ElasticScrubberCell,
  │   StickyReviewHeaderView, TimelineCellDelegate, CellHelpers)
  ├─ ReaderTab: 901 → 576 lines — alignment & context menu operations
  │   extracted to ReaderTab+Alignment.swift
  ├─ PlayerModel: 1,295 → 1,103 lines — Bookmarks API extracted to
  │   PlayerModel+Bookmarks.swift
  ├─ EPUB XML parsing: ~190 lines of duplicated delegates per platform
  │   consolidated into Shared/EPUBXMLParsing.swift
  └─ New shared utilities: FileLocations, KeychainStore, Logger+Subsystem,
      AnimationDurations, WhisperSession, AudioSnippetPlayer

Continuous alignment (opt-in)
  └─ ContinuousAlignmentService
       └── Background drift detection during playback

CloudKit Sync
  └─ CloudKitSyncService
       └── Cross-device anchor synchronization
```

**Reader UI architecture:**

```
ReaderTab (SwiftUI)
  ├── ReaderHeaderView          ← search bar ("Find in book..."), scroll-to-active button, TOC button, settings button
  ├── Part/Chapter/Section title bar ← three-level sticky context (part → chapter → section)
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

### PDF Companion Document Support (June 2026)

When a PDF file is placed alongside an audiobook (alongside or instead of an EPUB), Echo provides a PDF reader with per-page alignment and bookmarking:

```
PDF in audiobook folder
  └─ PDFImportCoordinator
       └── Copies PDF into the audiobook folder (same-folder imports are no-ops)

PDFDocumentView (SwiftUI)
  ├── PDFKitView (UIViewRepresentable wrapping PDFKit.PDFView)
  │    ├── Single-page continuous vertical scroll mode
  │    ├── Auto-scales to fit width
  │    ├── Tracks page, zoom, and scroll offset as PDFViewState
  │    └── Long-press gesture → alignment/bookmark context menu
  ├── Confirmation dialog: Align to Now / Align to Specific Time / Create Bookmark
  ├── ManualAlignmentSheet → fine-tune alignment with scrubber joystick
  └── Screenshot capture: renders current PDF page to JPEG for bookmark images

PDFViewState (Codable, Equatable, Hashable)
  ├── pageIndex: Int       ← which page is visible
  ├── zoomScale: Double    ← current magnification
  ├── offsetX: Double      ← horizontal scroll offset in page coordinates
  └── offsetY: Double      ← vertical scroll offset in page coordinates

Bookmark persistence (Schema V11):
  ├── bookmark.pdf_view_state_json  ← JSON-encoded PDFViewState
  └── timeline_item.pdf_view_state_json ← same for alignment anchors
```

**Key types:**
- `PDFDocumentView` — SwiftUI view that loads and displays a PDF from the audiobook folder, with long-press context menu for alignment and bookmarking.
- `PDFKitView` — `UIViewRepresentable` wrapping `PDFKit.PDFView` with `PDFViewPageChanged`/`PDFViewScaleChanged`/`PDFViewVisiblePagesChanged` notification observers for state tracking.
- `PDFViewState` — Codable model capturing page index, zoom scale, and scroll offset for bookmark restoration.
- `PDFImportCoordinator` — Stateless enum that copies a PDF into the target audiobook folder (security-scoped), skipping the copy when source and destination are the same file.
- `ManualAlignmentSheet` — Modal sheet for fine-tuning PDF/audio alignment with play/pause, ±5s skip, a `ScrubberJoystick` for variable-speed scrubbing (exponential mapping), and audio snippet preview during scrub.
- `ScrubberJoystick` — Horizontal drag-track control with a spring-returning knob. Maps drag offset to a -1.0…1.0 value with exponential mapping (small pulls = slow, big pulls = fast) for precise scrubbing.

**Reader tab routing:** `RootTabView` checks `model.hasPDF` when `model.hasEPUB` is false, routing to `PDFDocumentView` instead of `ReaderEmptyState`.

### Hierarchical Chapter Titles (June 2026)

`PlaylistView.computeHierarchicalTitles(for:)` detects parent-child relationships between consecutive chapter titles using prefix matching, then formats nested chapters with leading dots (e.g., "Part 1", ".Chapter 1", "..Section A"). This makes Libation-style sub-section hierarchies and multi-level EPUB structures visually scannable in the playlist without requiring explicit part/section metadata.

### Reader Tab Header Hierarchy (June 2026)

The Reader tab's sticky header now displays a three-level hierarchy: **Part** (`.headline`, primary) → **Chapter** (`.headline` or `.subheadline`, primary or secondary) → **Section** (`.caption`, secondary). When a part title exists, the chapter title renders smaller and in secondary color, creating visual depth. The `ReaderFeedCollectionView` receives a `$topPartTitle` binding alongside the existing `$topChapterTitle` and `$topSectionTitle`.

### UI Architecture (3-Tab)

The iOS app uses a 3-tab layout managed by `RootTabView`:

```
RootTabView
├── Tab 0: NowPlayingTab   ← pure media consumption (album art, scrubber, transport)
├── Tab 1: ReaderTab        ← EPUB reader with search, alignment, and TOC (when EPUB is loaded)
│                             falls back to PDFDocumentView (when PDF is loaded, no EPUB)
│                             falls back to ReaderEmptyState (no companion document)
└── Tab 2: TimelineTab      ← playlist, track/chapter list, bookmarks
```

**NowPlayingTab** focuses entirely on active playback: `AlbumArtHeroView`, `PlayerScrubberView`, and `TransportControlsView`. It is strictly play/pause/scrubbing — all auxiliary controls (speed, sleep timer, bookmarks, loop mode) live in the `BottomToolbarView` and `DashboardShelf`.

**ReaderTab** (available when `model.hasEPUB` is true; `model.hasPDF` provides a `PDFDocumentView` fallback) is the EPUB-backed reading surface. It renders the book as a feed of styled cards — headings, paragraphs, and images — aligned to the audio playback position. The header auto-hides on scroll-down and reveals on scroll-up. It includes:
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

`PlayerModel` has been decomposed from a ~2,900-line god class into a thin coordinator (~1,100 lines) that owns and wires together 20+ focused services. The Bookmarks API (~190 lines) has been extracted to `PlayerModel+Bookmarks.swift`, following the same extension-file pattern as `PlayerModel+PlaybackControllerDelegate.swift`, `PlayerModel+PlaybackLogging.swift`, and `PlayerModel+WatchState.swift`. Each service has a single responsibility:

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

**Watch page layout:** The watch app supports up to 5 customizable pages of action slots (25 total), synced from the phone via `SettingsManager.watchPage1` through `watchPage5` App Group keys. Pages whose slots are all `.empty` are automatically hidden from the watch `TabView`. Configuration is managed in `WatchAppSettingsView` using a swipeable `TabView` with page indicators. The `watchTitleScrollSpeed` setting (Double, defaults to 30.0) controls the pixels-per-second scrolling rate for long titles in the watch player.

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

### EPUB/PDF-to-Audio Data Model: Handling Mismatches

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

### Swift Concurrency & Thread Safety (June 2026)

All service-layer Timer closures and NotificationCenter observers have been modernized to use `MainActor.assumeIsolated` instead of `Task { @MainActor in }` for callbacks that are guaranteed to execute on the main thread. This pattern avoids spawning unnecessary unstructured tasks when the execution context is already on the main actor.

Key changes across 9 service files:
- **`AudioEngine`**: Timer callbacks (fade, time tracking, interruption observers) use `MainActor.assumeIsolated { ... }` with proper `[weak self]` guards. `AVAudioEngine`, `Timer`, and `NSObjectProtocol` observer properties are annotated `nonisolated(unsafe)` to suppress Swift 6 data-race diagnostics — these values are always accessed on the main thread at runtime because `AudioEngine` is `@MainActor`-isolated.
- **`BookmarkStore`**: Voice memo progress timer and audio file completion handler modernized.
- **`DatabaseService`**: Migration registration no longer wraps `Schema_V*.migrate(db)` in `MainActor.assumeIsolated { }` — `runMigrations(writer:)` is now `nonisolated` and the schema migrate methods do not require main-actor isolation. Test in-memory databases use the same simplified pattern.
- **Imports**: `@preconcurrency import AVFoundation` added to all files importing AVFoundation, silencing Swift 6 concurrency warnings until AVFoundation adopts full sendability.

### Artwork Accent Color (June 2026)

The app can dynamically derive its accent (tint) color from the current audiobook's cover artwork, providing a personalized UI that changes with each book. The feature is exposed as the **"Artwork"** theme option in Settings (now the default).

**Extraction pipeline (`DominantColorExtractor`):**
- Downsamples the cover image to 100×100px for fast analysis.
- Converts pixels to HSL and discards near-grey, near-white, and near-black pixels.
- Builds a saturation²-weighted hue histogram with centre-distance biasing (cover subjects tend to be centred).
- Emits a `CoverSignature` — ranked identity hues (OKLCH hue + chroma + weight) with an `isNeutral` flag (vivid coverage < 2%, so a stray pixel can't theme a book). The extractor reports what the cover IS; it has no opinion about how the UI looks.

**Integration points:**
- `PlayerModel.artworkAccentColor` — computed property with version-cached extraction, invalidated automatically when `currentDisplayArtworkVersion` changes.
- `EchoCoreApp.resolvedAccentColor` — returns the artwork-derived color when the theme is `.artwork`, otherwise the static theme color.
- `ThemeSelectionView` — shows a live preview circle using the extracted color (or a dashed placeholder when no artwork is loaded), with a descriptive subtitle and fallback footer text.
- `ThemeColor.artwork` added to the enum (before `.system` so it's the first/default option).

### Cover Tonal Themes (June 2026)

Cover colors are no longer used directly in the UI. The pipeline is
construct-don't-rescue:

`UIImage → DominantColorExtractor.signature(from:) → CoverSignature → CoverThemeBuilder.build(from:scheme:) → CoverTheme`

**`CoverThemeBuilder`** converts the cover's primary hue to OKLCH and builds
role colors from per-scheme tone recipes — pale ramps in light mode
(background L≈0.93–0.96), immersive deep tones in dark mode (L≈0.21–0.26),
accent at L 0.47 (light) / 0.78 (dark) with gamut-clamped chroma. Contrast is
guaranteed by construction: `CoverThemeBuilderTests` sweeps all 360 hues in
both schemes asserting accent ≥3:1 vs backgrounds, ≥2.5:1 vs chip, and
onAccent ≥4.5:1 vs accent. A bounded lightness-stepping safety valve covers
extreme gamut corners. Roles: `accent`, `onAccent`, `secondaryAccent`
(first candidate ≥60° away with ≥15% of the primary's weight, else a +30°
sibling), `backgroundTop`/`backgroundBottom` (the `AdaptiveBackground` ramp),
and `chip` (pills/control circles). Neutral covers (greyscale or `isNeutral`)
get a warm-grey ramp with the brand accent.

**Why OKLCH:** HSL lightness is not perceptual — yellow at HSL L 0.55 is
near-white in real luminance while blue at the same L is dark. OKLab
lightness is uniform across hues, which is what makes fixed tone recipes
safe for every cover.

**Integration:** `PlayerModel.coverTheme` (cached per artwork version +
`uiColorScheme`); `PlayerModel.artworkAccentColor` remains the compatibility
facade (nil for neutral covers so `?? .accentColor` fallbacks engage);
`artworkAccentColorHex` sends the **dark-recipe** accent to the Watch, whose
surface is always dark.

**History:** this replaced the `AccentSafetyNet` two-gate rescue ladder. Its
ΔE76 chroma gate passed high-chroma/equal-luminance accents (bright gold on
beige at 1.06:1 WCAG) because chromatic distance alone cannot carry small
glyphs — see CODE_AUDIT.md §13.

### Watch Connectivity Fixes (June 2026)

WatchConnectivity reliability fixes across the phone (`WatchSyncManager`) and watch (`WatchViewModel`):
1. **Timer suspension cap**: When the watch wakes from sleep, `Timer.scheduledTimer` fires with the accumulated wall-clock delta (potentially minutes). The tick delta is now capped at 2.0 seconds — beyond that, the watch requests a fresh authoritative state from the phone instead of animating through every intermediate progress value.
2. **Stale `userInfo` handling**: `WCSessionDelegate` `didReceiveUserInfo` deliveries can be minutes stale when queued while the watch is unreachable. After applying received state, the watch immediately requests the phone's current state to converge to the authoritative position.
3. **Transport commands never ride the background queue**: Transport / navigation / seek commands are only meaningful *live*. The watch sends them via `sendMessage` only; on failure it reverts its optimistic UI and re-requests phone state rather than falling back to `transferUserInfo`. `transferUserInfo` is a persistent FIFO queue that drains (even across launches) the next time the phone is reachable, so queuing a `play`/`pause`/`seek` there replays stale intent — the cause of ignored first taps, phantom resume-after-pause, and position jumps on relaunch. As defense-in-depth the phone routes queued payloads through `WatchCommandRouter.route(queuedMessage:)`, which honors only deferred-safe commands (bookmarks, flashcard grades) and drops time-sensitive ones; live commands continue through `route(message:)`.
4. **Durable application context for significant state** (phone side, `WatchSyncManager.syncToWatch(reason:)`): `updateApplicationContext` is now the source of truth for *significant* changes (book/track switch, transport, speed, loop, sleep timer, settings) rather than a fallback used only when the watch is unreachable. Previously, when the watch was reachable the phone pushed via `sendMessage` only; that message is best-effort and foreground-only, so if it was dropped (reachability flap / app-state transition) nothing durable carried the change. A foregrounded watch — whose only pull triggers are activation, `onAppear`, and reachability change — then kept showing the old book until a button press forced a `sendCommand`/`requestState` round-trip. The context is now always refreshed on significant changes (delivered immediately to an active watch via `didReceiveApplicationContext`, and guaranteed on the next activation otherwise), with `sendMessage` retained only as a low-latency optimisation. High-frequency progress and sleep-timer ticks pass `reason: .progress` to stay live-only and avoid churning the coalesced context — the watch interpolates position locally between syncs. State no longer rides `transferUserInfo` (same FIFO replay hazard as #3).

### Bug Fixes (June 2026)

- **`AudioEngine` pause-on-disconnect**: `AudioEngine` now observes `AVAudioSession.routeChangeNotification` and pauses on `.oldDeviceUnavailable` (wired headphones / aux / Bluetooth removed). Unlike `AVPlayer`, `AVAudioEngine` does not auto-pause when the output device disappears — left unhandled it falls back to the built-in speaker and keeps rendering, so the book suddenly plays out loud when the cable is pulled. Routed through a new `AudioEngineDelegate.audioEngineOutputDeviceDisconnected` → `PlaybackController.pause()`; because it is a normal pause (not an interruption) it never arms `wasPlayingBeforeInterruption`, so playback stays paused until the user explicitly resumes.
- **`PlayerLoadingCoordinator` progress save**: Before `stop()` zeroes `audioEngine.currentTime` and `state.folderURL` changes to the new book's key, the previous book's last-known-good position is now persisted under the correct folder key.
- **`EPUBAutoImportScanner` security scope**: When a single file (not a folder) is opened directly, a temporary security-scoped resource access is started on the parent directory so sibling EPUB files can be enumerated.
- **`AlignmentService` word-position calculation**: Hidden blocks (`isHidden = true`) and image blocks (`.image` kind) now receive weight 0.0 in cumulative word-position computation. Previously they contributed their full word count, skewing proportional interpolation. Block positions also shifted from "center" to "start" positioning for more predictable interpolation behavior.
- **`SecurityScopeManager` URL reuse**: `startSelection(url:)` and `startFile(url:)` now correctly stop the previous access grant when the URL changes (previously the `guard !hasAccess else { return }` early-exit leaked the old grant). When the same URL is requested, the call is a no-op.
- **`TokenDTW` gap-cost initialization**: The DTW cost matrix boundary row and column are now initialized with cumulative gap costs (`Int32(i) * 2` for deletions, `Int32(j) * 2` for insertions) so the DP can correctly skip leading tokens that have no match in the other sequence. Previously all boundary cells were zero, causing incorrect alignment when audio or EPUB sequences had unmatched prefixes.
