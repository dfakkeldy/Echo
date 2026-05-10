# 🛰️ Orbit AudioBooks

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)](#)
[![TestFlight](https://img.shields.io/badge/TestFlight-Beta-blue.svg)](#)
[![Platform](https://img.shields.io/badge/iOS-19+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/macOS-16+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/watchOS-12+-blue.svg)](#)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A multi-platform Apple ecosystem audiobook player built with SwiftUI, delivering a unified listening experience across iPhone, iPad, Mac, Apple Watch, and the Home Screen via widgets.

---

## Overview

Orbit AudioBooks is a full-featured audiobook application organized as a single Xcode workspace with four distinct targets. It supports bookmarking with optional voice memos, chapter navigation, loop modes, a sleep timer, variable playback speed, and intelligent rewind logic that adapts to pause duration. The iOS and watchOS apps communicate bidirectionally via WatchConnectivity, while a Widget displays the current playback state on the Home Screen / Lock Screen.

---

## Architecture

The workspace is composed of four targets, each with its own entry point and view hierarchy:

| Target | Bundle Identifier / Entry Point | Purpose |
|---|---|---|
| **OrbitAudioBooks** (`iOS/iPadOS`) | `Orbit_AudioBooksApp.swift` → `ContentView.swift` | Primary audiobook player. Manages playback via the `@Observable PlayerModel`, handles file/folder selection, bookmarks, voice memos, WatchConnectivity, and Now Playing integration. |
| **Orbit Audiobooks macOS** (`macOS`) | `Orbit_Audiobooks_macOSApp.swift` → `MacContentView.swift` | Native macOS desktop companion. Uses `MacPlayerModel` (`ObservableObject`-based) with a `NavigationSplitView` layout: a bookmarks sidebar and a player pane with transport controls and a speed picker. |
| **Orbit Audiobooks Watch App** (`watchOS`) | `OrbitAudioBooksWatchApp.swift` → `ContentView.swift` | Wearable remote for the iOS player. Communicates with the phone via `WCSession` to send play/pause, skip, scrub, volume, loop mode, sleep timer, and bookmark commands. |
| **Orbit Audiobooks Widget** (`Widgets`) | `Orbit_Audiobooks_WidgetBundle.swift` → `Orbit_Audiobooks_Widget.swift` | A `WidgetBundle` exposing a `StaticConfiguration` widget (`.accessoryCircular`) that shows the current track title, progress ring, and thumbnail via `AppGroupDefaults` communication. Also includes a `TogglePlaybackIntent` (App Intent) for Control Center / widget interactions. |

Shared models and utilities used across targets include:

- **`PlayerModel`** — Central iOS/iPadOS playback model (Swift Observable), responsible for AVPlayer management, chapter parsing, bookmark persistence, WatchConnectivity delegation, and sleep timer logic.
- **`MacPlayerModel`** — macOS-specific playback model wrapping AVPlayer with its own bookmark format (`MacBookmark`), security-scoped bookmarks, and UserDefaults persistence.
- **`Bookmark.swift`** — The `Bookmark` struct (Codable, Equatable, Hashable) representing a saved position, with optional text note and voice memo filename. Includes `VoiceMemoRecorder` and `EditBookmarkView` for recording/editing.
- **`AppIntent.swift`** — Shared `AppGroupDefaults` suite and `SessionDelegator` for WCSession activation, enabling the widget and app intents to toggle playback.
- **Shared Font Assets** — `Lexend.ttf` and `OpenDyslexic-Regular.otf` are bundled in both the iOS and macOS targets for accessibility-optimized typography.

---

## Accessibility (A11y) First

Orbit AudioBooks is built with accessibility as a core principle, not an afterthought.

### Dyslexia-Optimized Typography

The project bundles two specially-selected font families to support neurodiverse readers:

- **Lexend** ([`OrbitAudioBooks/Fonts/Lexend.ttf`](OrbitAudioBooks/Fonts/Lexend.ttf) and [`Orbit Audiobooks macOS/Fonts/Lexend.ttf`](Orbit%20Audiobooks%20macOS/Fonts/Lexend.ttf)) — A typeface designed with research-backed letter spacing and proportions to improve reading fluency and reduce visual crowding.
- **OpenDyslexic** ([`OrbitAudioBooks/Fonts/OpenDyslexic-Regular.otf`](OrbitAudioBooks/Fonts/OpenDyslexic-Regular.otf) and [`Orbit Audiobooks macOS/Fonts/OpenDyslexic-Regular.otf`](Orbit%20Audiobooks%20macOS/Fonts/OpenDyslexic-Regular.otf)) — An open-source font weighted at the bottom to combat letter reversal and rotation, widely adopted by the dyslexia community.

### Developer Requirements

> **All developers contributing to this project MUST:**
> 1. Register both fonts in the target's `Info.plist` under `UIAppFonts` (iOS) / `ATSApplicationFontsPath` (macOS) when adding new text-rendering targets.
> 2. Apply `Lexend` as the default body font and `OpenDyslexic` as the dyslexia-friendly toggle option in all user-facing text views.
> 3. Never hardcode a system font (`SF Pro`, `Helvetica Neue`, etc.) as the sole typographic option — the app must always offer at least one of the bundled accessibility fonts.
> 4. Test all new UI with both fonts enabled to ensure no truncation, overlapping, or layout breakage.

### Additional A11y Practices

- AVPlayer is configured with `mode: .spokenAudio` for optimal speech reproduction and language-specific voiceover support.
- All interactive controls (play/pause, skip, seek) are surfaced via `UIAccessibility` and WatchOS `accessibility` modifiers.
- Widget progress rings use high-contrast `.tint` fills and avoid ambiguous color-only state indicators.

---

## Development & Testing

### Test Suites

| Target | Test File | Scope |
|---|---|---|
| **OrbitAudioBooksTests** | `OrbitAudioBooksTests.swift` | Unit tests for the iOS model layer (playback logic, bookmark persistence, timer logic). |
| **OrbitAudioBooksUITests** | `OrbitAudioBooksUITests.swift`, `OrbitAudioBooksUITestsLaunchTests.swift` | UI integration tests for the iOS app using XCUITest. |
| **Orbit Audiobooks Watch AppTests** | `Orbit_Audiobooks_Watch_AppTests.swift` | Unit tests for watchOS model and WCSession command parsing. |
| **Orbit Audiobooks Watch AppUITests** | `Orbit_Audiobooks_Watch_AppUITests.swift` | UI tests for the watch app (launch validation, button interaction). |

Run all tests from Xcode with `⌘U` or via the terminal:

```bash
xcodebuild test \
  -workspace Orbit\ Audiobooks.xcodeproj \
  -scheme "Orbit Audiobooks" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

### MockMediaProvider

[`MockMediaProvider.swift`](OrbitAudioBooks/MockMediaProvider.swift) is a `#if DEBUG`-only utility that seeds a sample audiobook (`BIFF.m4b`) into the simulator's Documents directory on first launch. It is automatically invoked during `DEBUG && targetEnvironment(simulator)` builds in the app's `init()`.

**Usage during development:**
- Add `BIFF.m4b` to the app bundle (e.g., in the `Development Assets` folder).
- The mock provider copies it to the Documents directory on first launch, making it available for selection in the folder picker.
- The provider also supplies `sampleAudiobookURL()` for automatic restoration in `restoreLastSelectionIfPossible()`.

This allows developers to test the full playback, bookmarking, and chapter-navigation pipeline without any network dependency or real audiobook files.

---

## Agentic Workflows

Orbit AudioBooks includes an autonomous agent workflow definition at [`.clinerules/workflows/release.md`](.clinerules/workflows/release.md). This file is consumed by Cline-compatible agents to automate the release process:

1. The agent asks the developer for the next semantic version number.
2. It updates `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION` in the Xcode project settings.
3. It stages all changes and commits with `chore: bump version to [version]`.
4. It requests permission before pushing to the remote.

When extending or modifying the project with autonomous tooling, future agents MUST:
- Read `.clinerules/workflows/release.md` before executing any version-bump or release-related task.
- Respect the font accessibility constraints documented in the **Accessibility (A11y) First** section above.
- Ensure all four platform targets remain buildable and that platform-specific compilation guards (e.g., `#if os(iOS)`, `#if os(macOS)`, `#if os(watchOS)`) are correctly maintained.

---

## License

This project is licensed under the [MIT License](LICENSE).