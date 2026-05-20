# Overnight Implementation Notes

## 2026-05-20 — Step 1 Complete

### Test Runner Crash (Pre-existing)
The iOS Simulator test runner crashes on launch with "Early unexpected exit, operation never finished bootstrapping." This occurs in both the main repo and the worktree, confirming it's a pre-existing issue unrelated to Step 1 changes. Likely cause: App Group entitlement (`group.com.orbitaudiobooks`) can't be satisfied in the CI/sandbox simulator environment, or a `fatalError` is triggered during `DatabaseService` init.

**Assumption:** Tests validate via `xcodebuild build` (compilation success). Runtime testing will be verified when the simulator environment issue is resolved independently.

### Step 1 Changes Summary
1. **PlayerModel.loadFolder()** — Moved track loading before SQL persistence. Tracks are now loaded first, then persisted to SQL before `folderURL` is set.
2. **MigrationService startup** — Added `MigrationService.migrateIfNeeded(database:)` call in `Orbit_AudioBooksApp.init()`.
3. **TimelineFeedViewModel.lastError** — Added `lastError` property; all empty catch blocks now set it instead of silently discarding errors.
4. **Follow playback scrolling** — Wired `viewModel.onScrollToPosition` to `scrollTargetPosition` state, driving collection view scroll via `updateUIView`.
5. **SafeFileName** — Created `Shared/SafeFileName.swift` helper. Used in `TimelineIngestionFactory.saveChapterImage()` to sanitize audiobook ID URLs into safe filesystem names.
