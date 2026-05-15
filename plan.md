# Release Readiness Remediation Plan

> **For agentic workers:** Implement this task-by-task. Keep commits small, run the listed verification after each task group, and do not revert unrelated uncommitted changes.

**Goal:** Fix the release-readiness issues found in the audit: shared app-group state, broken URL routing, macOS transcription packaging, iPad targeting mismatch, missing tests, unavailable StoreKit unlock UI, and accessibility font defaults.

**Architecture:** Keep the existing multi-target structure. Centralize shared constants where practical, route external actions through explicit model APIs instead of notifications, and add focused tests around logic that can be validated without real audio playback or devices. Avoid broad refactors of `PlayerModel.swift` and watch `ContentView.swift` unless required for a specific fix.

**Tech Stack:** SwiftUI, Observation, AVFoundation, WatchConnectivity, WidgetKit, AppIntents, StoreKit 2, Xcode project settings, Swift Testing/XCTest, Swift Package Manager for `Tools/OrbitTranscriptionCLI`.

---

## Task 1: Put iOS, Watch, and Widget on the Same App Group

**Files:**
- Modify: `Orbit Audiobooks.xcodeproj/project.pbxproj`
- Modify or create: iOS entitlements file, preferably `OrbitAudioBooks/OrbitAudioBooks.entitlements`
- Keep: existing shared suite name `group.com.orbitaudiobooks`

**Steps:**
- [ ] Create a dedicated iOS entitlements file containing `com.apple.security.application-groups` with `group.com.orbitaudiobooks`.
- [ ] Set `CODE_SIGN_ENTITLEMENTS = OrbitAudioBooks/OrbitAudioBooks.entitlements;` on both Debug and Release build settings for the `Orbit Audiobooks` iOS target.
- [ ] Keep the watch app and widget extension pointed at their existing entitlements unless a target-specific split is needed by Xcode signing.
- [ ] Change `AppGroupDefaults.shared` in each target from silent fallback to a visible failure mode in Debug:
  - In Debug, assert/log clearly if `UserDefaults(suiteName:)` returns nil.
  - In Release, fall back only if necessary to avoid crashing user installs.
- [ ] Build iOS, watch, and widget and inspect generated `.xcent` files to confirm all three contain `group.com.orbitaudiobooks`.

**Acceptance Criteria:**
- iOS app, watch app, and widget extension all build.
- Generated iOS entitlements include the app group.
- Widget/watch state reads and writes the same suite as the iOS app.

---

## Task 2: Fix Widget and Bookmark Deep Links

**Files:**
- Modify: `OrbitAudioBooks/Orbit_AudioBooksApp.swift`
- Modify: `OrbitAudioBooks/Views/ContentView.swift`
- Modify: `OrbitAudioBooks/ViewModels/PlayerModel.swift`
- Modify: `Orbit Audiobooks Widget/Views/Orbit_Audiobooks_Widget.swift`
- Modify: `OrbitAudioBooks/Views/Bookmarks.swift`

**Steps:**
- [ ] Choose `orbitaudio` as the only app URL scheme because it is already registered in `OrbitAudioBooks/Info.plist`.
- [ ] Change widget URL from `orbitaudiobooks://` to an `orbitaudio://` URL.
- [ ] Replace the unobserved `SeekToTimestamp` notification with explicit model routing:
  - Store incoming deep-link requests in app-level state.
  - Pass the parsed request into `ContentView`.
  - Call a new `PlayerModel` API such as `handleDeepLink(_:)`.
- [ ] Support at least these deep links:
  - `orbitaudio://play`
  - `orbitaudio://play?time=<seconds>`
- [ ] When a `time` parameter is present, seek to that timestamp only when media is loaded; if no media is loaded, persist a pending seek and apply it after restore/load completes.
- [ ] Update Markdown export links in `Bookmark.markdownExport` to use the same canonical URL shape.

**Acceptance Criteria:**
- Tapping the widget opens the app through the registered scheme.
- Exported bookmark links open the app and seek to the intended timestamp when media is available.
- No code posts or depends on `SeekToTimestamp`.

---

## Task 3: Package or Disable macOS Transcription for Release

**Files:**
- Modify: `Orbit Audiobooks.xcodeproj/project.pbxproj`
- Modify: `Orbit Audiobooks macOS/Views/TranscriptionManager.swift`
- Modify if needed: `Tools/OrbitTranscriptionCLI/Package.swift`

**Steps:**
- [ ] Decide the release behavior for macOS transcription before shipping:
  - Preferred: bundle a signed `OrbitTranscriptionCLI` helper inside the macOS app.
  - Acceptable fallback: hide/disable transcription UI in Release until packaging is implemented.
- [ ] If bundling:
  - Add a build step that builds `Tools/OrbitTranscriptionCLI` for macOS.
  - Add a Copy Files phase to place `OrbitTranscriptionCLI` where `Bundle.main.url(forAuxiliaryExecutable:)` can find it.
  - Ensure signing/notarization covers the helper.
  - Remove production reliance on source-tree `.build` paths.
- [ ] If disabling:
  - Gate the transcription launch UI in Release.
  - Show a clear unavailable state instead of “binary not found.”
- [ ] Keep debug fallback paths only for local development.

**Acceptance Criteria:**
- A distributed macOS build either has a working bundled CLI or does not expose a broken transcription action.
- Debug builds can still use local source-tree workflows.

---

## Task 4: Align iPad Support With Product Claims

**Files:**
- Modify: `Orbit Audiobooks.xcodeproj/project.pbxproj`
- Review: `OrbitAudioBooks/Views/ContentView.swift`
- Review: `OrbitAudioBooks/Views/PlaylistView.swift`
- Review: `OrbitAudioBooks/Views/SettingsView.swift`

**Steps:**
- [ ] If iPad support is intended, set `TARGETED_DEVICE_FAMILY = "1,2";` for the iOS target in Debug and Release.
- [ ] Verify iPad orientations remain configured as intended.
- [ ] Build and smoke test on an iPad simulator.
- [ ] If iPad support is not intended for this release, update README and metadata to say iPhone only.

**Acceptance Criteria:**
- App Store target device support matches README and metadata.
- Main player, playlist, and settings screens are usable on iPad.

---

## Task 5: Add High-Value Automated Tests

**Files:**
- Modify: `Orbit AudiobooksTests/OrbitAudioBooksTests.swift`
- Modify: `Orbit Audiobooks Watch AppTests/Orbit_Audiobooks_Watch_AppTests.swift`
- Modify: `Tools/OrbitTranscriptionCLI/Tests/OrbitTranscriptionCLITests/OrbitTranscriptionCLITests.swift`
- Add helper test files only if a single test file becomes hard to scan.

**Steps:**
- [ ] Replace template iOS unit tests with real Swift Testing coverage for pure logic:
  - `sleepTimerCountdownText` formatting.
  - Settings default registration and app-group-backed watch settings.
  - Bookmark Markdown export URL scheme.
  - Bookmark sidecar URL naming for folder and single-file books.
- [ ] Add tests around any new deep-link parser before wiring it into UI.
- [ ] Replace template watch unit tests with coverage for:
  - `WatchAction.command` mappings.
  - Slot parsing/padding if extracted into testable helper logic.
  - Bookmark payload validation if extracted from `WatchViewModel`.
- [ ] Expand CLI tests only for local schema and argument-independent logic; do not require model downloads in unit tests.
- [ ] Leave UI tests minimal unless a deterministic launch/smoke path is available. Do not pretend launch-only tests cover playback or sync.

**Acceptance Criteria:**
- Unit tests fail before the relevant fixes where practical and pass after.
- Tests cover the release bugs without requiring real WatchConnectivity, StoreKit, or audio hardware.

---

## Task 6: Expose StoreKit Purchase and Restore for Transcript Unlock

**Files:**
- Modify: `OrbitAudioBooks/Views/SettingsView.swift`
- Modify or create: a small Store/Pro settings view
- Modify only if needed: `OrbitAudioBooks/Services/StoreManager.swift`
- Review: `OrbitAudioBooks/Views/ArtworkTranscriptOverlayView.swift`

**Steps:**
- [ ] Add a visible Pro/Transcripts section in Settings.
- [ ] Show current entitlement state from `StoreManager.hasUnlockedPro`.
- [ ] Show purchase action when `StoreManager.proUnlockProduct` is available.
- [ ] Show restore purchases action always.
- [ ] Surface `lastStoreError` in a user-visible but non-blocking way.
- [ ] If products fail to load, show a retry action.
- [ ] Keep `ArtworkTranscriptOverlayView` gated on `hasUnlockedPro` only if users can purchase or restore from the UI.

**Acceptance Criteria:**
- A new user can discover how to unlock transcript overlay.
- A returning user can restore purchases.
- StoreKit failures are visible enough to diagnose.

---

## Task 7: Make Accessibility Font Defaults Match the README

**Files:**
- Modify: `OrbitAudioBooks/Services/SettingsManager.swift`
- Modify: `OrbitAudioBooks/Views/SettingsView.swift`
- Review: `OrbitAudioBooks/Utilities/ViewModifiers.swift`
- Review: `README.md`

**Steps:**
- [ ] Set the default app font to `Lexend`.
- [ ] Keep `OpenDyslexic` as an explicit dyslexia-friendly option.
- [ ] Keep system font optional if desired, but label it as system/default system rather than making Helvetica the product default.
- [ ] Confirm bundled iOS fonts match the names used in `.custom(...)`.
- [ ] Review key screens at larger Dynamic Type sizes for truncation after the default changes.

**Acceptance Criteria:**
- First launch uses the accessibility-oriented default promised by README.
- Settings clearly offers Lexend and OpenDyslexic.
- Text remains readable at large accessibility sizes.

---

## Task 8: Verification and Release Gate

**Commands:**
- `xcodebuild build -project "Orbit Audiobooks.xcodeproj" -scheme "Orbit Audiobooks" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`
- `xcodebuild build -project "Orbit Audiobooks.xcodeproj" -scheme "Orbit Audiobooks Watch App" -destination 'generic/platform=watchOS Simulator' -quiet`
- `xcodebuild build -project "Orbit Audiobooks.xcodeproj" -scheme "Orbit Audiobooks WidgetExtension" -destination 'generic/platform=watchOS Simulator' -quiet`
- `xcodebuild build -project "Orbit Audiobooks.xcodeproj" -scheme "Orbit Audiobooks macOS" -destination 'platform=macOS' -quiet`
- `xcodebuild test -project "Orbit Audiobooks.xcodeproj" -scheme "Orbit Audiobooks" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`
- `swift test --package-path Tools/OrbitTranscriptionCLI`

**Manual Checks:**
- [ ] Launch iOS app, load sample/debug audiobook, verify playback controls.
- [ ] Open `orbitaudio://play?time=30` and confirm seek behavior.
- [ ] Tap widget and confirm app opens.
- [ ] Confirm watch quick commands update iOS state when devices/simulators are paired.
- [ ] Confirm widget/watch/iOS share app-group state after reinstall or clean launch.
- [ ] On macOS, confirm transcription is either working with bundled CLI or hidden/disabled in Release.
- [ ] Confirm purchase/restore UI appears and handles unavailable StoreKit products gracefully.

**Release Gate:**
- Do not ship until Tasks 1, 2, 3, and 5 are complete.
- Tasks 4, 6, and 7 must either be completed or product claims/metadata must be updated to remove those promises for the release.

