# Plan A3: Cross-Target Code Deduplication

## Summary

Eliminate duplicated code across iOS, macOS, watchOS, and Widget targets by creating a shared utility module or SPM package for common types and functions.

## Current Duplications

| Item | Locations | Lines |
|------|-----------|-------|
| `formatTime` / `formatHMS` / `formatTimestamp` / `formatDuration` | `PlayerModel.swift:1727`, `Bookmarks.swift:785`, `PlaylistView.swift:42,52`, `Watch Bookmarks.swift:102`, `MacContentView.swift:324`, `TranscriptionManager.swift:397` | 7 implementations, ~5-10 lines each |
| `AppGroupDefaults` + `suiteName` | `Watch ContentView.swift:8-23`, `Widget AppIntent.swift:4-16`, `SettingsManager.swift` | 3 copies, ~15 lines each |
| `TranscriptionSegment` | iOS (`OrbitAudioBooks/Models/TranscriptionSegment.swift`), macOS (inline or separate) | 2 definitions |
| `WordFrequency` | iOS (`OrbitAudioBooks/Models/WordFrequency.swift`), `Watch ContentView.swift:149` | 2 definitions |
| AVPlayer setup code | `PlayerModel.swift` (via AudioEngine), `MacPlayerModel.swift` | Similar patterns |
| `WatchAction` / layout enums | Watch `ContentView.swift`, iOS `WatchAppSettingsView.swift` | 2 copies |

## Current State

**Progress:** Shared files created. iOS-internal `formatHMS` duplicates deduplicated. Cross-target SPM integration pending.

### Done ✅
- Created `Shared/` directory with canonical implementations:
  - `TimeFormatting.swift` — `formatHMS(_:)` with NaN/infinite guard
  - `AppGroupDefaults.swift` — single suite name + migration logic
  - `TranscriptionSegment.swift` — public init added
  - `WordFrequency.swift` — public init added
- iOS internal dedup: `Bookmarks.swift` and `PlaylistView.swift` now use `NowPlayingController.formatTime` (removed 2 local `formatHMS` copies)

### Remaining (needs Xcode project changes)
- Add `Shared/` files as compile sources to: watchOS target, macOS target, Widget target
- Or: wrap in a local SPM package and add as dependency to all targets
- Replace remaining duplicates:
  - macOS: `MacContentView.formatHMS`, `TranscriptionManager.formatTimestamp`, `TranscriptionSegment`
  - watchOS: `Bookmarks.formatTimestamp`, `AppGroupDefaults` in ContentView
  - Widget: `AppGroupDefaults` in AppIntent
- Remove `DesignerWatchAction` from iOS `WatchAppSettingsView` (use shared `WatchAction`)

## Approach

Create `Shared/` directory with canonical implementations referenced by all targets. Each file gets added to the relevant targets' compile sources via Xcode File Inspector.

## Files to Create/Modify

| Action | File | Status |
|--------|------|--------|
| Create | `Shared/TimeFormatting.swift` | ✅ |
| Create | `Shared/AppGroupDefaults.swift` | ✅ |
| Create | `Shared/TranscriptionSegment.swift` | ✅ |
| Create | `Shared/WordFrequency.swift` | ✅ |
| Modify | `OrbitAudioBooks/Views/Bookmarks.swift` | ✅ (use NowPlayingController.formatTime) |
| Modify | `OrbitAudioBooks/Views/PlaylistView.swift` | ✅ (use NowPlayingController.formatTime) |
| Modify | `Orbit Audiobooks.xcodeproj/project.pbxproj` | ⏳ (add shared files to all targets) |
| Modify | macOS + watchOS + Widget files | ⏳ (replace with shared imports) |

## Dependencies

- **Blocked by:** A2 (Watch decomposition) ✅
- **Remaining:** Cross-target file membership requires Xcode GUI or pbxproj editing

## Complexity

**Medium.** Shared source files created. Target membership and remaining replacements deferred to manual Xcode step.
