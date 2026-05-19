# Swarm Execution Assumptions — feature/twitter-feed-7392

## Design Decisions (Approved via Interactive Session)
1. **Materialized table** — `timeline_item` replaces the `timeline` VIEW
2. **Flat feed** — No chapter sectioning; everything is a row
3. **Push-driven** — Audio engine pushes position → feed scrolls reactively

## Architectural Assumptions from Risk Assessment
4. **UICollectionView wrapper** — SwiftUI `LazyVStack` replaced for dense feed performance
5. **Range queries** — `audioStartTime`/`audioEndTime` replace single `mediaTimestamp`
6. **EPUB ordering index** — `epubSequenceIndex` survives alignment failures
7. **Granularity levels** — Chapter-level queries for scrubbing, sentence-level for reading
8. **Elastic Scrubber Cell** — Visual time-gap representation in sparse mode
9. **watchOS sparse-only** — No dense feed queries on watch; preload markers to memory
10. **VoiceOver guard** — Auto-scroll disabled when `UIAccessibility.isVoiceOverRunning`
11. **Alignment graceful degradation** — Failed alignment → un-synced EPUB text + sparse feed fallback

## Implementation Assumptions (Overnight Mode)
12. Schema migration is V4, additive (existing tables untouched)
13. `TimelineItemType` adds `textSegment`, `imageAsset`; removes `track`, `transcription`, `note`
14. `ContentCardType` gains `.imageAsset` case
15. Existing DAOs dual-write to `timeline_item` on create/update/delete
16. Ingestion factory runs once at audiobook load time, not on every app launch
17. `metadataJSON` column carries type-specific fields (SM-2 scheduling, voice memo paths)
18. `sourceTable`/`sourceRowid` columns enable sync without SQL triggers

## Compilation Fixes (Swarm Execution Session 2026-05-18)
19. **BookmarkRecord.id is non-optional** — Removed spurious `guard let` in BookmarkDAO.syncToTimeline
20. **TimelineItem circular reference** — Moved Codable conformance to extension alongside CodingKeys; keeping FetchableRecord/MutablePersistableRecord in a separate extension resolves a Swift 6 / GRDB 7 compiler circularity
21. **PlayerModel state access** — TimelineTab now accesses `model.tracks` and `model.folderURL?.absoluteString` instead of private `model.state.tracks`
22. **Float→Double conversion** — `model.speed` (Float) cast to Double for TimelineFeedViewModel.playbackSpeed
23. **UICollectionViewDiffableDataSource Sendable** — Replaced FeedItemIdentifier enum with plain `String` IDs for diffable data source; item/gap lookup via Coordinator dictionaries
24. **UIFont.monospacedDigit** — Replaced SwiftUI.Font.monospacedDigit() calls with UIFont.monospacedDigitSystemFont helper
25. **Shared EPUB alignment models** — Created `Shared/SyncMarker.swift` and `Shared/EnhancedTranscriptionSegment.swift` (including TextFormat/FormatType); previously only existed in CLI Tools SPM package
26. **DashboardShelf subviews** — Confirmed StatsModuleView, SpeedCardView, SleepTimerCardView, UpcomingReviewsModuleView, ListeningProgressModuleView, BookmarkCardView exist in Views/ directory (not Components/)
27. **Test fixes** — Updated PlayerModelTests and OrbitAudioBooksTests to match current Bookmark init signature, MockPlaybackController API, MockSleepTimerManager API, and TimelineItemType v4 enum values
