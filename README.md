# 🗣️ Echo: Audiobook Study Player

> For Every Mind — turn listening into learning

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)](#)
[![TestFlight](https://img.shields.io/badge/TestFlight-Beta-blue.svg)](#)
[![Platform](https://img.shields.io/badge/iOS-19+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/macOS-16+-blue.svg)](#)
[![Platform](https://img.shields.io/badge/watchOS-12+-blue.svg)](#)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**Echo** turns audiobooks into a serious study medium. Search across spoken content, jump to any passage, create flashcards from what you hear, and review with spaced repetition — all without leaving the audio.

---

## Documentation & Website

| Resource | What it covers |
|---|---|
| 🌐 [Website](https://dfakkeldy.github.io/Echo/) | Marketing home: the story, the features, the science |
| 🧠 [Getting the Most Out of Echo](https://dfakkeldy.github.io/Echo/learn.html) ([md](docs/guides/getting-the-most-out-of-echo.md)) | Every feature + the memory science behind it (context-dependent memory, spaced repetition, the testing effect, cognitive offloading…) |
| ♾️ [The Focus Field Guide](https://dfakkeldy.github.io/Echo/focus.html) ([md](docs/guides/focus-field-guide.md)) | ADHD/AuDHD strategies — task initiation, time blindness, organization, motivation, hyperfocus, distractibility — with sources |
| 📖 [User Manual](https://dfakkeldy.github.io/Echo/manual.html) ([md](docs/guides/user-manual.md)) | Complete reference: every feature on every platform, incl. library organization |
| 🛠 [Devlog](https://dfakkeldy.github.io/Echo/devlog.html) ([md](docs/guides/devlog.md)) | Week-by-week build history from the real commit log |
| 📣 [Marketing Plan](MARKETING.md) | Positioning, channels, App Store strategy (open like everything else) |
| 🏗 [ARCHITECTURE.md](ARCHITECTURE.md) · [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md) | For contributors |

> **Status tags used below:** 🚧 = **Coming in 1.0** (in active development) · 🔭 = **Roadmap** (planned after 1.0). Everything unmarked ships in the current beta.

---

## Why I Built Echo

I spend my days delivering mail. I'm in and out of my car dozens of times a shift, relying on an aux cable and dealing with constant interruptions. I listen to non-fiction to learn, but trying to absorb complex information with intermittent attention using standard audiobook apps was an exercise in frustration.

I needed an app that could loop a single chapter until I understood it. I needed to leave voice memos on bookmarks so I wouldn't forget my thoughts while driving. I needed a watch complication large enough to actually hit without looking down. And when I finally got home, I needed the audio to align perfectly with the ePub so I could look at the diagrams I had just heard about.

I couldn't find an app that did any of this persistently. So, I built it myself.

Echo is the result of a massive, month-long AuDHD spin. It brings together Spaced Repetition (SRS), smart rewind, pitch-corrected speed playback, and a library system that actually makes sense. It was designed from the ground up to support neurodivergent learning styles, but it turns out that building an app for an ADHD brain creates a powerful, friction-free tool for **every** mind.

Echo bridges the gap between reading and listening: a synced EPUB or PDF sits alongside your audiobook so you can follow the text while you hear it, jump between the two, and never lose your place. If you've ever struggled to stay focused on audio alone — or found that reading is your anchor — this hybrid approach is for you. Built for students, professionals, commuters, and anyone who learns differently.

---

## The Study Workflow

Echo is built around a simple idea: **audiobooks should be as searchable and referenceable as textbooks.** Here's how that works:

```
Add audiobook + EPUB/PDF   →   Echo aligns text to audio
          ↓
Search for any phrase   →   Jump instantly to that moment in the narration
          ↓
Lock paragraphs to timestamps   →   Build a precise, verified map of the book
          ↓
Capture while you listen   →   Bookmarks, voice memos, marks, brain-dump notes
          ↓
Review with spaced repetition   →   Retain what you learned, on your schedule
          ↓
See honest insights & export your second brain   →   Own what you learned
```

### Features Built for Focus

- **Intermittent Attention Support.** Smart rewind ensures you never lose context when you hit play after a pause. The longer you've been away, the further it rewinds — perfect for delivery drivers, commuters, and anyone with an interrupted day.
- **Chapter Looping.** Put a single chapter on repeat until the concepts are fully absorbed. Loop between bookmarks for targeted review sessions.
- **Voice Memo Bookmarks.** Instantly save your thoughts without fumbling with your phone. Perfect for driving, walking, or when your hands are full. Memos can play back inline when the narration reaches them.
- **Photo Bookmarks.** Attach a photo (from camera or library) to any bookmark; the player artwork dynamically switches to your photo as playback passes that moment. Built on *context-dependent memory* — your brain encodes where you were alongside what you heard, and the photo becomes a retrieval cue. [The science →](https://dfakkeldy.github.io/Echo/learn.html)
- **Spaced Repetition (SRS).** Built-in flashcard system using the SM-2 algorithm to help you memorize crucial facts, languages, or concepts permanently — with audio snippets on cards, Anki-style deck import, review stats, daily reminders, and hands-free review on Apple Watch.
- **Mark Now, Card Later.** 🚧 One tap (phone or watch) marks a passage without pausing playback; the **Card Inbox** turns marks into flashcards when you have the bandwidth. Retires mid-playback popups for good.
- **Decks, Tags & Real Anki Import.** 🚧 Organize cards into decks with tags, edit any card, review per deck — and import genuine `.apkg` Anki decks with scheduling history preserved. JSON deck export round-trips losslessly.
- **Brain Dump / Book Notes.** 🚧 A frictionless mental inbox: park any thought — text or voice, even dictated from the watch — without pausing the book, then promote keepers to bookmarks or flashcards. Built for leaky working memory.
- **Context Memory (opt-in).** 🚧 Echo can tag bookmarks, sessions, and chapter starts with an approximate place name ("Chapter 3 started at Oak Street") — context-dependent memory, automated. Off by default, reduced accuracy, deletable in one tap, session history never syncs.
- **Insights.** 🚧 A dedicated stats screen computed entirely on-device: listening time by day/week/month/year, streaks, per-chapter coverage heatmaps ("Ch 7 — 86%, listened 3×"), speed trends, time-of-day patterns, retention curves, grade distributions, and a 30-day review forecast.
- **Second-Brain Export.** 🚧 Per-book Markdown bundles — bookmarks, notes, flashcards, voice memos, photos — that drop straight into Obsidian, Logseq, or Notion. Plain files, relative links, no accounts, no lock-in. (Bookmark Markdown export ships today.)
- **iCloud Study Sync.** 🚧 Flashcards, decks, bookmarks, and playback position across iPhone, Mac, and Watch via your personal iCloud — Echo runs no servers.
- **True ePub & PDF Alignment.** Seamlessly scroll through the text and view diagrams exactly when the audio reaches that section. On-device auto-alignment (WhisperKit + CoreML) maps every paragraph to the narration — no cloud API calls, no privacy concerns. PDF companion documents are supported with page-level alignment and per-page screenshot bookmarks.
- **Pristine Speed Control.** Listen at 1.25x (or faster) with zero pitch distortion. Speed suggestions adapt to your listening habits.
- **Apple Watch Remote.** A massive, user-configurable interface with up to 25 customizable buttons across 5 pages. Assign the Digital Crown to control volume or scrub through audio — leave your phone in your pocket.
- **Designed for Neurodiversity.** Lexend and OpenDyslexic fonts — both backed by reading-fluency research — are built in. The hybrid document+audio view means you're never forced to learn by listening alone. The app icon (an infinity symbol in silver and gold) is a nod to the AuDHD community. The name "Echo" reflects how many neurodivergent brains work: ideas echoing between different modes of thinking, with text and audio reinforcing each other.

---

## The Road to v1.0

Echo has a defined 1.0:

> **Echo 1.0 is a trustworthy study player on iPhone (full), Apple Watch (companion), and Mac (functional core), with real listening/study analytics, a complete intentional-flashcard workflow including real Anki deck import, and study-state sync across devices.**

The program runs as dependency-ordered workstreams (~14 weeks solo), each landing on its own branch with tests-first plans and verification gates:

| # | Workstream | What ships |
|---|---|---|
| WS0 | **Listening capture layer** | The playback-event recorder — ships *first* so insights data accumulates from the next beta build onward |
| WS1 | **Identity & macOS foundation** | The Echo rebrand completed through every identifier, and the Mac target on a solid footing |
| WS2 | **CI** | GitHub Actions compiles every scheme + the test target on each PR (the unit/integration suites run locally via `make test` while the CI runner's iOS simulator carries an Apple isolated-deinit runtime bug) |
| WS3–4 | **Insights** | Stats backend (pure, tested aggregation) + the Insights screen with Swift Charts and live dashboard modules |
| WS5 | **Context Memory** | Opt-in, reduced-accuracy place capture on sessions, bookmarks, and chapter starts — privacy-first, deletable |
| WS6 | **Anki core** | Decks + tags schema, the mark-later Card Inbox, a full card editor, deck management; inline popups retire |
| WS6b | **Brain Dump / Book Notes** | Untethered per-book notes, global voice-memo inbox, watch dictation |
| WS7 | **Import/Export** | Real `.apkg` import (scheduling preserved), JSON deck export, Markdown second-brain bundle export |
| WS8 | **iCloud study sync** | Flashcards, decks, bookmarks, playback position — private database, sensible conflict rules |
| WS8b | **Audiobookshelf integration** | Connect a self-hosted Audiobookshelf server; pull books (audio + any bundled EPUB) into the local pipeline so alignment/flashcards/search keep working; browse & search the library by topic/genre/series; two-way playback-progress sync. *Streaming deferred post-1.0 — see [ROADMAP.md](ROADMAP.md) Phase 9.* Lands after the on-device narration (Kokoro) work, before WS9. |
| WS9 | **Polish & release** | Onboarding (incl. a library-organization step), reader speed controls, alignment celebration, Mac stats/review panes, TestFlight beta → release |
| WS10 | **Docs & site content** | Study-workflow guides, organization training, context-memory explainer — published as features ship |

**Deliberately after 1.0** (each with its seam already designed): FSRS scheduling, `.apkg` export, AnkiConnect, on-device AI card drafting, focus soundscapes, hyperfocus/transition alarms, Context Memory map view, CarPlay capture buttons, full Mac reader parity. See [ROADMAP.md](ROADMAP.md).

---

## Overview

Echo is a full-featured audiobook study application organized as a single Xcode workspace with four distinct targets. It supports bookmarking with optional voice memos, chapter navigation, loop modes, a sleep timer, variable playback speed, and intelligent rewind logic that adapts to pause duration. The iOS and watchOS apps communicate bidirectionally via WatchConnectivity, while a Widget displays the current playback state on the Home Screen / Lock Screen.

When you add an EPUB or PDF file alongside your audiobook, Echo unlocks its study toolkit: a searchable, browsable reader with per-paragraph audio alignment. Long-press any paragraph or PDF page to lock it to the current playback position, color-code important passages, or create timestamped bookmarks. Use **Auto-Align Chapters** to let Echo automatically align every chapter — it first matches audiobook chapter titles (from M4B metadata) against EPUB headings instantly, with no ML required, then falls back to on-device speech recognition (WhisperKit + CoreML) for any remaining chapters, transcribing short clips and fuzzy-matching them against the EPUB text (Levenshtein + Jaccard) to create precise alignment anchors. Drift detection finds misaligned chapters, and drift repair uses TokenDTW (Dynamic Time Warping) to insert correction anchors at word-level precision. Optional **Continuous Alignment** runs in the background during playback. For PDF documents, use the **Manual Alignment** sheet with the scrubber joystick for fine-tuned alignment.

---

## Architecture

The workspace is composed of four targets, each with its own entry point and view hierarchy:

| Target | Bundle Identifier / Entry Point | Purpose |
|---|---|---|
| **EchoCore** (`iOS/iPadOS`) | `EchoCoreApp.swift` → `RootTabView.swift` | Primary audiobook player. Uses a 3-tab layout (NowPlayingTab, ReaderTab with EPUB/PDF alignment and full-text search, PlaylistTab). PlayerModel acts as a thin coordinator over 20+ single-responsibility services. Handles file/folder selection, bookmarks, voice memos, WatchConnectivity, and Now Playing integration. When an EPUB or PDF file is loaded alongside the audiobook, the Reader tab provides a searchable, browsable book with per-paragraph alignment (EPUB) or page-level alignment (PDF). |
| **Echo macOS** (`macOS`) | `Echo_macOSApp.swift` → `MacContentView.swift` | Native macOS desktop companion. Uses `MacPlayerModel` (`@Observable`-based) with a `NavigationSplitView` layout: a bookmarks sidebar, a player pane with transport controls and a speed picker, and EPUB alignment via `MacGlobalAlignmentService` with streaming audio transcription support. |
| **Echo Watch App** (`watchOS`) | `EchoCoreWatchApp.swift` → `ContentView.swift` | Wearable remote for the iOS player. Communicates with the phone via `WCSession` to send play/pause, skip, scrub, volume, loop mode, sleep timer, section navigation, and bookmark commands. Features a customizable button layout with up to five pages of five action slots each (25 total), with configurable seek forward/backward durations (5–60s), all syncable from the phone. |
| **Echo Widget** (`Widgets`) | `Echo_WidgetBundle.swift` → `Echo_Widget.swift` | A `WidgetBundle` exposing a `StaticConfiguration` widget (`.accessoryCircular`) that shows the current track title, progress ring, and thumbnail via `AppGroupDefaults` communication. Also includes a `TogglePlaybackIntent` (App Intent) for Control Center / widget interactions. |

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
	- **`AutoAlignmentService`** — On-device auto-alignment via a progressive 4-tier pipeline: metadata title matching (Tier 0, `ChapterTitleMatcher`, no ML), VAD chunking + TokenDTW (Tier 1, WhisperKit), drift detection (Tier 2), drift repair (Tier 3), and manual fine-tuning.
	- **`AutoAlignmentTextMatcher`** — Fuzzy text matching (Levenshtein + word-level Jaccard) for matching transcribed audio against EPUB paragraphs.
	- **`TokenDTW`** — Dynamic Time Warping aligner for word-level EPUB-to-audio token matching. Uses flat Int32/Int8 arrays for memory-efficient 3000×3000 token grid alignment with Levenshtein-like fuzzy matching. Replaces the earlier silence-mapping approach (Tier 0) for drift repair.
- **`SilenceDetectionService`** — AVAudioFile + Accelerate-based silence gap detection. Retained for potential future use; no longer part of the active alignment pipeline.
	- **`EPUBImportService`** — Parses EPUB files into `epub_block` records: extracts the OPF spine, parses XHTML, copies images to Application Support.
		- **`PDFImportCoordinator`** — Copies PDF files into the audiobook folder with security-scoped resource access. Same-folder imports are no-ops to prevent file corruption.
		- **`PDFViewState`** — Codable model capturing PDF page index, zoom scale, and scroll offset for persistent bookmark restoration across app restarts.
		- **`PDFDocumentView`** — SwiftUI view wrapping `PDFKit.PDFView` for in-app PDF reading with long-press context menus for alignment and bookmarking.
		- **`ManualAlignmentSheet`** — Modal alignment UI with play/pause, ±5s skip, a `ScrubberJoystick` for fine-grained scrubbing, and audio snippet preview during adjustment.
		- **`ScrubberJoystick`** — Horizontal drag-track control with spring-return and exponential mapping (small pulls = slow, big pulls = fast) for precise scrubbing.
	- **`EPUBXMLParsing`** — Shared EPUB XML parser delegates (`ContainerXMLParser`, `OPFParserDelegate`, `XHTMLBlockDelegate`) deduplicated across iOS and macOS — each platform previously carried ~190 lines of identical parsing code.
	- **`WhisperSession`** — Reference-counted, shared WhisperKit model manager. Prevents duplicate ~40 MB model loads when both `AutoAlignmentService` and `ContinuousAlignmentService` are active.
	- **`ContinuousAlignmentService`** — Background audio capture and transcription: samples 15-second audio windows during playback, transcribes via WhisperKit, and inserts alignment anchors on-the-fly.
	- **`FileLocations`** — Centralized directory access (`documentsDirectory`, `cachesDirectory`, `applicationSupportDirectory`, `epubUnpackedDirectory(safeID:)`) replacing ad-hoc `FileManager.default.urls(for:in:)` calls across the codebase.
	- **`KeychainStore`** — Thin Keychain wrapper for storing security-scoped bookmark data and other sensitive blobs that should not live in unencrypted `UserDefaults`.
	- **`Logger+Subsystem`** — Single `"com.echo.audiobooks"` subsystem constant used by every logger in the project — prevents log fragmentation from typos in repeated string literals.
	- **`Schema_V11`** — Database migration adding `pdf_view_state_json` (TEXT) columns to `bookmark` and `timeline_item` tables for PDF page/zoom/scroll state persistence.
		- **`AnimationDurations`** — Named animation timing constants (`.micro`, `.standard`, `.emphasized`, `.slow`) to replace magic-number literals scattered across view bodies.
	- **`AudioSnippetPlayer`** — Lightweight, single-use audio player for voice-memo previews and bookmark playback. Eliminates the ad-hoc `AVAudioEngine` setup duplicated across `BookmarkStore`, `Bookmarks`, and `SnippetPlayer`.

---

## Accessibility (A11y) First

Echo is built with accessibility as a core principle, not an afterthought.

### Neurodivergent-Friendly Design

Echo is built from the ground up for the AuDHD (Autism + ADHD) and broader neurodivergent community. The core premise — a **hybrid reading + listening** experience — was inspired by the realization that many neurodivergent people struggle to learn from audio alone and need text as an anchor to stay engaged.

### Dyslexia-Optimized Typography

The project bundles two specially-selected font families to support dyslexic and neurodivergent readers:

- **Lexend** ([`EchoCore/Fonts/Lexend.ttf`](EchoCore/Fonts/Lexend.ttf) and [`Echo macOS/Fonts/Lexend.ttf`](Echo%20macOS/Fonts/Lexend.ttf)) — A typeface designed with research-backed letter spacing and proportions to improve reading fluency and reduce visual crowding.
- **OpenDyslexic** ([`EchoCore/Fonts/OpenDyslexic-Regular.otf`](EchoCore/Fonts/OpenDyslexic-Regular.otf) and [`Echo macOS/Fonts/OpenDyslexic-Regular.otf`](Echo%20macOS/Fonts/OpenDyslexic-Regular.otf)) — An open-source font weighted at the bottom to combat letter reversal and rotation, widely adopted by the dyslexia community.

### App Icon & Colors: An AuDHD Shoutout

The Echo app icon features an **infinity symbol (∞) in silver and gold** — a deliberate nod to the AuDHD community:

- **Infinity symbol (∞)**: Widely adopted by the neurodivergent community to represent the infinite variations and possibilities of the human mind — the idea that there is no single "correct" way to think, learn, or process information.
- **Silver & gold**: The AuDHD community's colors, representing the dual nature of autism (Au) and ADHD (DHD), and the unique strengths that come from this combination.
- **"Echo"**: The name itself speaks to the way many AuDHD brains work — ideas echoing back and forth between different modes of thinking, with text and audio reinforcing each other.

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
| **EchoTests** | `EchoTests.swift` | Unit tests for the iOS model layer (playback logic, bookmark persistence, timer logic). |
| **EchoUITests** | `EchoUITests.swift`, `EchoUITestsLaunchTests.swift` | UI integration tests for the iOS app using XCUITest. |
| **Echo Watch AppTests** | `Echo_Watch_AppTests.swift` | Unit tests for watchOS model and WCSession command parsing. |
| **Echo Watch AppUITests** | `Echo_Watch_AppUITests.swift` | UI tests for the watch app (launch validation, button interaction). |

Run all tests from Xcode with `⌘U` or via the terminal:

```bash
xcodebuild test \
  -project Echo.xcodeproj \
  -scheme "Echo" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

### MockMediaProvider

[`MockMediaProvider.swift`](EchoCore/MockMediaProvider.swift) is a `#if DEBUG`-only utility that seeds a sample audiobook (`BIFF.m4b`) into the simulator's Documents directory on first launch. It is automatically invoked during `DEBUG && targetEnvironment(simulator)` builds in the app's `init()`.

A development EPUB fixture is also available for testing the reader pipeline:

```
EchoCore/Development Assets/aliceinwonderland_1102_librivox/
└── Alice's Adventures in Wonderland.epub  ← Lewis Carroll (EPUB)
```

In `#if DEBUG` builds, `SettingsView` exposes a "Load Development Assets" button under a "Debug Menu" section. This invokes `PlayerModel.loadFolder()` with the main bundle URL, seeding the sample audiobook for immediate testing of the reader, alignment, and search features without requiring external file selection.

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

### Credits

- **[Paul Hudson](https://github.com/twostraws) ([@twostraws](https://github.com/twostraws))** — This project's [`AGENTS.md`](AGENTS.md) is adapted from Paul's [AGENTS.md template](https://github.com/twostraws/AGENTS.md), which has become the standard for guiding AI-assisted Swift and SwiftUI development.

---

## License

This project is licensed under the [MIT License](LICENSE).
