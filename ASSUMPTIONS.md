# Assumptions — Twitter Feed Timeline (Overnight Mode)

**Agent:** DeepSeek v4 / Claude Code  
**Date:** 2026-05-18  
**Branch:** `worktree-feature+twitter-feed-7314`

## Architecture Assumptions

1. **SQL Database Already Complete:** The plan `2026-05-17-sql-database-integration.md` is fully implemented. All DAOs (`TimelineDAO`, `BookmarkDAO`, `ChapterDAO`, etc.) and `DatabaseService` exist in `Shared/Database/`. The `timeline` SQL VIEW unions all five item types. This work builds the UI on top of that layer.

2. **`TimelineDAO.filtered(audiobookID:from:to:)` is the pagination primitive.** The time-range filter uses `media_timestamp >= startTime AND media_timestamp <= endTime`, which is the basis for windowed loading.

3. **`MediaPlayable` protocol does not yet exist.** CLAUDE.md references it as a future protocol for unifying audio/video. I define it in `OrbitAudioBooks/Protocols/MediaPlayable.swift` and conform `ContentCard` and `TimelineItem` to it. This is a forward-looking design decision — the protocol is minimal for now.

4. **No existing plan file for "Twitter Feed" specifically.** The plan name `2026-05-17-unified-sql-timeline-design.md` was suggested but does not exist. I am treating this as a net-new feature built on top of the completed SQL integration plan. The closest existing code is `PlaylistTimelineView` + `PlaybackTimelineService`, which I am extending (not replacing) to avoid breaking the existing Planner tab.

## UI/UX Assumptions

5. **The "Twitter Feed" replaces `PlaylistTimelineView` in `TimelineTab`.** The existing chapter-section-based view is replaced with a flat, Twitter-style chronological feed. The `TimelineHeaderView` and `DashboardShelf` above it remain unchanged.

6. **Window size of 30 minutes (1800 seconds).** Each pagination window loads ~30 min of content around the current playback position. This is configurable via `windowSize` in the ViewModel.

7. **`isFollowingPlayback` state machine:**
   - Starts `true` (follows playback)
   - Set to `false` when user manually scrolls away from the current position
   - Set to `true` on "Go to Right Now" tap
   - Auto-returns to `true` after 30 seconds of no manual scrolling IF the user is within the current window
   - Playback position updates push the "now" card position while following

8. **Chapter boundaries serve as sticky section headers.** When items cross a chapter boundary, a sticky `Section` header shows the chapter title. This uses SwiftUI's `LazyVStack(pinnedViews: [.sectionHeaders])`.

9. **"Go to Right Now" is a floating button** that appears when `!isFollowingPlayback`. Tapping it animates the scroll to the current playback position and resets `isFollowingPlayback = true`.

## Code Organization Assumptions

10. **New files go in existing directories:**
    - `OrbitAudioBooks/ViewModels/TimelineFeedViewModel.swift`
    - `OrbitAudioBooks/Views/TimelineFeedView.swift`
    - `OrbitAudioBooks/Views/TimelineFeedCard.swift`
    - `OrbitAudioBooks/Protocols/MediaPlayable.swift`

11. **Existing files modified:**
    - `OrbitAudioBooks/Services/PlaybackTimelineService.swift` — add windowed pagination
    - `OrbitAudioBooks/Views/TimelineTab.swift` — swap view

12. **No target changes needed.** All new files belong to the existing `OrbitAudioBooks` (iOS) target. The `Shared/` database layer already supports windowed queries.

## Risk Assumptions

13. **No migration needed.** The SQL schema already has the unified `timeline` VIEW. No schema changes required.

14. **Compile-time safety:** The code targets iOS 17+ (Swift 5.9+), uses `@Observable` (not `@ObservableObject`), and SwiftUI `ScrollViewReader` APIs available since iOS 14.

15. **GRDB is already linked.** All targets already have the GRDB SPM dependency from the completed SQL plan.

## Self-Correction Protocol

If a compilation error occurs more than 3 times:
1. Comment out the offending code
2. Add `// TODO: FIX ERROR - [explanation]`
3. Move to the next task
4. Document in this file
