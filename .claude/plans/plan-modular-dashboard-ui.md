# Plan: Modular Dashboard UI & Transcript Optimization — RESCOPED (2026-05-18)

**Original scope:** LazyVGrid of configurable, toggleable, draggable module tiles with a `DashboardModule` protocol.

**Reality:** The UI took a different direction — tab-based navigation with a Timeline + horizontal DashboardShelf. The original grid/protocol design was replaced. This plan now reflects what was actually built and what genuinely remains.

## What Was Built (replaces original plan)

### Tab Navigation
- **`RootTabView.swift`** — 3-tab container (Now Playing, Timeline, Library) with toolbar buttons for folder picker, help, and settings. Handles deep links and StoreKit product requests.
- **`NowPlayingTab.swift`** — Main player UI: album art hero, chapter/track indicator, scrubber, transport controls, voice memo overlay, bottom toolbar. The traditional player experience.
- **`TimelineTab.swift`** — Timeline scroll view + `DashboardShelf` horizontal strip. Creates a `TimelineService` on appear, binds to time scale and timeline mode (real-time vs. playlist-time) changes.
- **`LibraryTab.swift`** — **STUB ONLY.** Shows `ContentUnavailableView` placeholder. Needs real implementation.

### Dashboard Shelf
- **`DashboardShelf.swift`** — Collapsible horizontal `ScrollView` with 3 stat cards. Toggled by a chevron button. Lives inside TimelineTab.
- **`StatsModuleView.swift`** — "Today" card showing listened duration vs. total.
- **`UpcomingReviewsModuleView.swift`** — "Reviews Due" card querying `FlashcardDAO.allDueCards()`.
- **`ListeningProgressModuleView.swift`** — "Progress" card showing percentage through current title.

### Timeline (not in original plan)
- **`TimelineContentView.swift`** — Lazy-loaded vertical scroll of `TimelineGroup` cards with `NowLineView` for current position, "load earlier"/"load later" infinite scroll triggers, and `ScrollViewReader`-based "Recenter on Now" support.
- **`TimelineHeaderView.swift`** — Time scale picker (minutes/hours/days), mode toggle (real-time/playlist-time), viewing/editing toggle.
- **`TimelineContentCard.swift`** — Individual card renderer for timeline items.
- **`PlaylistTimelineView.swift`** — Playlist-time mode view.
- **`NowLineView.swift`**, **`PlayheadLineView.swift`** — Position indicators.

### Supporting Models & Services
- **`TimelineService.swift`** — Groups timeline items by time scale, handles pagination.
- **`Models/TimelineGroup.swift`**, **`Models/ContentCard.swift`**, **`Models/TimeScale.swift`**, **`Models/RealTimeEvent.swift`** — Timeline data types.
- **`Models/Note.swift`**, **`Models/PlannedSession.swift`**, **`Models/SpeedSuggestion.swift`** — Content card subtypes.
- **`Views/ContentCardEditor.swift`**, **`Views/NoteEditorView.swift`**, **`Views/SchedulingSheet.swift`**, **`Views/SpeedSuggestionBanner.swift`** — Editing/scheduling UI.
- **`Views/FlashcardReviewCard.swift`**, **`Views/FlashcardReviewSession.swift`** — Flashcard review views.

## Remaining Gaps

### 1. LibraryTab — needs real implementation
Currently a `ContentUnavailableView` stub. Should show:
- Recently played audiobooks
- Browse by author/title
- Imported playlist manifests (post-PLIST plan)
- Storage usage stats

### 2. Transcript visibility optimization
The original plan's core optimization: tie `TranscriptionManager` processing to whether transcript-dependent views are visible. Currently `TranscriptOverlayView` is embedded directly in `NowPlayingTab` — no lazy processing gate. This saves CPU/battery when the user isn't looking at transcript data.

### 3. Dashboard shelf module expansion
Only 3 mini-cards exist. Natural additions that fit the horizontal-shelf pattern:
- **SleepTimerCard** — countdown display when timer is active
- **BookmarkCard** — recent bookmark count / quick-add
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
