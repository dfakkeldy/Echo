# Assumptions — Twitter Feed Timeline (Overnight Mode)

**Primary Agent:** DeepSeek v4 / Claude Code  
**Date:** 2026-05-18  
**Branch:** `worktree-feature+twitter-feed-7314` (prior swarm)  
**Resumed by:** Agent 4829 on `feature/twitter-feed-4829`

## Implementation Status: COMPLETE

### ✅ Core Feed Feature
- `TimelineFeedViewModel.swift` — @Observable VM with 30-min rolling window via `TimelineDAO.filtered`
- `TimelineFeedView.swift` — `ScrollViewReader` + `LazyVStack(pinnedViews: [.sectionHeaders])` + sticky chapter headers
- `TimelineFeedCard.swift` — Twitter-style cards with per-`ContentCardType` icons and color coding
- `MediaPlayable.swift` — Forward-looking protocol (separate from existing `PlaybackTimelineItem`)
- `PlaybackTimelineService.swift` — `loadWindow(from:to:)` added for windowed queries
- `TimelineTab.swift` — Wired `TimelineFeedView` with `recenterTrigger` for header "Now" button

### ✅ Follow State Machine
- `FollowState.following` → `FollowState.browsing` on user scroll
- `FollowState.browsing` → `FollowState.following` on "Go to Now" tap or 30s auto-follow timeout
- `ScrollViewReader` programmatic scroll to `currentItemID`

### 🐛 Agent 4829 Fixes Applied
16. **`TimelineFeedCard.swift` type mismatches fixed.** The prior swarm referenced `ContentCardType` cases as `.transcription` and `.flashcard`, but the actual enum uses `.textSegment` and `.ankiCard`. Both `iconFor(_:)` and `cardBackground` were corrected. Added `.imageAsset` case handling.

17. **Xcode project uses `PBXFileSystemSynchronizedRootGroup`.** No manual pbxproj file addition needed — Xcode 16 auto-discovers `.swift` files in synchronized directories. All new files under `OrbitAudioBooks/` are automatically compiled.

18. **Pre-existing build error:** `Bookmarks.swift:375` — `@Environment(PlayerModel.self)` fails in `Orbit_Audiobooks_WidgetExtension` target because `PlayerModel` is not available in the widget extension module. This is present on `main` (commit `997f9cd`) and is NOT introduced by this feature.

### ⚠️ Future Work
19. **Deduplicate **`buildSections` logic.** Both `TimelineFeedViewModel` and `PlaybackTimelineService` contain chapter-section-building code. The service's `loadWindow(from:to:)` should be removed once `PlaylistTimelineView` is fully replaced by the feed.

20. **MediaPlayable vs PlaybackTimelineItem.** Two similar but separate protocols exist. These should be unified in a follow-up refactor.

## Architecture Assumptions (from prior swarm)

1. **SQL Database Already Complete:** The plan `2026-05-17-sql-database-integration.md` is fully implemented. All DAOs (`TimelineDAO`, `BookmarkDAO`, `ChapterDAO`, etc.) and `DatabaseService` exist in `Shared/Database/`. The `timeline` SQL VIEW unions all five item types. This work builds the UI on top of that layer.

2. **`TimelineDAO.filtered(audiobookID:from:to:)` is the pagination primitive.** The time-range filter uses `audio_start_time >= startTime AND audio_start_time <= endTime`, which is the basis for windowed loading.

3. **`MediaPlayable` protocol does not yet exist.** CLAUDE.md references it as a future protocol for unifying audio/video. Defined in `OrbitAudioBooks/Protocols/MediaPlayable.swift`.

4. **No existing plan file for "Twitter Feed" specifically in the plans directory.** The plan is `docs/superpowers/specs/2026-05-17-unified-sql-timeline-design.md` in prior worktree. This is a net-new feature built on top of the completed SQL integration plan. The closest existing code is `PlaylistTimelineView` + `PlaybackTimelineService`, which is extended (not replaced) to avoid breaking the existing Planner tab.

## UI/UX Assumptions

5. **The "Twitter Feed" replaces `PlaylistTimelineView` in `TimelineTab`.** The `TimelineHeaderView` and `DashboardShelf` above it remain unchanged.

6. **Window size of 30 minutes (1800 seconds).** Configurable via `windowSize` in the ViewModel.

7. **`isFollowingPlayback` state machine** (see status above).

8. **Chapter boundaries serve as sticky section headers** using `LazyVStack(pinnedViews: [.sectionHeaders])`.

9. **"Go to Right Now" is a floating button** that appears when `followState == .browsing`.

## Code Organization

10. **New files:**
    - `OrbitAudioBooks/ViewModels/TimelineFeedViewModel.swift`
    - `OrbitAudioBooks/Views/TimelineFeedView.swift`
    - `OrbitAudioBooks/Views/TimelineFeedCard.swift`
    - `OrbitAudioBooks/Protocols/MediaPlayable.swift`

11. **Modified files:**
    - `OrbitAudioBooks/Services/PlaybackTimelineService.swift`
    - `OrbitAudioBooks/Views/TimelineTab.swift`

12. **Xcode 16 `PBXFileSystemSynchronizedRootGroup`** auto-discovers all `.swift` files. No pbxproj edits needed.

## Risk Assumptions

13. **No migration needed.** The SQL schema already has the unified `timeline` VIEW.

14. **Compile-time safety:** Targets iOS 17+ (Swift 5.9+), uses `@Observable`, `ScrollViewReader` available since iOS 14.

15. **GRDB is already linked** via SPM.
