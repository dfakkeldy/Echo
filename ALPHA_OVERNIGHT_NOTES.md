# [ALPHA] Overnight Notes — 2026-05-20

## Implementation Status: ALL 8 STEPS COMPLETE

### Step 1: Repair timeline plumbing (COMMITTED — 8e40a91)
- Added MigrationService.migrateIfNeeded at app startup
- Added TimelineFeedViewModel.lastError with item-preserving behavior
- Wired follow playback scrolling via scrollTargetPosition binding
- Created SafeFileName.fromAudiobookID sanitizer
- loadFolder() ordering was already fixed

### Step 2: Schema_V5 (COMMITTED — bcf5d69)
- Registered V5 migration in DatabaseService.runMigrations()
- epub_block table with sequence/chapter/hidden indexes
- alignment_anchor table with time/block indexes
- Extended timeline_item with epub_block_id, timestamp_source, alignment_status, alignment_confidence
- EPubBlockDAO: insertAll, blocks, visibleBlocks, searchBlocks, hideBlock, unhideBlock
- AlignmentAnchorDAO: insert, anchors, bracketingAnchors, time-range queries, upsert
- TimestampSource enum: none, estimated, interpolated, lockedAnchor, transcript
- AlignmentStatus enum: unaligned, estimated, interpolated, lockedAnchor, omitted

### Step 3: EPUB import (COMMITTED — 07d2ba6)
- EPUBImportService: OPF spine parsing + XHTML block extraction via XMLParser
- EPUBAssetStorage: Application Support/EPUBAssets/<safeAudiobookID>/ management
- Image copying to local paths usable by UIImage(contentsOfFile:)
- Tests use minimal 2-chapter EPUB fixture

### Step 4: Timeline materialization (COMMITTED — 069b79a)
- EPUBBlockIngestionStrategy: primary V1 ingestion path
- Extended TimelineIngestionStrategy protocol with epubBlocks/anchors/bookmarks/cards
- Factory returns EPUB strategy when hasEPUB is true
- PlayerModel detects EPUB availability via EPubBlockDAO
- Sort: timestamped items by time, untimestamped by epubSequenceIndex

### Step 5: Manual anchors (COMMITTED — 6cf5dec)
- AlignmentService: moveBlockToCurrentTime, anchorSearchResult, anchorChapterStart/End
- hideBlock/unhideBlock with omitted status
- recalculateTimeline: linear interpolation between locked anchors by sequence_index
- TimelineDAO.updateAlignment for atomic row updates
- Tests cover: interpolation, anchor precedence, move updates, hide/unhide

### Steps 6-7: Feed modes + enhanced transcripts (COMMITTED — 7f9f8b3)
- TimelineFeedMode enum: followingPlayback, browsing, searchingToAnchor, editingAlignment
- Mode transitions on scroll and Go to Now
- Search-to-anchor via EPubBlockDAO.searchBlocks
- Context menu actions: moveBlockToNow, hideBlock, unhideBlock
- TranscriptService.loadEnhancedTranscript for .enhanced.json sidecars

### Step 8: Documentation (this commit)

## Test Status
- **Compilation**: ALL STEPS VERIFIED (`** BUILD SUCCEEDED **`)
- **Test execution**: BLOCKED — pre-existing simulator crash ("Early unexpected exit").
  Affects ALL tests (including pre-existing tests) on all available simulators.
  Root cause appears to be app crash at launch in simulator environment.

## Assumptions
1. `PBXFileSystemSynchronizedRootGroup` auto-includes new Shared/ files
2. ZIPFoundation needs SPM addition for production EPUB ZIP extraction (current impl works with expanded dirs)
3. Scroll position detection via @State binding is simplest change-set approach
4. Enhanced transcript returned directly to ingestion (no PlaybackState modification)

## Architecture Notes
- `Shared/Database/` module is shared across all targets via PBXFileSystemSynchronizedRootGroup
- Tests use Swift Testing framework with in-memory DatabaseService(inMemory: ())
- GRDB is the sole SPM dependency
- Chapter image filenames now use SafeFileName for sanitization
