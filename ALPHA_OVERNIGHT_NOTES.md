# [ALPHA] Overnight Notes — 2026-05-20

## Step 1: Repair Current Timeline Plumbing (COMPLETE)

### Fixes Applied
1. **loadFolder() ordering** — Was already fixed; SQL persistence occurs after tracks load.
2. **MigrationService startup** — Added `MigrationService.migrateIfNeeded(database:)` call in `Orbit_AudioBooksApp.init()`.
3. **TimelineFeedViewModel.lastError** — Added `lastError` property; error paths now populate it and preserve existing items instead of replacing with empty feed.
4. **Follow playback scrolling** — Added `scrollTargetPosition` binding, wired `viewModel.onScrollToPosition`, updated `TimelineFeedCollectionView` to detect changes and call coordinator.
5. **SafeFileName helper** — Created `Shared/SafeFileName.swift` with `SafeFileName.fromAudiobookID(_:)`; automatically included via `PBXFileSystemSynchronizedRootGroup`.

### Test Status
- **Compilation**: PASSED (`** BUILD SUCCEEDED **`)
- **Test execution**: BLOCKED by pre-existing simulator issue ("Early unexpected exit, operation never finished bootstrapping"). All simulators tested (iPhone 17, iPhone 17 Pro, iPhone 17e on OS 26.5 and 26.4.1) produce the same crash. This crash also affects existing tests in the repo — not introduced by these changes.

### Assumptions
- Using `@State private var scrollTargetPosition: TimeInterval?` is the simplest approach for detecting scroll position changes in `updateUIView`.
- The `PBXFileSystemSynchronizedRootGroup` mechanism correctly auto-includes `SafeFileName.swift` in all targets that include the `Shared/` group.
