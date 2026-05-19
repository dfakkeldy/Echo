# Plan: Modular Dashboard UI & Timeline Refactor — RESCOPED (2026-05-19)

**Original scope:** LazyVGrid of configurable, toggleable, draggable module tiles with a `DashboardModule` protocol.

**Reality:** The UI took a different direction — tab-based navigation with a Timeline + horizontal DashboardShelf. The original grid/protocol design was replaced. This plan now reflects what was actually built and what genuinely remains. **2026-05-19 update:** Major UI simplification — consolidated to strict 2-tab architecture.

## What Was Built (replaces original plan)

### Tab Navigation
- **`RootTabView.swift`** — Strict **2-tab** container (Now Playing, Timeline) with toolbar buttons for folder picker, help, and settings. Library and Planner tabs removed; their functionality merged into the Timeline feed. Handles deep links, StoreKit product requests, and flashcard review sheet presentation.
- **`NowPlayingTab.swift`** — Pure consumption UI: `AlbumArtHeroView` at top (no transcript overlay wrapper), chapter/track indicator, scrubber, transport controls, voice memo overlay, bottom toolbar. Transcript interaction moved to Timeline feed.
- **`TimelineTab.swift`** — Unified feed replacing former Library, Planner, and standalone Review tabs. Contains `DashboardShelf`, `SpeedSuggestionBanner` (moved from Planner), `dueReviewBanner`, and the `TimelineFeedCollectionView` feed.
- **DELETED:** `LibraryTab.swift`, `PlannerTab.swift`, `ContentView.swift` (duplicate of NowPlayingTab).

### Dashboard Shelf
- **`DashboardShelf.swift`** — Collapsible horizontal `ScrollView` with 6 module cards: Stats, Speed, SleepTimer, UpcomingReviews, ListeningProgress, Bookmarks. Toggled by a chevron button. Lives inside TimelineTab.
- **`StatsModuleView.swift`** — "Today" card showing listened duration vs. total.
- **`UpcomingReviewsModuleView.swift`** — "Reviews Due" card querying `FlashcardDAO.allDueCards()`.
- **`ListeningProgressModuleView.swift`** — "Progress" card showing percentage through current title.
- **`SpeedCardView.swift`**, **`SleepTimerCardView.swift`**, **`BookmarkCardView.swift`** — Additional shelf modules.

### Timeline (not in original plan)
- **`TimelineContentView.swift`** — Lazy-loaded vertical scroll of `TimelineGroup` cards with `NowLineView` for current position, "load earlier"/"load later" infinite scroll triggers, and `ScrollViewReader`-based "Recenter on Now" support.
- **`TimelineHeaderView.swift`** — Time scale picker (minutes/hours/days), mode toggle (real-time/playlist-time), viewing/editing toggle.
- **`TimelineContentCard.swift`** — Individual card renderer for timeline items.
- **`PlaylistTimelineView.swift`** — Playlist-time mode view.
- **`NowLineView.swift`**, **`PlayheadLineView.swift`** — Position indicators.

### Supporting Models & Services
- **`TimelineService.swift`** — Groups timeline items by time scale, handles pagination.
- **`Models/TimelineGroup.swift`**, **`Models/ContentCard.swift`**, **`Models/TimelineScope.swift`** (renamed from `TimeScale`), **`Models/RealTimeEvent.swift`** — Timeline data types.
- **`Models/Note.swift`**, **`Models/PlannedSession.swift`**, **`Models/SpeedSuggestion.swift`** — Content card subtypes.
- **`Views/ContentCardEditor.swift`**, **`Views/NoteEditorView.swift`**, **`Views/SchedulingSheet.swift`**, **`Views/SpeedSuggestionBanner.swift`** — Editing/scheduling UI.
- **`Views/FlashcardReviewCard.swift`**, **`Views/FlashcardReviewSession.swift`** — Flashcard review views.

### TimelineScope (renamed from TimeScale)
Structural zoom levels for the unified feed: `.book` (library/chapter markers only), `.chapter` (segments under chapter sections), `.transcription` (sentence-level transcript). Managed by `TimelineHeaderView` cycle button.

### Feed Interaction Model
- **Tap** text/chapter/bookmark items → seek playhead to `audioStartTime`
- **Tap** image assets → open in system viewer
- **Tap** Anki cards → launch review session
- **Long press** any item → context menu with Edit action
- **Now Line** demarcation: history items rendered at reduced opacity; active item highlighted with blue bar

## Remaining Gaps

### 1. Library-as-TimelineScope.book
The library now lives inside the Timeline feed at the `.book` scope level. Currently `TimelineScope.book` shows chapter markers; needs full library browsing (all audiobooks, recently played, storage stats) when no audiobook is loaded.

### 2. Transcript visibility optimization
Transcript overlay removed from `NowPlayingTab`. Processing now tied to Timeline feed visibility — `isTranscriptProcessingEnabled` managed by TimelineTab's appear/disappear, saving CPU/battery when user is on Now Playing tab.

### 3. Dashboard shelf — completed
The original 3-card limitation is resolved. The shelf now contains 6 modules: Stats, Speed, SleepTimer, UpcomingReviews, ListeningProgress, Bookmarks. Additional cards can follow the same pattern.
- **SpeedCard** — current speed with tap-to-cycle

### 4. Chapter time block visualization
**`ChapterTimeBlockView.swift`** exists but may need integration into the timeline or NowPlayingTab.

## What's NOT Happening (descoped)

| Original Plan Item | Disposition |
|--------------------|-------------|
| `DashboardModule` protocol | Not needed — the tab + shelf pattern doesn't require protocol conformance |
| `LazyVGrid` configurable layout | Replaced by tab navigation + horizontal shelf |
| `ModuleSize` enum | Not applicable |
| `DashboardModuleConfig` persistence | Not applicable |
| Drag-to-reorder edit mode | Not applicable |
| Module toggling in Settings | Could be added for shelf cards, but lower priority than LibraryTab |

## Dependencies

- **Done:** A1 (PlayerModel decomposition), A5 (protocol extraction), L10N (localization)
- **Blocks:** Nothing critical. LibraryTab can be built independently.
- **Related:** PLIST (LibraryTab will display imported playlist manifests), SQL (shelf cards query GRDB)

## Complexity

**Reduced from Large to Medium.** The tab navigation and timeline are built. Remaining work: LibraryTab implementation (medium), transcript optimization (small), shelf card expansion (small).
