# Changelog

All notable changes to Echo: Audiobook Study Player.

## [Unreleased]

### Added
- **On-device AI narration — synthesis engine (Kokoro-82M):** The narration engine core (below) now has a real on-device voice. `KokoroTTSEngine` implements the `TTSEngine` seam against the Kokoro-82M CoreML model via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s `KokoroAneManager` (Neural Engine), with a `MisakiPhonemizer` grapheme-to-phoneme front end (Apache-licensed; no GPL espeak-ng) and an `AVFoundationAudioWriter` that concatenates 24 kHz mono PCM chunks into one AAC file per chapter. Synthesis verified producing audio on-device. Narration UI components (`VoicePickerView`, `NarrationStatusView`, `NarrationNudgeView`) and `BookDetailViewModel` orchestration land alongside; per-chapter and `.m4b` export (`NarrationExportService`) are in progress.
- **On-device narration engine core (Schema V17) — Plan 1:** Foundation for generating AI-narrated audio from study EPUBs that have no audiobook (additive — the WhisperKit alignment pipeline is unchanged). Adds the `TTSEngine`/`AudioFileWriting` seams, `VoiceCatalog` (curated voices, default "Ava"), a pure `TextNormalizer` (abbreviations, thousands separators, Roman-numeral chapters, em-dash pauses), an observable `NarrationState` (mirrors `AutoAlignmentState`), and `NarrationService.renderChapter` — which writes one AAC `track` per chapter plus one `.synthesized` `AlignmentAnchorRecord` per text block, all unit-tested behind a mock engine. Schema V17 adds the nullable `track.narration_voice` column (non-null marks a synthesized track) and a new `AlignmentAnchorRecord.Source.synthesized` case. The real on-device model (Kokoro) now ships (see above); the read-first Listen UI wiring follows. Design: `docs/superpowers/specs/2026-06-13-epub-ai-narration-design.md`.
- **Accessibility — VoiceOver scrubber:** the `ScrubberJoystick` manual-alignment control is now exposed to VoiceOver with an adjustable trait and value updates.
- **Hierarchical Table of Contents from the publisher's TOC (Schema V13):** EPUB import now preserves the book's declared TOC tree — NCX `navPoint` nesting (EPUB 2) or nav `<ol>` nesting (EPUB 3) — instead of flattening it to per-file labels. Entries persist as `epub_toc_entry` rows (parent links, preorder order, depth, publisher titles) resolved to concrete blocks via fragment anchors (`#its_your_life` → the block carrying that element id), with first-heading/first-block fallbacks. The Reader's TOC sheet now shows the publisher's hierarchy and titles ("1. A Pragmatic Philosophy" → "Topic 3. Software Entropy") rather than headings guessed from markup; heading inference remains as fallback for books without a declared TOC. **Re-import is required for existing books to gain the hierarchy.**
- **Section titles that aren't heading tags are recognized:** TOC entries that resolve to a non-heading block (e.g. The Pragmatic Programmer marks topic titles up as layout tables) are promoted to heading blocks when their text matches the TOC label (punctuation-insensitive + Levenshtein ≥ 0.85 gate), so they style, anchor, and navigate like real headings.
- **Playback segment capture:** Added async listening-segment recording to the `playback_event` table for detailed analytics. Consumed via `PlaybackSessionRecorder` (actor) from an event stream and built using `PlaybackSegmentBuilder` (pure state machine) with 5-second noise discarding and 30-second heartbeats for crash safety.
- **Schema V14 database migration:** Added `idx_playback_event_started_at` index, `session_location` table (WS5 context), bookmark location columns, note global/voice-memo columns, and event-integrity backfills.

### Fixed
- **Glued titles at element boundaries:** text split across structural child elements — `<span>Chapter 1</span><br/><span>A Pragmatic Philosophy</span>`, `<td>Topic 3</td><td>Software Entropy</td>` — no longer concatenates without a space ("Chapter 1A Pragmatic Philosophy", "Topic 3Software Entropy"). Inline formatting tags (`<em>un</em>do`) and entity-split words (`it&#8217;s`) still join with no separator.
- **Reader breadcrumb ancestry:** the pinned header now follows the publisher's TOC path for the current position (e.g. "1. A Pragmatic Philosophy › Topic 2. The Cat Ate My Source Code › Challenges") instead of the heading-level cascade that could pin an early `<h1>` ("Foreword") as a permanent top-level ancestor. The cascade remains as fallback for books without a declared TOC.
- **PDF companion document support:** Import PDF files alongside audiobooks for page-level alignment and bookmarking. `PDFDocumentView` wraps `PDFKit.PDFView` with auto-scale, continuous vertical scroll, and long-press context menus for alignment. `PDFViewState` (page index, zoom, scroll offset) persists in bookmarks via `pdf_view_state_json` column (Schema V11). `PDFImportCoordinator` handles security-scoped file copy with same-folder no-op prevention. PDF bookmark screenshots render the current page to JPEG for thumbnail images.
- **Manual alignment with scrubber joystick:** `ManualAlignmentSheet` provides fine-tuned alignment with play/pause, ±5s skip, and a `ScrubberJoystick` — a horizontal drag-track control with spring-return and exponential mapping (small pulls = slow, big pulls = fast) for precise scrubbing. Audio snippet preview plays during scrub for real-time feedback.
- **Hierarchical chapter titles:** `PlaylistView.computeHierarchicalTitles(for:)` detects parent-child relationships between consecutive chapter titles via prefix matching, formatting nested chapters with leading dots (e.g., "Part 1", ".Chapter 1", "..Section A") for visually scannable playlist hierarchies.
- **Reader tab three-level header:** Sticky reader header now displays Part → Chapter → Section hierarchy. When a part title exists, the chapter title renders smaller and in secondary color, creating visual depth. `ReaderFeedCollectionView` receives a `$topPartTitle` binding alongside existing title bindings.
- **Watch title scroll speed setting:** `watchTitleScrollSpeed` (Double, defaults to 30.0) controls the pixels-per-second scrolling rate for long titles in the watch player, configurable in `WatchAppSettingsView`.
- **Schema V11:** `pdf_view_state_json` (TEXT) columns added to `bookmark` and `timeline_item` tables for PDF view state persistence.
- **Proportional word-count alignment (Schema V8):** `word_count` column on `epub_block` enables alignment interpolation weighted by paragraph content length rather than raw sequence index. Longer paragraphs get proportionally wider time ranges; shorter ones are more tightly positioned. Improves accuracy for chapters with uneven prose/dialogue mixing.
- **Anchor management:** "Erase Anchor" removes a single locked anchor from a block; "Reset Alignment" clears all anchors for the current audiobook. Both trigger timeline recalculation. Available via context menu on locked-anchor cards in both the Reader and Timeline feeds.
- **Reader-specific bottom toolbar:** When the Read tab is active, `BottomToolbarView` switches to reader-optimized controls (skip back, play/pause, skip forward, timeline, bookmark) instead of the standard transport layout. Skip durations use configurable seek settings with dynamic SF Symbol naming.
- **Anchor status indicators:** Locked-anchor cards show a green badge — a timestamp label (Reader feed) or 🔗 icon (Timeline feed) — distinguishing manually-aligned items from interpolated/estimated ones.
- **Debug development assets:** Alice in Wonderland EPUB fixture (`aliceinwonderland_1102_librivox/`) under Development Assets, loadable via a `#if DEBUG` "Load Development Assets" button in Settings for instant reader pipeline testing.
- Mini-player control bar (`PlayerControlBar`) on the Timeline tab — appears above the bottom toolbar when a book is loaded, showing artwork, title/chapter metadata, and play/pause. Tap to open the full NowPlaying player.
- Configurable seek forward/backward durations (5–60s), synced between phone and watch.
- **Watch expanded to 5 pages** — up to 25 customizable action slots (5 pages × 5 slots) with per-page configuration and TabView-style page swiping in settings. Empty pages auto-hide on the watch.
- **Phone transport long-press actions** — each of the 5 transport buttons now supports a configurable long-press secondary action (`TransportButton` / `TransportPrimitiveButtonStyle`) with haptic feedback, configurable via a "Tap Actions" / "Long Press" segmented picker in `PhonePlayerSettingsView`.
- Customizable watch button layout presets — drag-and-drop configuration from the phone via `WatchAppSettingsView`.
- `LayoutPreset` data model (`WatchPreset`, `PhonePreset`) with WatchConnectivity sync and UserDefaults persistence. `WatchPreset` supports optional `page3`/`page4`/`page5` fields; `PhonePreset` supports optional `longPressSlots`.
- Configurable default playback speed per-book and globally.
- Theme accent color setting.
- Local watch playback timer with independent progress tracking.
- `os.log` migration for structured logging across all targets.
- GitHub Pages marketing site and privacy policy page.
- **Marketing & documentation suite (2026-06-09):** website rebranded Orbit→Echo and expanded with `learn.html` (learning-science guide), `manual.html` (complete user manual), and `devlog.html` (weekly build history from git log); markdown sources in `docs/guides/`; `MARKETING.md` strategy doc with positioning, channel plan, and a shipped-vs-vision honesty ledger; App Store metadata refreshed (photo bookmarks, PDF, Pomodoro; keywords brought under the 100-character limit). **TestFlight suite:** `beta.html` tester funnel page + `docs/guides/testflight-beta-guide.md` (six structured test plans, feedback how-to, beta privacy notes); version-controlled beta copy in `fastlane/testflight/` (`beta_app_description.txt`, `what_to_test.txt`) wired into the `beta` lane via `changelog:`/`beta_app_description:`; privacy policy gains a TestFlight section.
- Timeline freeze mode for EPUB browsing with sync-and-resume anchoring.
- **Chapter grouping service** (`ChapterGroupingService`): detects and collapses Libation-style sub-section chapter atoms into logical chapters. Handles patterns like "Chapter 11. A" / "Chapter 11. B" → single "Chapter 11" spanning the full time range, with original sub-sections retained for scrubber tick marks.
- **Section navigation**: new `.nextSection` and `.previousSection` `WatchAction` cases for skipping between sub-section boundaries within chapters. Available on both phone transport controls and watch button layouts.
- **Section scrubber ticks**: `SectionTickOverlay` renders hairline tick marks on the scrubber rail at each sub-section boundary, with magnetic snapping and haptic feedback (`UIImpactFeedbackGenerator`) while dragging.
- **Compact player layout**: "Compact" layout style option in player settings, reducing transport button sizes and placing the scrubber inline between time labels for a minimalist, one-handed-friendly look.
- **Section disclosure groups in playlist**: logical chapters with sub-section data render as expandable `DisclosureGroup` rows, with tappable section rows and now-playing indicators.
- **Artwork-derived accent color theming**: Dynamic accent (tint) color derived from audiobook cover artwork via `DominantColorExtractor` — downsamples to 100×100px, converts to HSL, builds a saturation²-weighted hue histogram with centre-distance biasing, and clamps saturation/lightness for readability. Available as the "Artwork" theme option in Settings (now the default).
- **Accent contrast safety pipeline**: Two-stage safety net ensuring artwork-derived accent colors are legible against the player surface. `ColorMetrics.isLegible(_:on:)` uses a dual-gate trigger (WCAG luminance ≥ 2.4:1 AND CIELAB ΔE chroma ≥ 52). `AccentSafetyNet.resolve(...)` applies a progressive A→B→C rescue ladder: (A) nudge hue lightness to contrast floor within distortion budget, (B) re-pick next safe cover hue, (C) fall back to nudged brand tint. Returns a `Tier` for debug/telemetry. Key types: `ColorMetrics` (WCAG/CIELAB/HSL/`RGB`), `AccentSafetyNet` (A→B→C rescue), `ArtworkPalette` (`{ rawAccent, candidates, background }`).
- **Shared extractPalette histogram pass**: `DominantColorExtractor.extractPalette(from:)` returns `{ rawAccent, candidates, background }` from a single downsampled histogram scan, shared by accent extraction (`artworkAccentColor`) and background gradient computation.
- **Now Playing UI redesign**: Unified dock/header component architecture (`UnifiedTopHeader`, `UnifiedBottomDock`) with adaptive theming, full-bleed artwork split layout, and tab-specific content padding. Player layout supports Default and Compact styles with configurable transport button sizes.
- **Pomodoro timer**: Focus timer with hours support, multi-wheel picker (hours/minutes/seconds), thicker circular progress indicator with dynamic formatting, wrist-down tick fix, and 3-second persistent alarm. Available as a watch action with artwork accent color syncing.
- **Fullscreen cover art viewer**: Tap album art on watch to view fullscreen cover art.
- **Watch face date overlay**: Configurable date overlay on watch player screen with format options (e.g., "Tue, Jun 9").

### Changed
- **Architecture cleanup (code audit):** deleted the unused protocol-oriented DI layer (`PlayerModelComponentProtocols`, `SettingsManagerProtocol`, `StoreManagerProtocol`, `MediaPlayable`, and their orphaned `EchoTests/Mocks`) — it was never wired as an injection seam (`CODE_AUDIT.md` §10.1); and removed the dead Timeline-Feed prototype cluster (~3.9k LOC) superseded by the current Reader feed. See `CLAUDE.md` for the "add a protocol back only when a real second implementation exists" guidance.
- **Swift 6 main-actor isolation pass (code audit):** `NowPlayingController`, `WatchSyncManager`, and `CarPlaySceneDelegate` are now explicitly main-actor isolated, with timer teardown isolated in `deinit`, resolving Swift-6 isolation regressions.
- **Performance:** batched the "export all" `.apkg` card query (`CODE_AUDIT.md` §7.6); cut redundant view-body work in the dashboard (§7.2, §7.3); made the macOS reader block cells `Equatable` to avoid needless redraws.
- **Design-review HIG pass (audit B1–B5, C1–C4, D1–D2, E1–E6 + mini-player):** the v1.0 design review's audit fixes applied across the existing surfaces.
  - *Now Playing:* the ambiguous top "remaining time" pill is now the single **sleep-timer home** — a bare moon glyph when off, a tinted chip with moon + countdown when armed (pomodoro-ready slot); the duplicate sleep button leaves the bottom utility row (now four targets). Utility buttons carry active state by **filled chip, not color alone**. The title block flips to an **eyebrow layout** — book · author in small caps above (tap for book info), chapter title on the hero line. Transport is re-weighted: **±30s skips get the big 62pt chips** beside a 78pt play button (progress ring kept as the signature), chapter prev/next move outboard as quiet glyphs. Under the chapter scrubber, a **3pt book-progress hairline with chapter ticks** plus a "4% of book · Prologue of 8 chapters" caption; tapping the trailing time label toggles remaining ↔ duration.
  - *Chapter list:* interaction inverted on purpose — **row tap toggles the chapter on/off** (with haptic), a trailing 44pt play button owns playback, so an accidental toggle is harmless instead of losing your place. Shared "Part …:" title prefixes become **section headers** (`ChapterPartGrouper`). The glyph filter chips are replaced by an **All / Chapters / Bookmarks segmented control** plus an inline search field.
  - *Reader:* paragraph timestamps now show on the **active card only** (it doubles as the you-are-here marker); other cards reveal theirs via long-press (context-menu title). The sticky chapter header is tinted by the cover theme instead of a flat gray band.
  - *Settings:* **one settings surface** — the loaded book's overrides sit in a labeled section at the top of Settings ("<Book> — overrides global"), and the ellipsis menu has a single Settings entry; the standalone book-info sheet remains reachable from the player's eyebrow. App-wide accent tint now resolves the artwork-derived color inside settings sheets too (`PlayerModel.resolvedThemeTint`) — toggles no longer fall back to system green. The "for testing" Silence Detection slider is `#if DEBUG`-gated. Smart Rewind teaches by example with a **live footer** ("Paused 12 min → rewinds 30 s") recomputed from the steppers (`SmartRewindPolicy`, also now backing playback's rewind logic). Label fixes: "Color Scheme" picker (was a duplicate "Appearance"), a footer explaining "Truncate Chapter to Ch.", and "Sync Now" (was "Force Sync to Watch").
  - *Mini-player:* now has **three user-configurable button slots** (default −30 · play · +30), set via pickers in the Phone Player Designer (`SettingsManager.miniPlayerPage`).
- **Cover-derived theming rebuilt on OKLCH tone recipes:** cover artwork now contributes only its identity hues (`CoverSignature`); `CoverThemeBuilder` constructs role colors (accent, on-accent, chip, background ramp) from per-scheme tone recipes — pale tonal ramps in light mode, immersive deep tones in dark mode — with WCAG contrast guaranteed by construction and proven by a 360-hue property test. Fixes illegible accents on pale covers (bright gold on beige measured 1.06:1). Now Playing background is a designed two-stop ramp instead of a blurred three-hue gradient; transport circles and header pills use tone-on-tone chip fills; the play button is accent-filled with a guaranteed-contrast glyph. The Watch now receives a dark-recipe accent (its surface is always dark). `AccentSafetyNet` and the ΔE76 legibility gate were removed.
- **Bundle identifier & app-group migration (Echo rebrand):** all `com.orbit.*` bundle identifiers and the `group.com.orbitaudiobooks` App Group migrated to the `com.echo.*` domain across `project.pbxproj`, the per-target entitlement files, and code. The Fastlane `Appfile` still references `com.orbit.*` (flagged with TODO markers) pending coordinated App Store Connect changes and provisioning-profile regeneration (see `docs/provisioning-rebrand.md`).
- **Tier 0 metadata title matching:** `AutoAlignmentService` now runs a pre-ML Tier 0 pass (`ChapterTitleMatcher`) that compares audiobook chapter titles (from M4B metadata) to EPUB headings via composite Levenshtein + Jaccard scoring. High-confidence matches (≥0.85) create anchors instantly and skip DTW transcription for those chapters, making coarse alignment near-instant before any model loads.
- **Proportional fallback chapter alignment:** `AutoAlignmentService` now calculates estimated fallback timestamps for EPUB chapters proportionally based on cumulative `word_count` instead of a linear sequence index. A block with 500 words is appropriately weighted against a block with 5 words.
- **DTW Memory Optimization:** Reduced `TokenDTW.align` peak memory consumption by over 80% (from ~125MB to ~25MB for large chapters) by utilizing a sliding 2-row algorithm for Dynamic Time Warping instead of a full NxM cost matrix. Prevents out-of-memory crashes during WhisperKit transcription.
- **Playlist document import unified:** The "Import EPUB" button now accepts both EPUB and PDF files, with automatic routing to the appropriate importer. The Reader tab falls back from EPUB to PDF to empty state based on available companion documents.
- **Reader tab routing:** `RootTabView` now checks `model.hasPDF` when `model.hasEPUB` is false, routing to `PDFDocumentView` instead of `ReaderEmptyState`.
- **Alignment interpolation now uses word-count-weighted proportional math** (Schema V8) instead of sequence-index-based linear interpolation. Results in more accurate timestamp estimates for paragraphs of varying lengths.
- Settings, Book Settings, and Help toolbar buttons consolidated into a single "More" (`ellipsis.circle`) menu on both the NowPlaying tab and the NowPlaying top toolbar.
- Simplified scrubber layout: time labels always below the slider.
- Watch communication reliability improvements and playlist toggle UI polish.
- Artwork handling simplified; oversized widget artwork now downsampled via ImageIO instead of discarded.
- Timeline feed action buttons (bookmark, flashcard, etc.) now use `UIButton.Configuration` with larger content insets for improved hit targets while maintaining 14pt icon size.
- **Watch connectivity architecture overhauled**: Significant state now syncs via durable `updateApplicationContext` (delivered immediately to active watch, guaranteed on next activation), with `sendMessage` retained only as a low-latency optimisation. Transport commands never ride the `transferUserInfo` background queue to prevent stale command replay. High-frequency progress and sleep-timer ticks stay live-only (`reason: .progress`).
- **Swift Concurrency & Thread Safety modernized**: `MainActor.assumeIsolated` replaces `Task { @MainActor in }` for callbacks guaranteed on the main thread across 9 service files. `AVAudioEngine`, `Timer`, and `NSObjectProtocol` observer properties annotated `nonisolated(unsafe)` to suppress Swift 6 data-race diagnostics. `@preconcurrency import AVFoundation` added project-wide.
- **AlignmentService word-position calculation**: Hidden blocks and image blocks now receive weight 0.0 in cumulative word-position computation. Block positions shifted from center to start positioning for more predictable interpolation.

### Fixed
- **Alignment & transcription robustness (code audit Phase 3):** prevented silence-detection spin on damaged audio; guarded the chunk planner against inverted bounds; guarded `TokenDTW` against non-monotonic WhisperKit word times; made the `AVAudioConverter` input block one-shot; stopped collapsing the timeline tail to 1.0s before the duration is known; and hardened WhisperKit model lifecycle — release the model on `AutoAlignmentService` dealloc, nil the handle on unload so re-alignment reloads, balance the `WhisperSession` refcount on continuous-align stop, honor cancellation before each chapter transcribe, and stop continuous alignment on `deinit`.
- **Data integrity:** Keychain items now use device-only accessibility with an atomic update-or-add; CloudKit anchor sync drops downloaded anchors that reference unknown local blocks and merges shared anchors on conflict instead of overwriting; the UserDefaults→SQL bookmark migration is now safe and idempotent; `.apkg` export allocates non-colliding note/card IDs; and JSON-deck flashcard import ensures the audiobook row exists before inserting.
- **CarPlay & audio session:** use the non-deprecated `setRootTemplate(_:animated:completion:)`; corrected the disconnect-delegate signature so teardown actually runs; and re-arm route/interruption observers after `stop()` so playback recovers from interruptions.
- **Real-time event integrity:** Standardized flashcard review event types as `flashcard_reviewed` (`RealTimeEventType.flashcardReviewed.rawValue`) and closed instantaneous events by setting `ended_at = startedAt` to prevent push-forward timer anomalies.
- **Push-forward mechanism removal:** Deleted the push-forward timer and uncompleted item advance logic from `TimelineService` and `RealTimeEventDAO` to resolve timeline integrity issues.
- Watch skip forward/backward fallback SF Symbols corrected from nonexistent `goforward`/`gobackward` to valid `arrow.clockwise`/`arrow.counterclockwise`.
- Auto-resume after audio interruption when playback was paused.
- Digital crown deadzone to prevent accidental scrubbing on watch.
- Out-of-range crashes and settings view layout crash.
- Security-scoped URL access permissions for EPUB auto-import.
- Destructive file operations in EPUB import replaced with copy-only approach.
- EPUB heading hierarchy bug where explicit HTML header tags (e.g., `<h1>`) on sub-sections incorrectly overwrote active chapter and part context.
- **Pause on output device disconnect**: `AudioEngine` now observes `AVAudioSession.routeChangeNotification` and pauses on `.oldDeviceUnavailable` (wired headphones / aux / Bluetooth removed). Previously, `AVAudioEngine` would fall back to the built-in speaker and keep rendering when the cable was pulled.
- **Progress save before track change**: `PlayerLoadingCoordinator` now persists the previous book's last-known-good position under the correct folder key before `stop()` zeroes `audioEngine.currentTime` and `state.folderURL` changes.
- **EPUB auto-import security scope**: When a single file (not a folder) is opened directly, a temporary security-scoped resource access is started on the parent directory so sibling EPUB files can be enumerated.
- **Security scope URL reuse**: `SecurityScopeManager.startSelection(url:)` and `startFile(url:)` now correctly stop the previous access grant when the URL changes (previously `guard !hasAccess` early-exited, leaking the old grant).
- **TokenDTW gap-cost initialization**: DTW cost matrix boundary row and column now initialized with cumulative gap costs so the DP can correctly skip leading tokens with no match in the other sequence.
- **EPUB TOC fallback and chapter index off-by-one**: EPUB table of contents now falls back gracefully when heading hierarchy is incomplete; chapter index corrected for sticky header display.
- **Watch stale transport commands**: Transport commands (play/pause/seek) no longer ride the `transferUserInfo` persistent FIFO queue, preventing phantom resume-after-pause and position jumps on relaunch. Queued payloads are routed through `WatchCommandRouter.route(queuedMessage:)` which honors only deferred-safe commands.
- **Watch timer suspension cap**: When the watch wakes from sleep, `Timer.scheduledTimer` delta is capped at 2.0 seconds — beyond that, the watch requests fresh authoritative state from the phone instead of animating through accumulated progress.
- **Watch stale userInfo handling**: After applying received `userInfo` state, the watch immediately requests the phone's current state to converge to the authoritative position.

---

## [0.6] — 2026-05-10 (Build 8)

### Added
- Per-book settings overrides (font, volume boost, bookmarks-inline) via `BookSettingsOverrideStore`.
- EPUB import flow with `EPUBImportCoordinator` and auto-import scanner.
- Twitter-style timeline cards with materialized `timeline_item` table (Schema V4).
- `TimelineDisplayItem` enum for unified heterogeneous feed rendering (audiobook cards, timeline items, NowLine, scrubber gaps).
- Dual-path timeline ingestion: rich (EPUB + transcription) and sparse (audio-only chapters).
- `MediaPlayable` protocol for forward-looking video support.
- Playlist manifest (`.orbitplaylist.json`) for portable playlist state.

### Changed
- **PlayerModel decomposed** from ~2,900-line god class into a thin coordinator (~1,200 lines) wiring 20+ focused services: `PlaybackController`, `PlaybackState`, `BookmarkStore`, `SleepTimerManager`, `NowPlayingController`, `ChapterLoadingCoordinator`, `PlaybackProgressPresenter`, `PlayerLoadingCoordinator`, `BookmarkArtworkCoordinator`, `PlayerTimelinePersistenceService`, `InlineFlashcardTriggerController`, `EPUBImportCoordinator`, `BookSettingsOverrideStore`, `BookPreferencesService`, `WatchStateContextBuilder`, `WatchCommandRouter`, `PlaylistManager`, `PlaylistManifestService`, `Persistence`, `SecurityScopeManager`, `TranscriptService`.
- **Strict 2-tab UI**: NowPlayingTab (pure media consumption) + TimelineTab (unified library, feed, planner, review).
- NowPlaying layout redesigned with top toolbar and compact scrubber.
- Timeline feed rebuilt as hierarchical, speed-aware scroll with structural zoom (Library → Chapter → Transcription).

### Fixed
- Timeline ingestion pipeline now always fires regardless of chapter count.
- Swift 6 concurrency errors and deprecation warnings resolved.
- Infinite duration on chapters without chapter markers fixed.
- `@MainActor` isolation on `Observable` classes to prevent data races.
- SQLite `DEFAULT` syntax and in-memory test database configuration.
- Anki flashcard: generation counter to prevent stale SnippetPlayer completion races.
- Database: composite indexes on `audiobook_id` columns for query performance.
- Database: UTC ISO8601 date serialization for bookmarks and flashcards.

---

## [0.5] — 2026-05-05

### Added
- **SQL database foundation** with GRDB.swift: `DatabaseService`, `MigrationService`, and DAOs for all domain types.
- **V5 Schema**: `epub_block` and `alignment_anchor` tables for EPUB-audio alignment.
- **EPUB-Audio Alignment Pipeline** (`Tools/OrbitTranscriptionCLI/`): Swift CLI with `transcribe` and `align` subcommands. Includes `OrbitEPUBAligner` library with EPUB parsing, XHTML marker extraction, sliding-window NLP alignment, and marker injection.
- **Anki Spaced Repetition**: Inline flashcard recall during playback, daily review UI with SM-2 grading, snippet media playback (`SnippetPlayer`), JSON deck import, and watchOS hands-free review.
- **CarPlay** support with `CarPlaySceneDelegate`, browse template, and remote commands.
- Multi-file M4B folder support with aggregated chapters.
- Tab navigation: `RootTabView` with `NowPlayingTab` and `TimelineTab`.
- **Localization** with Dutch language support.
- Accessibility labels, values, and Dynamic Type support across iOS, macOS, and watchOS.
- Siri App Intents for dictated bookmarks.
- App Group persistence and WatchConnectivity state sync.

### Changed
- UI simplified to strict 2-tab architecture: NowPlaying (consumption) + Timeline (browsing).
- Playlist view rebuilt as hierarchical, speed-aware timeline.
- Watch app redesigned with immersive full-screen artwork and configurable layout.
- Classic watch background setting preserved as toggle.
- Settings centralized in `SettingsManager` with protocol-based mock support.

### Fixed
- Watch complication update frequency improved.
- Circular ring animation lock-up on background wake.
- Chapter-looping cascade and first-open silence resolved.
- 1× speed dead-zone eliminated.
- `AVAudioUnitVarispeed` replaced with `AVAudioUnitTimePitch` to preserve pitch at >1×.
- Security-scoped access lifetime extended across folder scan and image load.
- Optimistic state updates with rollback on Watch for reliability.

---

## [0.4] and earlier

### Added
- **AVAudioEngine** playback backend replacing AVPlayer for volume boost and granular audio control.
- **Smart Rewind**: adaptive rewind logic based on pause duration (seconds/minutes/hours).
- **Sleep timer** with countdown, fade-out, and pause-on-end modes.
- **Bookmarks with voice memos** that play inline at the saved position.
- Bookmark looping mode (loop between consecutive bookmarks).
- **Transcription overlay** with live auto-scroll, tap-to-seek, and word cloud visualization.
- macOS companion app with `NavigationSplitView`, bookmark sidebar, and transcript pane.
- Python and Swift CLI transcription tools (Whisper integration).
- Watch app with play/pause, skip, scrub, volume, loop mode, sleep timer, and bookmark commands.
- Widget extension with circular progress ring and `TogglePlaybackIntent`.
- Sidecar JSON persistence for bookmarks and playback state.
- Markdown export and deep linking for bookmarks.
- Dyslexia-optimized typography (Lexend, OpenDyslexic fonts).
- Haptic feedback toggle via App Group.

### Changed
- Project reorganized into MVVM folder structure per target.
- Legacy `BookLoop`/`LoopPlayer` projects removed.
- Relicensed from GPL-3.0 to MIT.

### Fixed
- Watch bookmark HIG compliance.
- Memory issues in widget and complication rendering.
- Bookmark looping boundary logic and chapter boundary detection.
