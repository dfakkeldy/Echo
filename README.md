# 🗣️ Echo: Audiobook Study Player

> Turn listening into learning

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)](#)
[![TestFlight](https://img.shields.io/badge/TestFlight-Beta-blue.svg)](#)
[![Platform](https://img.shields.io/badge/iOS-19+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/macOS-16+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/watchOS-12+-blue.svg)](#)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**Echo** turns audiobooks into a serious study medium. Search across spoken content, jump to any passage, create flashcards from what you hear, and review with spaced repetition — all without leaving the audio. Built for students, professionals, and anyone who learns by listening.

---

## The Study Workflow

Echo is built around a simple idea: **audiobooks should be as searchable and referenceable as textbooks.** Here's how that works:

```
Add audiobook + EPUB   →   Echo aligns text to audio
          ↓
Search for any phrase   →   Jump instantly to that moment in the narration
          ↓
Lock paragraphs to timestamps   →   Build a precise, verified map of the book
          ↓
Create bookmarks & flashcards   →   Capture knowledge while you listen
          ↓
Review with spaced repetition   →   Retain what you learned, on your schedule
```

### Why This Matters

- **Find anything, instantly.** Heard a great passage but can't remember where? Type a few words — Echo finds it in the EPUB and seeks the audio to that exact moment.
- **Study while you listen.** Long-press any paragraph to align it to the current playback position, color-code important passages, or create timestamped bookmarks and flashcards.
- **Retain more.** Echo's built-in spaced repetition system (SM-2 algorithm) schedules flashcards for optimal retention — review on your phone or Apple Watch during idle moments.
- **Learn hands-free.** The customizable Apple Watch app lets you control playback, create bookmarks, and review flashcards between deliveries, during commutes, or while working out.

---

## Overview

Echo is a full-featured audiobook study application organized as a single Xcode workspace with four distinct targets. It supports bookmarking with optional voice memos, chapter navigation, loop modes, a sleep timer, variable playback speed, and intelligent rewind logic that adapts to pause duration. The iOS and watchOS apps communicate bidirectionally via WatchConnectivity, while a Widget displays the current playback state on the Home Screen / Lock Screen.

When you add an EPUB file alongside your audiobook, Echo unlocks its study toolkit: a searchable, browsable reader with per-paragraph audio alignment. Long-press any paragraph to lock it to the current playback position, color-code important passages, or create timestamped bookmarks. Use **Auto-Align Chapters** to let on-device speech recognition (WhisperKit + CoreML) automatically align every chapter — it maps silence gaps to chapter boundaries (Tier 0), transcribes short clips at chapter starts, fuzzy-matches them against the EPUB text (Levenshtein + Jaccard), and creates precise alignment anchors. A drift-detection system finds and repairs misaligned chapters. Optional **Continuous Alignment** runs in the background during playback.

---

## Architecture

The workspace is composed of four targets, each with its own entry point and view hierarchy:

| Target | Bundle Identifier / Entry Point | Purpose |
|---|---|---|
| **EchoCore** (`iOS/iPadOS`) | `Echo_AudioBooksApp.swift` → `RootTabView.swift` | Primary audiobook player. Uses a 3-tab layout (NowPlayingTab, ReaderTab with EPUB alignment and full-text search, PlaylistTab). PlayerModel acts as a thin coordinator over 20+ single-responsibility services. Handles file/folder selection, bookmarks, voice memos, WatchConnectivity, and Now Playing integration. When an EPUB file is loaded alongside the audiobook, the Reader tab provides a searchable, browsable book with per-paragraph audio alignment. |
| **Echo: Audiobook Study Player macOS** (`macOS`) | `Echo_Audiobooks_macOSApp.swift` → `MacContentView.swift` | Native macOS desktop companion. Uses `MacPlayerModel` (`@Observable`-based) with a `NavigationSplitView` layout: a bookmarks sidebar, a player pane with transport controls and a speed picker, and EPUB alignment via `MacGlobalAlignmentService` with streaming audio transcription support. |
| **Echo: Audiobook Study Player Watch App** (`watchOS`) | `EchoCoreWatchApp.swift` → `ContentView.swift` | Wearable remote for the iOS player. Communicates with the phone via `WCSession` to send play/pause, skip, scrub, volume, loop mode, sleep timer, section navigation, and bookmark commands. Features a customizable button layout with up to five pages of five action slots each (25 total), with configurable seek forward/backward durations (5–60s), all syncable from the phone. |
| **Echo: Audiobook Study Player Widget** (`Widgets`) | `Echo_Audiobooks_WidgetBundle.swift` → `Echo_Audiobooks_Widget.swift` | A `WidgetBundle` exposing a `StaticConfiguration` widget (`.accessoryCircular`) that shows the current track title, progress ring, and thumbnail via `AppGroupDefaults` communication. Also includes a `TogglePlaybackIntent` (App Intent) for Control Center / widget interactions. |

Shared models and utilities used across targets include:

- **`PlayerModel`** — Central iOS/iPadOS coordinator (`@Observable`), wires together 20+ focused services (PlaybackController, BookmarkStore, SleepTimerManager, ChapterLoadingCoordinator, PlaybackProgressPresenter, PlayerLoadingCoordinator, BookmarkArtworkCoordinator, PlayerTimelinePersistenceService, PlaylistManager, ChapterGroupingService, etc.) via closure injection in `init()`. Each service owns a single responsibility; PlayerModel provides thin pass-through computed properties for SwiftUI view binding. Supports section-level navigation within chapters (Libation-style sub-sections), a compact player layout mode, and haptic-scrubbing through section tick marks on the scrubber rail.
- **`MacPlayerModel`** — macOS-specific playback model wrapping AVPlayer with its own bookmark format (`MacBookmark`), security-scoped bookmarks, and UserDefaults persistence.
- **`Bookmark.swift`** — The `Bookmark` struct (Codable, Equatable, Hashable) representing a saved position, with optional text note and voice memo filename. Includes `VoiceMemoRecorder` and `EditBookmarkView` for recording/editing.
- **`AppIntent.swift`** — Shared `AppGroupDefaults` suite and `SessionDelegator` for WCSession activation, enabling the widget and app intents to toggle playback.
- **`LayoutPreset.swift`** — `WatchPreset` and `PhonePreset` data models (Codable, Identifiable) for customizable watch button layouts (up to 5 pages × 5 slots) and phone transport control layouts (5-slot tap actions + 5-slot long-press secondary actions). The action palette includes play/pause, skip, next/previous track, next/previous section, loop mode, speed, sleep timer, and bookmark. Presets sync bidirectionally via WatchConnectivity and persist in UserDefaults.
- **`WatchAction.swift`** — Enumeration of all available transport actions (`playPause`, `skipForward`, `skipBackward`, `nextTrack`, `previousTrack`, `nextSection`, `previousSection`, `loopMode`, `speed`, `sleepTimer`, `bookmark`, `empty`) with SF Symbol icon mappings and watch command routing strings.
- **`ChapterGroupingService.swift`** — Detects and collapses Libation-style sub-section chapter atoms (e.g. "Chapter 11. A" / "Chapter 11. B") into logical chapters, retaining sub-sections for scrubber tick marks and section-level navigation.
- **Shared Font Assets** — `Lexend.ttf` and `OpenDyslexic-Regular.otf` are bundled in both the iOS and macOS targets for accessibility-optimized typography.
	- **`ReaderFeedViewModel`** — View model for the EPUB reader feed. Loads blocks from `EPubBlockDAO`, supports full-text search, and tracks the active block via binary search for O(log N) playback sync.
	- **`ReaderCardItem`** — Enum for reader feed items (`.chapterHeader` and `.block(EPubBlockRecord)`), rendered as cards in a `UICollectionView`.
	- **`ReaderSettings`** — User-configurable reader settings: font size, line spacing, and card background tint color.
	- **`AlignmentService`** — Manual EPUB-to-audio alignment through locked anchors and word-count-weighted proportional interpolation with dynamic CPS projection.
	- **`AutoAlignmentService`** — On-device WhisperKit-based auto-alignment: silence mapping (Tier 0), chapter snap (Tier 1), drift detection (Tier 2), drift repair (Tier 3), and manual fine-tuning.
	- **`AutoAlignmentTextMatcher`** — Fuzzy text matching (Levenshtein + word-level Jaccard) for matching transcribed audio against EPUB paragraphs.
	- **`SilenceDetectionService`** — AVAudioFile + Accelerate-based silence gap detection for chapter boundary mapping.
	- **`EPUBImportService`** — Parses EPUB files into `epub_block` records: extracts the OPF spine, parses XHTML, copies images to Application Support.
	- **`EPUBXMLParsing`** — Shared EPUB XML parser delegates (`ContainerXMLParser`, `OPFParserDelegate`, `XHTMLBlockDelegate`) deduplicated across iOS and macOS — each platform previously carried ~190 lines of identical parsing code.
	- **`WhisperSession`** — Reference-counted, shared WhisperKit model manager. Prevents duplicate ~40 MB model loads when both `AutoAlignmentService` and `ContinuousAlignmentService` are active.
	- **`ContinuousAlignmentService`** — Background audio capture and transcription: samples 15-second audio windows during playback, transcribes via WhisperKit, and inserts alignment anchors on-the-fly.
	- **`FileLocations`** — Centralized directory access (`documentsDirectory`, `cachesDirectory`, `applicationSupportDirectory`, `epubUnpackedDirectory(safeID:)`) replacing ad-hoc `FileManager.default.urls(for:in:)` calls across the codebase.
	- **`KeychainStore`** — Thin Keychain wrapper for storing security-scoped bookmark data and other sensitive blobs that should not live in unencrypted `UserDefaults`.
	- **`Logger+Subsystem`** — Single `"com.orbitaudiobooks"` subsystem constant used by every logger in the project — prevents log fragmentation from typos in repeated string literals.
	- **`AnimationDurations`** — Named animation timing constants (`.micro`, `.standard`, `.emphasized`, `.slow`) to replace magic-number literals scattered across view bodies.
	- **`AudioSnippetPlayer`** — Lightweight, single-use audio player for voice-memo previews and bookmark playback. Eliminates the ad-hoc `AVAudioEngine` setup duplicated across `BookmarkStore`, `Bookmarks`, and `SnippetPlayer`.

---

## Accessibility (A11y) First

Echo is built with accessibility as a core principle, not an afterthought.

### Dyslexia-Optimized Typography

The project bundles two specially-selected font families to support neurodiverse readers:

- **Lexend** ([`EchoCore/Fonts/Lexend.ttf`](EchoCore/Fonts/Lexend.ttf) and [`Echo: Audiobook Study Player macOS/Fonts/Lexend.ttf`](Echo%20Audiobooks%20macOS/Fonts/Lexend.ttf)) — A typeface designed with research-backed letter spacing and proportions to improve reading fluency and reduce visual crowding.
- **OpenDyslexic** ([`EchoCore/Fonts/OpenDyslexic-Regular.otf`](EchoCore/Fonts/OpenDyslexic-Regular.otf) and [`Echo: Audiobook Study Player macOS/Fonts/OpenDyslexic-Regular.otf`](Echo%20Audiobooks%20macOS/Fonts/OpenDyslexic-Regular.otf)) — An open-source font weighted at the bottom to combat letter reversal and rotation, widely adopted by the dyslexia community.

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
| **EchoCoreTests** | `EchoCoreTests.swift` | Unit tests for the iOS model layer (playback logic, bookmark persistence, timer logic). |
| **EchoCoreUITests** | `EchoCoreUITests.swift`, `EchoCoreUITestsLaunchTests.swift` | UI integration tests for the iOS app using XCUITest. |
| **Echo: Audiobook Study Player Watch AppTests** | `Echo_Audiobooks_Watch_AppTests.swift` | Unit tests for watchOS model and WCSession command parsing. |
| **Echo: Audiobook Study Player Watch AppUITests** | `Echo_Audiobooks_Watch_AppUITests.swift` | UI tests for the watch app (launch validation, button interaction). |

Run all tests from Xcode with `⌘U` or via the terminal:

```bash
xcodebuild test \
  -workspace Echo\ Audiobooks.xcodeproj \
  -scheme "Echo: Audiobook Study Player" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

### MockMediaProvider

[`MockMediaProvider.swift`](EchoCore/MockMediaProvider.swift) is a `#if DEBUG`-only utility that seeds a sample audiobook (`BIFF.m4b`) into the simulator's Documents directory on first launch. It is automatically invoked during `DEBUG && targetEnvironment(simulator)` builds in the app's `init()`.

**Usage during development:**
- Add `BIFF.m4b` to the app bundle (e.g., in the `Development Assets` folder).
- The mock provider copies it to the Documents directory on first launch, making it available for selection in the folder picker.
- The provider also supplies `sampleAudiobookURL()` for automatic restoration in `restoreLastSelectionIfPossible()`.

This allows developers to test the full playback, bookmarking, and chapter-navigation pipeline without any network dependency or real audiobook files.

---

## Agentic Workflows

Echo includes an autonomous agent workflow definition at [`.clinerules/workflows/release.md`](.clinerules/workflows/release.md). This file is consumed by Cline-compatible agents to automate the release process:

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
