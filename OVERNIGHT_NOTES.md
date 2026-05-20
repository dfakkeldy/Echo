# Overnight Implementation Notes — V1 Manual EPUB Timeline

## Overall Status: All 8 Steps Implemented (Builds Clean)

Worktree: `.claude/worktrees/feature-work`
Branch: `worktree-feature-work`
Commits: 7 (one per step, see `git log`)

### Test Runner Issue (Pre-existing)
The iOS Simulator test runner crashes on launch ("Early unexpected exit, operation never finished bootstrapping"). Confirmed in both main repo and worktree. Likely cause: App Group entitlement or `DatabaseService.init()` fatalError in simulator.

**Verification:** All steps verified via `xcodebuild build` (compilation success). Runtime tests will verify when simulator issue is resolved.

### Implementation Summary

#### Step 1: Repair Timeline Plumbing (962ca80)
- Fixed `PlayerModel.loadFolder()`: tracks loaded before SQL persistence
- Wired `MigrationService.migrateIfNeeded` at app startup
- Added `TimelineFeedViewModel.lastError` with populated catch blocks
- Follow-playback scrolling via `scrollTargetPosition` state
- `SafeFileName.fromAudiobookID` for URL-to-filename sanitization

#### Step 2: Schema_V5 + Records + DAOs (903ff34)
- New tables: `epub_block` (14 columns, 3 indexes), `alignment_anchor` (9 columns, 2 indexes)
- Extended `timeline_item` with: `epub_block_id`, `timestamp_source`, `alignment_status`, `alignment_confidence`
- DAOs: `EpubBlockDAO` (insert, fetch, hide/unhide, deleteAll), `AlignmentAnchorDAO` (insert, fetch, delete, deleteAll)
- Registered `v5_epub_alignment` migration in `DatabaseService`

#### Step 3: EPUB Import Service (4dda65b)
- `EPUBImportService`: writes blocks to SQL, copies images to `EPUBAssets/<safeID>/`, posts `.epubBlocksDidChange`
- `DirectoryEPUBParser`: reads pre-extracted EPUB directories using `Foundation.XMLParser` (iOS-compatible SAX parser)
- Supports: container.xml → OPF spine → XHTML block extraction (headings, paragraphs, images)
- **Assumption:** Full ZIP extraction needs ZIPFoundation SPM dependency added to iOS target. V1 uses pre-extracted EPUB directories.

#### Step 4: Timeline Ingestion Service (7eaa09e)
- `TimelineIngestionService`: unified ingestion from chapters, EPUB blocks, anchors, bookmarks, flashcards, transcripts
- Ordering: timestamped items by `audioStartTime`, untimestamped by `epubSequenceIndex`
- Proper `timestamp_source`, `alignment_status`, `epub_block_id` tracking on all items
- Chapter estimation for blocks within known chapter boundaries

#### Step 5: Alignment Service (269cad2)
- `AlignmentService`: manual anchor management + timestamp interpolation
- Operations: `moveBlockToCurrentTime`, `anchorSearchResult`, `anchorChapterStart/End`, `hideBlock/unhideBlock`
- `recalculateTimeline`: linear interpolation between locked anchors, chapter-boundary estimation, hidden block handling
- All updates in single DB transaction

#### Step 6: Feed States (b612d60)
- `TimelineFeedMode` enum: `followingPlayback`, `browsing`, `searchingToAnchor`, `editingAlignment`
- Mode-aware scroll behavior, tripwire auto-restore
- Entry/exit methods for search and edit-alignment modes

#### Step 7: Enhanced Transcript (0e2ca3b)
- `TranscriptService.loadEnhancedTranscript(for:)` — discovers `<audio>.enhanced.json` sidecar
- Static method returns `[EnhancedTranscriptionSegment]?`, falls back gracefully
- Existing plain transcript loading unchanged

#### Step 8: Documentation (this commit)
- Updated `OVERNIGHT_NOTES.md`
- Updated `ARCHITECTURE.md` with new services and schema

### Remaining Integration Work
1. Wire `AlignmentService` into `TimelineTab` context menu actions
2. Add `ZIPFoundation` to iOS target for full ZIP-based EPUB import
3. Wire search-to-anchor sheet UI
4. Wire `TimelineIngestionService` into `PlayerModel.loadFolder()` (currently uses old `TimelineIngestionFactory`)
5. Run tests once simulator issue is resolved

### Files Created/Modified
- **New services:** `EPUBImportService`, `EPUBParser`, `TimelineIngestionService`, `AlignmentService`, `SafeFileName`
- **New schema:** `Schema_V5`, `EpubBlockRecord`, `AlignmentAnchorRecord`, `EpubBlockDAO`, `AlignmentAnchorDAO`
- **Modified:** `PlayerModel`, `TimelineFeedViewModel`, `TimelineTab`, `TimelineFeedCollectionView`, `TranscriptService`, `TimelineItem`, `DatabaseService`, `Orbit_AudioBooksApp`, `TimelineIngestionFactory`
- **Tests:** `Step1_RegressionTests`, `Step2_SchemaV5Tests`, `Step3_EPUBImportTests`, `Step4_TimelineIngestionTests`, `Step5_AlignmentServiceTests`, `Step7_EnhancedTranscriptTests`
