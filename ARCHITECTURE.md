# Architecture Overview

<!-- ⚠️  AUTO-GENERATED — do not edit directly. -->
<!-- Regenerate with: `make architecture`                        -->

**Last generated:** 2026-06-13 22:20:36

This document maps the source-tree layout of the Xcode targets and Shared/
module in the Echo: Audiobook Study Player project. Folders are shown in the order
returned by the filesystem; only source, configuration, and metadata files
are included (build artifacts, asset catalogs, and media files are filtered
out).

---

## EchoCore (iOS)

```
CarPlay/CarPlayManager.swift
CarPlay/CarPlayNotificationNames.swift
CarPlay/CarPlaySceneDelegate.swift
DailyPlanner/PlannedSession.swift
DailyPlanner/RealTimeProjectionService.swift
DailyPlanner/SchedulingSheet.swift
Development Assets/.gitkeep
Development Assets/aliceinwonderland_1102_librivox/Alice's Adventures in Wonderland.epub
EchoCore.entitlements
EchoCoreApp.swift
Info.plist
Localizable.xcstrings
Models/AggregatedChapter.swift
Models/Chapter.swift
Models/EchoPlaylistManifest.swift
Models/FlashcardDeckImport.swift
Models/LoopMode.swift
Models/M4BBook.swift
Models/Note.swift
Models/PlayerDeepLink.swift
Models/ReaderCardItem.swift
Models/RealTimeEventType.swift
Models/SleepTimerMode.swift
Models/SpeedSuggestion.swift
Models/ThemeColor.swift
Models/Track.swift
PrivacyInfo.xcprivacy
Protocols/PlayerModelComponentProtocols.swift
Protocols/SettingsManagerProtocol.swift
Protocols/StoreManagerProtocol.swift
Services/AlignmentChunkPlanner.swift
Services/AlignmentService.swift
Services/AlignmentTranscript.swift
Services/AnchorSelector.swift
Services/ApkgExportService.swift
Services/ApkgImportService.swift
Services/ArtworkCache.swift
Services/AudioEngine.swift
Services/AudioSegmentReader.swift
Services/AutoAlignmentService.swift
Services/AutoAlignmentState.swift
Services/AutoAlignmentTextMatcher.swift
Services/BookPreferencesService.swift
Services/BookSettingsOverrideStore.swift
Services/BookmarkArtworkCoordinator.swift
Services/BookmarkStore.swift
Services/ChapterGroupingService.swift
Services/ChapterLoadingCoordinator.swift
Services/ChapterPartGrouper.swift
Services/ChapterService.swift
Services/ChapterTitleMatcher.swift
Services/CloudKitSyncService.swift
Services/ContinuousAlignmentService.swift
Services/CoverThemeBuilder.swift
Services/DeckImportService.swift
Services/DeepLinkHandler.swift
Services/DefaultChimePlayer.swift
Services/DefaultSoundscapeMixer.swift
Services/DefaultVisualizerTap.swift
Services/DominantColorExtractor.swift
Services/EPUBAssetStorage.swift
Services/EPUBAutoImportScanner.swift
Services/EPUBImportCoordinator.swift
Services/EPUBImportService.swift
Services/LocationCaptureService.swift
Services/M4BParser.swift
Services/MacPlaybackLogic.swift
Services/MockMediaProvider.swift
Services/ModelRetainBox.swift
Services/Narration/AudioFileWriting.swift
Services/Narration/NarrationService.swift
Services/Narration/NarrationState.swift
Services/Narration/TextNormalizer.swift
Services/Narration/TTSEngine.swift
Services/Narration/VoiceCatalog.swift
Services/NowPlayingController.swift
Services/PDFImportCoordinator.swift
Services/Persistence.swift
Services/PlaybackController.swift
Services/PlaybackEventLogger.swift
Services/PlaybackProgressPresenter.swift
Services/PlaybackSessionRecorder.swift
Services/PlayerLoadingCoordinator.swift
Services/PlayerTimelinePersistenceService.swift
Services/PlaylistManager.swift
Services/PlaylistManifestService.swift
Services/ReviewNotificationService.swift
Services/SecurityScopeManager.swift
Services/SettingsManager.swift
Services/SilenceDetectionService.swift
Services/SleepTimerManager.swift
Services/SmartRewindPolicy.swift
Services/SnippetPlayer.swift
Services/StandaloneTranscriptionService.swift
Services/StoreManager.swift
Services/StudyNotesExportService.swift
Services/TOCTreeBuilder.swift
Services/TimelineIngestionFactory.swift
Services/TimelineIngestionService.swift
Services/TokenDTW.swift
Services/TranscriptService.swift
Services/WatchCommandRouter.swift
Services/WatchConnectivityCoordinator.swift
Services/WatchStateContextBuilder.swift
Services/WatchSyncManager.swift
Services/WhisperSession.swift
State/PlaybackState.swift
Utilities/ColorMetrics.swift
Utilities/FolderPicker.swift
Utilities/OKLCH.swift
Utilities/ViewModifiers.swift
Utilities/WordFrequencyComputer.swift
ViewModels/DailyReviewViewModel.swift
ViewModels/PlayerModel+Bookmarks.swift
ViewModels/PlayerModel+MarkedPassages.swift
ViewModels/PlayerModel+PlaybackControllerDelegate.swift
ViewModels/PlayerModel+PlaybackLogging.swift
ViewModels/PlayerModel+WatchState.swift
ViewModels/PlayerModel.swift
ViewModels/ReaderFeedViewModel.swift
Views/AppIconSelectionView.swift
Views/AutoAlignmentProgressView.swift
Views/BookSettingsView.swift
Views/BookmarkCardView.swift
Views/Bookmarks.swift
Views/BottomToolbarView.swift
Views/CardColorPickerSheet.swift
Views/CardInboxView.swift
Views/Cells/HeadingCardCell.swift
Views/Cells/ImageCardCell.swift
Views/Cells/ParagraphCardCell.swift
Views/ChapterPickerSheet.swift
Views/ChimeSettingsView.swift
Views/Components/AdaptiveBackground.swift
Views/Components/AlbumArtHeroView.swift
Views/Components/BookProgressTrack.swift
Views/Components/CircularProgressPlayButton.swift
Views/Components/FlashcardCreationSheet.swift
Views/Components/Haptic.swift
Views/Components/InlineStepperRow.swift
Views/Components/MarqueeText.swift
Views/Components/PlayerControlBar.swift
Views/Components/SleepTimerPill.swift
Views/Components/UnifiedBottomDock.swift
Views/Components/UnifiedTopHeader.swift
Views/Components/WordCloudView.swift
Views/DashboardShelf.swift
Views/EPUBHeadingPickerSheet.swift
Views/Fidget/BubblePopView.swift
Views/Fidget/DoodlePadView.swift
Views/Fidget/FidgetOverlayView.swift
Views/Fidget/InfinityScrollView.swift
Views/Fidget/KineticSandView.swift
Views/Fidget/TactilePlaygroundView.swift
Views/FlashcardReviewCard.swift
Views/FlashcardReviewSession.swift
Views/FontSelectionView.swift
Views/HelpContent.swift
Views/HelpView.swift
Views/ListeningProgressModuleView.swift
Views/ManualAlignmentSheet.swift
Views/NoteEditorView.swift
Views/NowPlayingLayout.swift
Views/NowPlayingTab.swift
Views/OnboardingView.swift
Views/PDFDocumentView.swift
Views/PhonePlayerSettingsView.swift
Views/PlaybackOptionsSheet.swift
Views/PlayerMoreMenu.swift
Views/PlayerScrubberView.swift
Views/PlayheadLineView.swift
Views/PlaylistView.swift
Views/ProTranscriptsSettingsView.swift
Views/ReaderEmptyState.swift
Views/ReaderFeedCollectionView.swift
Views/ReaderHeaderView.swift
Views/ReaderSettingsSheet.swift
Views/ReaderTab+Alignment.swift
Views/ReaderTab.swift
Views/RootTabView.swift
Views/ScrubberJoystick.swift
Views/SettingsAdvancedView.swift
Views/SettingsAppearanceView.swift
Views/SettingsView.swift
Views/SleepTimerCardView.swift
Views/SmartRewindSettingsView.swift
Views/SoundscapePickerView.swift
Views/SpeedCardView.swift
Views/SpeedSuggestionBanner.swift
Views/StandaloneTranscriptView.swift
Views/Stats/BookStatsView.swift
Views/Stats/DeckDetailView.swift
Views/Stats/DeckListView.swift
Views/Stats/StatCardView.swift
Views/Stats/StatsView.swift
Views/StatsModuleView.swift
Views/StreakModuleView.swift
Views/ThemeSelectionView.swift
Views/TransportControlsView+LongPress.swift
Views/TransportControlsView.swift
Views/UpcomingReviewsModuleView.swift
Views/Visualizer/VisualizerPickerView.swift
Views/Visualizer/VisualizerShaders.metal
Views/Visualizer/VisualizerStyle.swift
Views/Visualizer/VisualizerView.swift
Views/VoiceMemoOverlayView.swift
Views/WatchAppSettingsView.swift
```

## Echo macOS

```
Echo_macOS.entitlements
Echo_macOSApp.swift
Info.plist
PrivacyInfo.xcprivacy
Services/AudioExtractor.swift
Services/FolderAudioScanner.swift
Services/MacAlignmentService.swift
Services/MacApkgExportService.swift
Services/MacAudioBoostTap.swift
Services/MacBatchProcessingService.swift
Views/MacAnkiExportView.swift
Views/MacBatchQueueView.swift
Views/MacNotesPane.swift
Views/MacPlaybackOptionsSheet.swift
Views/MacPlayerModel.swift
Views/MacPlayerMoreMenu.swift
Views/MacReaderFeedView.swift
Views/MacSettingsView.swift
Views/MacTOCTreeView.swift
Views/MacTriPaneView.swift
Views/TranscriptPane.swift
Views/TranscriptStore.swift
Views/TranscriptionManager.swift
```

The macOS app is rooted in `MacTriPaneView` (a `NavigationSplitView`/tri-pane layout), with a separate `Settings { MacSettingsView() }` scene (⌘,). `MacPlayerModel` is a self-contained `@Observable` model wrapping a raw `AVPlayer` — it is **independent of the iOS `PlaybackController`** (which is not compiled into the macOS target), so macOS builds no global cross-file chapter timeline. As of the BookPlayer-style redesign (June 2026) `MacPlayerModel` gained a chapter axis, a 3-way loop, a configurable skip interval, above-unity volume boost, and `SettingsManager` consumption:

- **Chapter axis.** On file open it parses M4B chapter markers via the shared `ChapterService.parseChapters(from:)` (token-guarded async) and derives the active chapter from the periodic time observer via `ChapterService.chapterIndex(forTime:in:)`, exposing `chapters` / `currentChapterIndex` (`private(set)`) plus `nextChapter()` / `previousChapter()` / `seekToChapter(_:)`. Axis reconciliation: chapter nav drives *within* a file when it has ≥2 M4B chapters, else falls back to across-file track nav. The ⌘←/⌘→ "Previous/Next Chapter" menu commands now perform real chapter navigation (they previously called track methods despite their labels).
- **3-way loop + end-of-chapter sleep.** `loopMode: LoopMode`; the time observer calls `handleChapterBoundary()` **before** the active-chapter refresh (so the boundary is detected on the pre-advancement index), delegating to the pure, unit-tested `MacChapterLoopDecision.evaluate(...)` in `EchoCore/Services/MacPlaybackLogic.swift`. The `.bookmark` (A→B) loop is enforced on the same tick by `handleBookmarkLoop()`, delegating to the pure `MacBookmarkLoopDecision.seekBackTarget(...)` (mirrors iOS `PlaybackController.applyBookmarkLoopIfNeeded`: repeat the segment between the two bookmarks bracketing the playhead); the `MacPlaybackOptionsSheet` demotes `.bookmark` → `.off` when the book has no bookmarks.
- **Configurable skip interval** (`skipInterval`, default 15) threaded through the player bar and Playback menu commands.
- **Volume boost above unity** (which `AVAudioMix` volume cannot reach) via an `MTAudioProcessingTap` (`Services/MacAudioBoostTap.swift`) that multiplies samples by a linear gain read live from a shared box; an ASBD `prepare`-callback guard degrades to clean passthrough on non-float-PCM routes. The dB→linear math is the pure `MacVolumeBoost.linearGain` (also in `MacPlaybackLogic.swift`).
- **Settings.** `Echo_macOSApp` injects a shared `SettingsManager` into both the main `WindowGroup` and the `Settings` scene, applies `.preferredColorScheme` from `settings.appAppearance`, applies static `themeColor` choices as the window tint, and installs the persisted `appFont` as the default body font. `MacPlayerModel.settings` (injected once by `MacTriPaneView.task`, mirroring the `dbService` pattern) adopts the persisted skip interval and default speed. `MacSettingsView` is a native Preferences `TabView` (Appearance + Playback panes binding the shared `SettingsManager`; no Pro/StoreKit pane — macOS has none). The main tri-pane chrome and Mac reader feed/card text also use the configured accessibility font.
- **Player bar.** `MacTriPaneView`'s player bar replaced the track label with a `< Chapter Title >` chevron nav bar, the inline speed `Picker` with a button that opens `MacPlaybackOptionsSheet` (a `.popover` — speed / loop / skip / boost + a Smart Rewind `SettingsLink`), and relocated the inline sleep menu into `MacPlayerMoreMenu` (chapters / bookmarks / add-bookmark / mark-passage / sleep / Settings).

### macOS Batch Processing Queue (June 2026)

The Mac app can process an entire folder of audiobooks unattended. A small `FolderAudioScanner` recursively scans a user-picked folder and **enqueues** each audio file (with its companion EPUB) into a persistent queue; `MacBatchProcessingService` drains it one book at a time through the real **import → transcribe → align** pipeline. (This replaced the earlier inline, in-memory "Bulk Align Folder…" flow — the dead `MacBulkAlignmentService` and its progress sheet `MacBulkAlignmentProgressView` were removed once the queue UI shipped.)

- **Durable queue (`batch_queue`, Schema V20).** `BatchQueueRecord` / `BatchQueueDAO` persist queue position, status, and (nullable) security-scoped bookmarks. `batch_queue.audiobook_id` deliberately has **no** FK — entries legitimately reference not-yet-imported books. The pure, testable `BatchQueueRunner` (`Shared/`) drains the queue FIFO, isolates per-book failures (a throw marks that item `.failed` and processing continues), and on relaunch `recoverInFlight()` resets any `importing`/`transcribing`/`aligning` item back to `queued` so the queue resumes cleanly.
- **Sandbox-correct file access.** The Mac app is sandboxed (`app-sandbox` + `files.user-selected.read-write` + `files.bookmarks.app-scope`), so each audio file's security-scoped bookmark is captured at enqueue, and a **separate bookmark for the sibling companion EPUB** is captured at the same moment — while the user-picked folder's scope is still live. Both are resolved and `startAccessingSecurityScopedResource()`-balanced (with `defer` stops) during processing. A book whose import produces **no** EPUB blocks is marked `.failed` rather than silently completing empty.
- **Two item kinds (`batch_queue.kind`, Schema V21).** `kind` (additive `ALTER ADD … DEFAULT 'align'`) discriminates audiobook-alignment items (`.align`, the original import→transcribe→align) from text-only **EPUB narration** items (`.narrate`). `makeStages()` branches on `kind`: a `.narrate` item bookmarks the EPUB itself as its source, imports the EPUB's blocks (no audio), and synthesizes each chapter on-device via `NarrationService` (see *On-Device Narration*), reusing the same `BatchQueueRunner` failure isolation + restart recovery. `BatchItemKind` decodes forward-compatibly (an unknown future kind falls back to `.align` rather than crashing an older build). `FolderAudioScanner.enqueueEPUBsForNarration` and `MacBatchProcessingService.enqueueNarration(epubURL:)` enqueue them.
- **UI.** `MacBatchQueueView` shows per-item status/progress (and an **Open** button on a completed `.narrate` book that loads it into the player); `Echo_macOSApp` adds a **Batch** command menu (Open Batch Queue / Add Folder to Queue / **Narrate EPUB(s)…** ⌘⌥N) and calls `resumeOnLaunch()` from the main window's `.task`.

### Audiobookshelf Integration — download-to-local (June 2026)

Echo can connect to a self-hosted **Audiobookshelf (ABS)** server and download books directly into the local study pipeline. The design is **download-to-local, not streaming** — streaming remains deferred post-1.0 because Echo's audio engine reads via `AVAudioFile(forReading:)` (local files only) and the study differentiators (alignment, phrase search, karaoke, flashcards) depend on a local folder identity.

**Architecture overview:**

- **`AudiobookshelfService`** (`@MainActor` class, injected `URLSession`, no protocol — matches the concrete-type DI style) speaks the ABS HTTP API: authenticate, browse libraries/items, search, download whole-item zips, and push/pull media progress. Auth uses JWT + serialized refresh-with-rotation (the rotated token is persisted on every response to avoid self-invalidation). Bare host input defaults to `https://`; plaintext LAN/tailnet `http://` only happens when the user types the scheme explicitly and confirms before Echo sends credentials, and connected HTTP servers remain visibly marked as unencrypted. Both app targets (iOS `EchoCore/Info.plist`, macOS `Echo macOS/Info.plist`) still declare `NSAppTransportSecurity → NSAllowsArbitraryLoads = true` because confirmed ABS hosts are user-supplied and can be arbitrary LAN/VPN/Tailscale addresses; a narrower `NSAllowsLocalNetworking` or per-domain exception is insufficient for Tailscale's CGNAT range (`100.64.0.0/10`), which ATS does not classify as local. **Self-signed HTTPS** remains the recommended local path and is supported via opt-in, per-server **trust-on-first-use certificate pinning**: on first connect the user is shown the cert's SHA-256 fingerprint and, on approval, Echo pins that exact leaf certificate (stored in the server's Keychain namespace — no schema migration) and accepts it only for the configured host. CA-trusted HTTPS validates normally with no prompt. A pinned cert that later changes fails closed (sign out and reconnect to re-trust). *Known limitation:* cover thumbnails on a self-signed server don't load, because `AsyncImage` fetches via `URLSession.shared` (which can't use the pinning delegate); connect, browse, search, download, and progress all work.
- **`ABSImportService`** (or the download coordinator) receives the downloaded zip, unzips it into `Application Support/ABSLibrary/<remoteItemID>/` (an app-owned folder, no security-scoped bookmarks needed), stamps provenance columns on the `AudiobookRecord`, and hands the resulting folder to the existing `PlayerLoadingCoordinator.loadFolder` unchanged — so M4B chapter parsing, `EPUBAutoImportScanner` sibling discovery, alignment, flashcards, and phrase search all fire with zero pipeline changes.
- **`ABSProgressReconciler`** implements a last-write-wins (ABS-authoritative) strategy: progress pushes are throttled (~15–30 s) while playing; on book open the reconciler compares local `updatedAt` against ABS `lastUpdate` and re-seeks if ABS is newer. The pull re-seek is single-track-only in v1. *The pure reconciler logic is unit-tested; live playback wiring is device-unverified as of the initial branch.*
- **Background-task grace window:** a `beginBackgroundTask` call keeps an in-flight download alive when the user backgrounds the app during a download. This is *not* a full `URLSessionConfiguration.background` session — the ABS zip endpoint lacks `Content-Length`/range headers, so true background-session resumption (progress survives process termination) is a documented future enhancement.
- **Anchor-reuse:** `CloudKitSyncService.downloadAnchors` keys shared anchors on `title+author+duration` (not `audiobookID`), so a book re-downloaded from ABS inherits prior WhisperKit alignment anchors that another device already computed. The provenance columns carry the real ABS title/author so the lookup key matches.

**Schema V23** adds four nullable columns to `audiobook`: `source_type` (TEXT — `"abs"` for ABS-sourced books, `NULL` for local), `server_id` (TEXT), `remote_item_id` (TEXT), and `topics_json` (TEXT — serialized ABS genres/tags for local topic filtering). All are additive `ALTER TABLE ADD COLUMN` statements; no re-import or re-alignment is needed for existing books.

**Platform split:** iOS UI is fully built (Settings ▸ Library Sources connect/browse sheet, search, "Add from Audiobookshelf" download action). The macOS target compiles the service layer but the macOS ABS UI is a fast-follow (not yet wired).

**Credential storage:** the ABS JWT is stored in `KeychainStore` (never in SQLite). The `abs_server` table (Schema V18; existing) holds `baseURL`, `username`, and `defaultLibraryId`; V23 carries the per-book provenance on `audiobook`.

## Echo Watch App

```
EchoCoreWatchApp.swift
EchoWatchApp.entitlements
Info.plist
Models/WatchBookmark.swift
PrivacyInfo.xcprivacy
Services/WatchViewModel.swift
Services/WatchVoiceMemoRecorder.swift
Views/Bookmarks.swift
Views/Components/PomodoroButton.swift
Views/Components/ToggleTraitModifier.swift
Views/ContentView.swift
Views/PlayerPage.swift
Views/PomodoroTimerPickerView.swift
Views/WatchControlBackground.swift
Views/WatchReviewView.swift
```

## Shared (cross-target)

```
AnimationDurations.swift
AppGroupDefaults.swift
ArchiveExtractionLimits.swift
ChimeSound.swift
Database/AlignmentAnchorRecord.swift
Database/BookmarkRecord.swift
Database/ChapterRecord.swift
Database/ClozeParser.swift
Database/DAOs/AlignmentAnchorDAO.swift
Database/DAOs/AudiobookDAO.swift
Database/DAOs/BookmarkDAO.swift
Database/DAOs/ChapterDAO.swift
Database/DAOs/EPubBlockDAO.swift
Database/DAOs/EPubTOCEntryDAO.swift
Database/DAOs/FlashcardDAO.swift
Database/DAOs/NoteDAO.swift
Database/DAOs/PlannedSessionDAO.swift
Database/DAOs/PlaybackEventDAO.swift
Database/DAOs/RealTimeEventDAO.swift
Database/DAOs/TimelineDAO.swift
Database/DAOs/TrackDAO.swift
Database/DAOs/TranscriptionDAO.swift
Database/DatabaseService.swift
Database/Deck.swift
Database/EPubBlockRecord.swift
Database/EPubTOCEntryRecord.swift
Database/FSRSScheduler.swift
Database/Flashcard.swift
Database/MarkedPassageRecord.swift
Database/NoteRecord.swift
Database/PlannedSessionRecord.swift
Database/RealTimeEventRecord.swift
Database/SM2Scheduler.swift
Database/SchedulingAlgorithm.swift
Database/Schema_V1.swift
Database/TimelineItem.swift
Database/TrackRecord.swift
Database/TranscriptionRecord.swift
Database/TranscriptionWord.swift
EPUBBlockParser.swift
EPUBHeuristicEngine.swift
EPUBXMLParsing.swift
EnhancedTranscriptionSegment.swift
FileLocations.swift
HeadingClassifier.swift
ImageEncoding.swift
KeychainStore.swift
LayoutPreset.swift
Logger+Subsystem.swift
MediaPlayable.swift
Models/PDFViewState.swift
NotificationNames.swift
ReaderSettings.swift
SafeFileName.swift
Services/ChapterCardDrafter.swift
SoundscapePreset.swift
StandaloneTranscriptRecord.swift
Stats/PlaybackSegmentBuilder.swift
Stats/StatsAggregator.swift
Stats/StatsModels.swift
Stats/StatsRepository.swift
String+Levenshtein.swift
SyncMarker.swift
TabSelection.swift
TextAlignmentUtilities.swift
TimeFormatting.swift
TranscriptionSegment.swift
URL+SHA256.swift
VisualizerFrame.swift
WatchAction.swift
WatchFlashcard.swift
WatchMessageKey.swift
WordFrequency.swift
```

## Echo Widget

```
EchoWidget.entitlements
Info.plist
Models/AppIntent.swift
PrivacyInfo.xcprivacy
Views/Echo_Widget.swift
Views/Echo_WidgetBundle.swift
Views/Echo_WidgetControl.swift
```


<!-- MANUAL BELOW -->

## Tools & Pipeline

### EPUB-Audio Alignment (In-App)

> **Note:** The earlier `EchoTranscriptionCLI` tool (Swift CLI + Python/Whisper pipeline) has been **abandoned and removed**. It is not part of the current user workflow.

Alignment is now performed entirely in-app, without any external tools or API calls:

1. **EPUB / Text-Document Import:** When the user adds a companion document, the appropriate parser produces an `EPUBBlockParse` value consumed by a shared persist phase:

   - **EPUB** (`EPUBImportService`) parses the file into `epub_block` records (headings, paragraphs, images) stored in the database.
   - **Markdown / plain text** (`TextDocumentParser`, `Shared/`) — `.md`/`.markdown`/`.txt` files are parsed into the same `EPUBBlockParse` that the EPUB parser emits, producing one synthetic spine entry per chapter. Markdown chapter breaks follow the heading hierarchy (chapter level = shallowest repeating heading level; a lone leading `#` is front matter; deeper headings are in-chapter section headings). Plain text uses heuristic detection ("Chapter N", multi-word or ≥6-letter ALL-CAPS title lines) and falls back to a single chapter. Bold, italic, and strikethrough are preserved as `TextFormat` spans; code blocks, tables, and images are omitted from narration output. A `TextAutoImportScanner` drives the text import path, analogous to `EPUBAutoImportScanner` for EPUBs.
   - **PDF** (`PDFAutoImportScanner`, `EchoCore/Services`) extracts each page's text with **PDFKit** (run off the main actor in a detached task) and feeds the same `EPUBBlockParse` → shared persist phase. Page line breaks are **preserved**, so a standalone "Chapter N" / "Part N" line is still detected as a chapter marker (the same per-line `tokenizePlainText` pass the text path uses); the tokenizer reflows the remaining wrapped lines back into paragraphs. When a marker-less PDF has more than one page, it falls back to **one synthetic narration chapter per page** (`parsePDFPagesAsPlainTextChapters`, `Shared/TextDocumentParser.swift`) so a long PDF doesn't become a single enormous narration batch. **Reachable from** the headless narration runner / `echo-cli narrate` and from iOS folder import (a `.pdf` inside an opened folder); **not yet wired** to the iOS document picker (no PDF `UTType`) or any macOS-app path (the macOS open panel and batch importer don't accept PDFs).

   These import paths share a **`EPUBImportService.import(parse:audiobookID:chapters:bookDuration:assetBaseURL:)`** persist phase (writes `epub_block` rows) and a **`DocumentImportFinalizer.finalize(...)`** tail (writes alignment anchors and the timeline tail). This seam means the narrate, read-along, and chaptered-playback pipeline is reused unchanged. No schema migration is needed — text-document and PDF blocks use the existing `epub_block` table (schema head V23).

   **Out of scope (future work):** attaching a text file to an existing audio book for read-along; rendering-but-not-speaking code blocks; image resolution; multi-file (folder-of-`.md`) books.

   The spine walk, heuristic block classification, and stable block-ID assignment (`epub-<audiobookID>-s<i>-b<j>`) live in the shared `parseEPUBBlocks` driver (`Shared/EPUBBlockParser.swift`), consumed by **both** this importer and the macOS aligner so the content-stable block-ID **suffix** (`s<i>-b<j>`) is identical across devices (CODE_AUDIT.md §5.1); the device-local `epub-<audiobookID>-` prefix differs per install and is re-applied on import (see **Mac → device alignment handoff** below). Parsing applies three correctness passes:
   - **Whitespace normalization:** XHTML text accumulates with collapsing whitespace (`collapsedWhitespace()` / entity-split-safe chunk joining in `XHTMLBlockDelegate`), so pretty-printed source line breaks never reach `epub_block.text`, and words split by XML entity references (`it&#8217;s`) stay intact. Structural element boundaries (`<br>`, table cells, divs — anything not an inline formatting tag) inject a collapsible space, so titles split across child elements (`<span>Chapter 1</span><br/><span>A Pragmatic Philosophy</span>`, `<td>Topic 3</td><td>Software Entropy</td>`) read as separate words while mid-word inline markup (`<em>un</em>do`) stays glued. NCX/nav TOC labels and document titles are normalized the same way.
   - **Front-matter classification:** the importer reads the EPUB's structural metadata — spine `linear="no"`, the EPUB 2 `<guide>` (`type="text"` = body start), and EPUB 3 nav landmarks (`epub:type="bodymatter"`) — to flag blocks before body matter as `is_front_matter` (Schema V12). Heading-less spines whose only available title is non-content per `HeadingClassifier` (cover, praise, printed TOC, …) are also flagged when no content heading has appeared yet. Front-matter spines never receive synthesized fallback headings, so cover/praise pages no longer become junk chapters. `HeadingClassifier` is the single source of truth for junk-heading rules shared by import, the reader feed, and the TOC sheet.
   - **TOC hierarchy (Schema V13):** `TOCParserDelegate` preserves the publisher's declared TOC tree — NCX `navPoint` nesting (EPUB 2) or nav `<ol>` nesting (EPUB 3) — as `TOCEntryNode` values instead of flattening to per-file labels. At import, `EPUBImportService.resolveTOCEntries` maps each entry to a concrete block (fragment anchor → first heading → first block; `XHTMLBlockDelegate` records element `id`s per block as `anchorIDs` for the fragment step) and persists the tree as `epub_toc_entry` rows. Fragment-resolved targets that aren't `<h1>`–`<h6>` (e.g. The Pragmatic Programmer's table-marked "Topic N" titles) are promoted to heading blocks when their text essentially matches the TOC label (normalized + Levenshtein ≥ 0.85 gate so body prose is never promoted). `TOCTreeBuilder.build(from:tocEntries:)` renders the TOC sheet from these entries (publisher titles + nesting) and falls back to heading inference only when a book declares no TOC; the reader breadcrumb (`ReaderFeedViewModel`) likewise derives ancestry from the entry path at the block's sequence position, appending deeper in-file headings, with the heading-level cascade as fallback.
2. **Auto-Alignment (on-device, word-timestamp pipeline):** `AutoAlignmentService` aligns EPUB blocks to audio using on-device speech recognition (WhisperKit + CoreML) and dynamic time warping. Each run first deletes every machine-made anchor (`auto-tier0-`/`auto-dtw-`/`auto-continuous-`) so re-alignment can correct earlier results; human-made anchors survive and their blocks are never re-anchored.
   - **Tier 0 — Metadata Title Matching (bootstrap):** `ChapterTitleMatcher` compares audiobook chapter titles (from M4B metadata) to EPUB heading blocks using composite Levenshtein + Jaccard fuzzy scoring. Matches create *bootstrap* anchors at track starts so the timeline takes rough shape before transcription; content alignment still runs on every chapter and supersedes a Tier 0 anchor when it finds a strong content match for the same block. Generic numeric track labels ("Chapter 7", "Pt. 2", "12") are excluded — M4B metadata numbers *tracks*, not book chapters (track 1 is often opening credits). Titles whose numbers contradict the heading's number are vetoed outright, and each heading block accepts at most one chapter match.
   - **Content alignment — capture → word timestamps → gated DTW:** For every chapter, `AlignmentChunkPlanner` plans bounded capture windows (15–45 s, cut at `SilenceDetectionService` silence midpoints, hard-capped when no silence is in reach). `AudioSegmentReader` reads each window straight from the audio file (never the playback graph) and WhisperKit transcribes it with `wordTimestamps: true`. `AlignmentTranscript` harvests **every** `TranscriptionResult` (VAD chunking returns one per internal window) into `TranscribedWord`s carrying real per-word times — no token time is ever fabricated from a constant-rate spread. `TokenDTW.alignWithBisection` then warps EPUB tokens (digits expanded to spoken number words, so "Chapter 2" matches "chapter two") against the audio tokens. The chapter's blocks are joined by a 12-block slack margin from each neighbouring chapter, because chapter indices are word-count *estimates* and boundary text routinely lands in the wrong bin.
   - **Anchor gating:** DTW emits `AnchorCandidate`s (block, time, strong-run length); `AnchorSelector` keeps only candidates inside a strong match run (≥3 consecutive exact/prefix token matches) and enforces time monotonicity along reading order (the weaker run loses a conflict). Substitutions cost more than gaps in the DTW, so never-narrated text (front matter, mis-binned blocks, hallucinations) is skipped rather than force-matched — those blocks get **no** anchor and are bridged by interpolation. Anchors insert per-chapter, so alignment improves progressively during a run and partial results survive cancellation.
   - **Memory guard:** `alignWithBisection` recursively bisects the audio at the largest inter-word gap (≈ a paragraph pause) whenever the DTW matrix would exceed ~48 M cells, with overlapping EPUB seams — so single-chapter or multi-hour tracks can't exhaust memory.
   - **Fine-Tuning:** `fineTuneManualAlignment(blockID:around:)` captures a 10 s window (±5 s) around a user-specified time, matches it against the target block, and back-projects the block's first-word time from real word timestamps (`AlignmentTranscript.projectBlockStart`).
3. **Global flat interpolation:** `AlignmentService.recalculateTimeline()` uses dynamic CPS (characters-per-second) computed from existing locked anchors to project synthetic boundary positions, rather than hardcoding time 0.0 and total duration. This produces more accurate extrapolation when anchors exist near but not at the book's edges.
4. **Mac → device alignment handoff (`alignment.json` sidecar):** `audiobookID` — and therefore the full block-ID prefix `epub-<audiobookID>-` — is device-local (`folderURL.absoluteString` differs per install), so a Mac-aligned anchor cannot carry its raw block ID to another device. Instead **both** `MacAlignmentService` (after DTW alignment) and `MacBatchProcessingService` (after on-device narration — where the per-block synthesized anchors are *exact*, converted from per-chapter-relative to absolute m4b times) write an `alignment.json` sidecar next to the EPUB holding each anchor's content-stable **portable suffix** (`s<i>-b<j>`) plus its audio time (`AlignmentSidecar`, the shared contract). When the same EPUB is later imported elsewhere (e.g. pulled from Audiobookshelf), `EPUBAutoImportScanner` → `DocumentImportFinalizer` re-prefixes each suffix with the importing device's local `audiobookID`, drops any that don't resolve to a local block, and ingests the rest — so batch alignment done once on the Mac becomes read-along on the phone. This sidecar is the only cross-device path that resolves; the public-CloudKit community-anchor route cannot, because it matches on device-local block IDs.
4. **Manual refinement:** The user long-presses any card in the Reader and chooses "Align to Now", "Align to 5s Ago", "Align to Chapter Start", or "Align to Chapter End" to lock that block to a specific timestamp. Each locked anchor improves the accuracy of neighboring blocks through proportional interpolation.
5. **Timeline recalculation:** `AlignmentService.recalculateTimeline()` runs in a single DB transaction, updating all affected `timeline_item` rows with new interpolated timestamps, including `audioEndTime` computed from the next visible block's start time.
6. **Block/chapter hiding:** Users can mark individual blocks ("Not in Audio (This Paragraph)") or entire chapters ("Not in Audio (Whole Chapter)") as hidden when the EPUB contains content not present in the audiobook narration. Hidden blocks get `alignment_status = omitted`, `is_enabled = false`. The `hideChapter(chapterIndex:reason:)` method on `AlignmentService` batch-hides all blocks in a chapter.
7. **Continuous Alignment:** `ContinuousAlignmentService` (opt-in via `continuousAutoAlignmentEnabled` setting) periodically transcribes the 15 s of audio behind the playback position and inserts a correction anchor when the transcript confidently matches a nearby block. It reads the audio *file* at media time via `AudioSegmentReader` — the earlier output-mixer tap sat after the time-pitch node, so at non-1× speeds every captured window was time-compressed and anchors landed early by the speed factor. Anchors require ≥8 transcribed words and a sane projection range; they are cleared by the next full auto-alignment run.
8. **CloudKit Sync:** `CloudKitSyncService` synchronizes alignment anchors across devices via CloudKit, ensuring manual and auto-alignment work is shared.

**Dynamic CPS projection (AlignmentService):**

Synthetic anchor placement now uses the average speaking rate derived from existing locked anchors rather than assuming the book starts at 0.0 and ends at `totalDuration`:

1. When ≥2 anchored blocks exist, compute `averageCPS = totalChars / totalTime` from the word-position distances and time deltas between them.
2. Project the first block's time backward from the first locked anchor: `firstTime = anchorTime − (wordDistance / averageCPS)`, clamped to ≥0.
3. Project the last block's time forward from the last locked anchor: `lastTime = anchorTime + (wordDistance / averageCPS)`, clamped to ≤totalDuration.
4. Falls back to 15 CPS (~155 WPM) when fewer than 2 anchors exist.

**Word-count proportional interpolation (Schema V8):**

Earlier alignment used sequence-index-based linear interpolation, which assumed uniform spacing between blocks. Schema V8 introduces `word_count` on `epub_block` to weight block positions proportionally by content length. The current algorithm:

1. Computes a cumulative `wordPosition` for each block (running sum of word counts, placing each block at its proportional start position within the book). Hidden blocks and image blocks receive weight 0.0 so they don't skew interpolation.
2. Synthetic anchor points are placed at the first block (time 0.0) and last block (total duration from the last chapter marker's end time), ensuring the entire book is bounded.
3. Interpolation fraction = `(blockPos − prevPos) / (nextPos − prevPos)` using word positions between any two bracketing anchors (locked or synthetic).
4. This produces smooth timestamp estimates for uneven paragraph lengths (e.g., long prose followed by short dialogue) without requiring chapter boundary data.

**Key types:**

- `AlignmentService` — Creates anchors and recalculates timeline via word-count-weighted proportional interpolation between locked and synthetic boundary anchors. Uses dynamic CPS projection for synthetic boundary placement. Supports `eraseAnchor(blockID:)`, `resetAlignment()`, `hideBlock(blockID:reason:)`, `hideChapter(chapterIndex:reason:)`, and `anchorChapterEnd(blockID:chapterIndex:time:)` for anchor and content management.
- `ChapterTitleMatcher` — Tier 0 metadata-based matcher that compares audiobook chapter titles (from M4B metadata) to EPUB headings using composite Levenshtein + Jaccard fuzzy scoring. Runs before any ML model loading; matches become bootstrap anchors that content alignment later refines or supersedes. Skips generic numeric track labels (`isGenericNumericTitle`), vetoes matches with contradicting numbers, and returns at most one chapter per heading block.
- `AutoAlignmentService` — WhisperKit-based auto-alignment orchestrator: Tier 0 bootstrap, then per-chapter content alignment (chunk planning → word-timestamp transcription → gated DTW → per-chapter anchor insertion) and manual fine-tuning. Reports progress via `AutoAlignmentState` for UI binding.
- `AlignmentTranscript` / `TranscribedWord` — Bridge from WhisperKit output to the alignment pipeline: flattens *all* `TranscriptionResult`s (VAD chunking yields one per window) into words with absolute per-word timestamps, falling back to per-segment spreading only when a segment lacks word data. Also hosts `projectBlockStart(words:matchedBlockWindowStart:)`, the word-rate back-projection used by fine-tune and continuous alignment, and `transcribeWords(with:samples:captureStart:)`, the single home of the pipeline's `DecodingOptions`.
- `AlignmentChunkPlanner` — Pure planner that splits a chapter into capture chunks: prefers silence-midpoint cuts, hard-caps chunk length (45 s) when no silence is reachable, and merges tiny tails.
- `AudioSegmentReader` — Reads a time window straight from the audio file on a background queue and converts to 16 kHz mono Float32. Used by batch alignment, fine-tune, and continuous alignment so captures are never distorted by the playback graph's time-pitch node.
- `AutoAlignmentTextMatcher` — Fuzzy text matching engine for short-transcript lookups (fine-tune, continuous alignment). Uses Levenshtein distance and word-level Jaccard similarity with a sliding window, reporting `bestWindowStart` for back-projection.
- `TokenDTW` — Dynamic Time Warping aligner that matches EPUB tokens against audio transcription tokens at word-level granularity (flat `Int32` cost + `Int8` direction arrays). `normalize` expands digit runs to spoken number words. `alignCandidates` returns per-block `AnchorCandidate`s carrying strong-run evidence — substitution costs more than a gap, so unmatched text is skipped, not force-matched. `alignWithBisection` recursively splits oversized problems at the largest audio pause with overlapping EPUB seams.
- `AnchorSelector` — Pure gate over `AnchorCandidate`s: minimum strong-run length (3) plus a monotonic-time sweep along reading order where the weaker run loses.
- `SilenceDetectionService` — Scans audio files for silence gaps using `AVAudioFile` + `Accelerate` buffer processing. Returns `[SilenceGap]` (start/end/duration). Feeds `AlignmentChunkPlanner`'s preferred cut points.
- `ContinuousAlignmentService` — Background alignment drift correction during playback. Every 15 s reads the just-played media-time window from the file (`AudioSegmentReader`), transcribes it, and inserts an anchor when the transcript confidently matches a nearby block (≥8 words, projection sanity-checked, word-rate back-projection). Uses a re-entry guard to prevent overlapping transcription tasks. Opt-in via `continuousAutoAlignmentEnabled` setting. Uses single-pass O(N) timeline scan instead of O(N log N) sort to prevent main-thread stalls every 15 seconds.
- `WhisperSession` — Reference-counted, shared WhisperKit model manager (`@MainActor`). Prevents duplicate ~40 MB model loads when both `AutoAlignmentService` and `ContinuousAlignmentService` are active. Uses `acquire(model:)` / `release()` / `forceUnload()` lifecycle.
- `AudioSnippetPlayer` — Lightweight, single-use audio player for voice-memo previews and bookmark playback. Eliminates the ad-hoc `AVAudioEngine` setup previously duplicated across `BookmarkStore`, `Bookmarks`, and `SnippetPlayer`.
- `CloudKitSyncService` — Cross-device alignment anchor synchronization via CloudKit. Uses deterministic SHA-256 record names instead of `hashValue` for cross-device record matching. Uses `NSNumber`-based predicates to avoid floating-point precision loss.
- `MacAlignmentService` — macOS-specific streaming alignment orchestrator with EPUB picker UI and match threshold slider. Shares `WhisperSession` with iOS services. Precomputes word arrays to avoid per-sliding-window allocations. Parses EPUB blocks via the shared `parseEPUBBlocks` driver (not a Mac-specific parser), so its anchor block IDs match those the iOS importer writes (CODE_AUDIT.md §5.1).
- `AlignmentAnchorRecord` — A user-created or auto-generated lock point tying an EPUB block to an audio time. Includes `anchorKind` (chapterStart/chapterEnd/correction) and `source` (manual/auto/imported).
- `EPubBlockRecord` — Database row for a parsed EPUB block (heading, paragraph, or image). Includes `wordCount` (V8) for proportional math.
- `TimelineItem` — Materialized row linking blocks to audio timestamps with `timestamp_source` and `alignment_status`
- `TimestampSource` — Enum: `.lockedAnchor`, `.interpolated`, `.estimated`, `.none`
- `AlignmentStatus` — Enum: `.lockedAnchor`, `.interpolated`, `.estimated`, `.unaligned`, `.omitted`

### Word-Level Read-Along & Karaoke (June 2026)

Block-level read-along (the active paragraph) is refined to **word level** so the current word highlights as the narration speaks it, on both the iOS and macOS readers.

- **One word definition, by construction.** `WordTokenizer` (`Shared/`) is the single source of truth for read-along word boundaries: it splits on **all** Unicode whitespace (`Character.isWhitespace` — NBSP, line/paragraph separators, vertical tab, and form feed all count) and keeps attached punctuation with the word. The non-whitespace token *sequence* is invariant under any whitespace normalization, so the timing pipeline and both readers index the same words even when each renders a differently-normalized string — the highlighted-word index cannot drift.
- **Per-word timings (`word_timing`, Schema V19).** `WordTimingMaterializer` rebuilds the `word_timing` table for a book whenever the timeline is (re)built (from `AlignmentService.recalculateTimeline` and the auto-alignment pipeline). For each aligned block it distributes the block's words across its `[start, next-block-start)` span by character weight (`WordTimingInterpolator`, pure), then **refines** individual word times to real WhisperKit word timestamps wherever a DTW token maps cleanly to a rendered word (`TokenDTW.wordMatches` / `wordMatchesWithBisection` feeding `WordTimingRefiner`, pure); interpolation is the fallback so every word always has a monotonic time. Rows carry `confidence` + `source` (`interpolated`/`dtw`) and cascade-delete with their audiobook. (The on-device **narration** render loop opts out of this whole-book rebuild — it passes `recalculateTimeline(materializeWordTimings: false)` and instead materializes one chapter at a time via `WordTimingMaterializer.materializeChapter`, so a long render isn't O(chapters²); see *On-Device Narration*.) **The migration is additive — existing books light up only after a one-time per-book alignment re-run populates the table.**
- **Active-word resolution + rendering.** `ReaderActiveBlockResolver.activeWord(in:time:activeBlockID:)` (pure, in `Shared/`, unit-tested) resolves the spoken word within the already-resolved active block. iOS: `ReaderFeedViewModel` caches the book's word rows and publishes the active word; the collection-view coordinator retints the active `ParagraphCardCell`/`HeadingCardCell` in place (via `WordTokenizer` ranges → `NSAttributedString`), throttled to ~12 Hz with no full reload. macOS: `MacReaderFeedView` polls the active word faster (~80 ms) while playing, and `MacBlockCardView` highlights it positionally in an `AttributedString`.

### On-Device Narration — Synthesis Engine Core (June 2026)

For study EPUBs that have **no audiobook**, Echo can generate spoken audio on-device and produce the same sentence-synced, study-ready aligned book. This is **additive** — the WhisperKit alignment pipeline above is untouched and still runs whenever a real audiobook exists. The synthesis path is the *inverse* of alignment: because the audio is generated from the EPUB text, every timestamp is known at synthesis time, so the transcribe-and-DTW recovery step is unnecessary — anchors are written directly.

> **Phased rollout.** This documents **Plan 1 — the engine core**: schema, seams, state, text normalization, and the per-chapter render orchestration, all unit-tested behind a mock engine. The real on-device model (Kokoro CoreML/ANE) + grapheme-to-phoneme (MisakiSwift, Apache-licensed, no GPL espeak-ng), the one-time model download, the read-first "Listen" UI + voice picker, render-ahead scheduling, and `.m4b`/per-chapter export land in later plans. **No audible output ships yet.** Design spec: `docs/superpowers/specs/2026-06-13-epub-ai-narration-design.md`.

> **Update (June 2026 — engine real + upstream chunking).** The real engine has since shipped: Kokoro-82M runs on-device via **FluidAudio (CoreML/ANE)** behind the `TTSEngine` seam, narration plays through the main playback pipeline (iPhone + CarPlay), and the rendered cache is **lossless ALAC** in `.m4a`. **Upstream input chunking (required):** FluidAudio does no internal chunking and caps IPA input at ~510 phonemes ("chunk longer prompts upstream"). A whole 400+ char block drove the palettized vocoder's BNNS fallback into a dynamic tensor shape that **traps** (uncatchable `EXC_BREAKPOINT` in `libBNNS`), so `NarrationService.renderChapter` splits each EPUB block into ~200-char sentence sub-chunks (`NarrationTextChunker`, pure/testable) and synthesizes each separately before concatenation — keeping inference shapes bounded and yielding finer audio, while still writing **one `.synthesized` anchor per original block** (spanning the summed sub-chunk durations) so the data model below is unchanged.

> **Update (2026-06-15 — on-device hardening + A14 gate).** **A14 status (corrected):** stream-to-sink fixed the A14 **jetsam**, but the **BNNS vocoder trap (§3.1) still RECURS** (device-confirmed — crashed 3× in one session; a full re-render triggers it). So on-device narration is now **gated to A15+** (`NarrationCapability`, gate by chip generation via the device model, not OS version) as the interim — the audio-less reader stays functional; the proper A14 fix is the vocoder model swap (1A). **Persistence:** chapters render **once and persist** — the render loops (`PlayerModel+Narration.swift`) skip synthesis when the chapter file already exists, so reopen/export/per-item narration don't re-burn the ANE. Cache validity is keyed by `NarrationFileNaming.renderVersion` in the filename — bump it when the rendered audio changes and stale files regenerate once; `staleVoiceFiles` sweeps stale voices **and** orphaned versions. **Audio quality:** the perceived "whine/reverb" was a **playback artifact**, not the render — `AVAudioUnitTimePitch` ran its phase-vocoder even at 1× (a `pitch=0.01` workaround); `AudioEngine.applyPlaybackRate` now **bypasses the unit at 1×** (clean passthrough) and maxes `overlap` (32) for the 2× stretch. (A render-side low-pass was tried and reverted — wrong layer.) **Voice picker:** `VoicePickerView` reachable from Now Playing (was dead UI); catalog trimmed to **Ava only** because FluidAudio's ANE Kokoro ships only `af_heart` (others 404 until their `[510,256]` fp32 `.bin` packs are bundled).

> **Update (2026-06-17 — m4b chapter markers).** Combined-`.m4b` export now writes real Nero `chpl` + QuickTime `chap` chapter atoms via the `swift-audio-marker` package (iOS target only); `ChapterMarkerWriter` replaces the copy-only `AudioMarker` stub, and `NarrationExportService` labels chapters with their real `TrackRecord` titles. *(Superseded 2026-06-23: the note here said AVFoundation could not surface these atoms — that was an upstream-package bug, now fixed in Echo's fork; AVFoundation/Apple Books reads the chapters and tags. See the Chaptered M4B Export "Forked `swift-audio-marker`" note.)*

> **Update (2026-06-17 — narration on macOS).** On-device narration now runs on **macOS** too — a target-wiring + de-gating port, not new ML work (FluidAudio is `.macOS(.v14)`-capable and M-series doesn't hit the A14 ANE trap, so no model swap). FluidAudio is linked to the Echo macOS target and `KokoroTTSEngine` is de-gated to `os(iOS) || os(macOS)`. The one iOS-coupled helper, `PlayerModel.narrationCacheDirectory()`, moved into a cross-platform **`NarrationCache.directory()`** (the iOS symbol stays as a forwarder); a new **`NarrationEngineFactory.make()`** (gated to iOS+macOS — the only targets that compile `EchoCore` and link FluidAudio) supplies the real `KokoroTTSEngine` behind the seam. macOS synthesis runs **in the overnight batch queue** (see the batch section): a `kind == .narrate` item imports a standalone EPUB's blocks (no audio), plans chapters with `NarrationChapterPlanner`, and drives `NarrationService.renderChapter` into the same `NarrationCache`, honoring the shared `narrationVoiceID` preference. Playback is **DB-driven**: because rendered files live in Application Support (outside any scanned folder), `MacPlayerModel.loadNarratedBook(audiobookID:)` sources its track list from `TrackRecord` rows (ordered by the pure, shared `NarrationTrackOrdering`) instead of a filesystem scan. The three narration views (`VoicePickerView`, `NarrationStatusView`, `NarrationNudgeView`) are ported to the macOS target, with a voice picker in the macOS Settings *Playback* pane. No SoC gate on Macs — the A15+ branch stays iPhone-only. *(`.m4b` export expanded to cross-platform in a later update — see the Export module section below.)*

> **Update (2026-06-18 — lexicon-only G2P + pronunciation overrides).** MisakiSwift's MLX-backed **BART out-of-vocabulary fallback** (and the transitive `mlx-swift` dependency) was **removed**, making English G2P (`KokoroG2P` → MisakiSwift's `EnglishG2P`) **lexicon-only** (`us_gold`/`us_silver`). This unblocks the iPhone-simulator test suite — `mlx-swift` 0.30.2 references Metal symbols undefined on the simulator ([mlx-swift#341](https://github.com/ml-explore/mlx-swift/issues/341)), which had transitively failed every sim test — and trims ~15 MB of `us_bart` weights from the bundle. `EnglishFallbackNetwork` is now a graceful stub: an OOV word emits the `unk` glyph (dropped by `KokoroPhonemeVocab` → silent) rather than crashing or guessing. To recover pronunciations for OOV words (proper nouns, tech terms), a user **pronunciation dictionary** — `PronunciationOverrideStore` (`@Observable`, JSON-persisted global map; **Settings ▸ Pronunciation**) feeding the pure `PronunciationOverrides` rewriter — wraps chosen words in MisakiSwift's `[word](/ipa/)` link syntax, which `EnglishG2P` injects at **rating 5** (above both the lexicon and the removed fallback). The rewrite runs in `NarrationService.renderChapter` **after `TextNormalizer` and before `NarrationTextChunker`**; the link token has no spaces or sentence terminators, so it survives chunking and reaches both the iOS and macOS render paths.

> **Update (2026-06-19 — engine pivot to ONNX Runtime; CoreML stack removed).** The narration engine is now **`OnnxKokoroEngine`** (ONNX Runtime, CPU EP) on **both iOS and macOS**, replacing the entire CoreML stack. *Why:* the CoreML path AOT-compiled its model graphs on-device on first run — ~20 min on an A14, because the LSTM duration predictor's Espresso compile is O(n²) in token length — and routed the vocoder onto the ANE, which **trapped** (`libBNNS` `EXC_BREAKPOINT`) on A14. ONNX Runtime *interprets* the graph (no AOT compile, ≈0.7 s `ORTSession` load) and its CoreML EP can't run Kokoro's dynamic shapes, so it runs on the **CPU EP by construction — never touching the ANE**, which removes the trap entirely. On-device A14 (iPhone 12 Pro): ≈0.7 s load, RTF ≈ 0.5 (twice real-time), no crash. The engine loads the single `model_fp16.onnx` graph (~163 MB, `onnx-community/Kokoro-82M-v1.0-ONNX`; inputs `input_ids` i64 / `style` f32[1,256] / `speed` f32 → `waveform` f32 @ 24 kHz) and **reuses the existing front end verbatim** — MisakiSwift G2P (`KokoroG2P`), `KokoroPhonemeVocab` (BOS/EOS-wrapped ids, widened to Int64 for ORT), and `KokoroVoicePack` (the `af_heart` refS row); only the runtime changed. `NarrationFileNaming.renderVersion` **6** captured the ONNX-byte transition; **7** reserves the segment-render cache layout for hybrid streaming. The `model_fp16.onnx` download is pinned to an **immutable upstream commit** (not the moving `main` ref, so an upstream re-upload can't silently change the model behind the pinned ONNX cache) and **integrity-checked by exact byte size** before the `ORTSession` loads it — a truncated or stale file is discarded and re-fetched — with byte-level download progress. **`NarrationCapability` now reports narration available on every iOS 18 / macOS 15 device** — the former A15+ gate existed only for the ANE trap. **Removed:** `KokoroFixedShapeEngine` (fixed-shape CoreML), `KokoroTTSEngine` (FluidAudio), `NarrationModelStore` (the 731 MB CoreML downloader), and FluidAudio's `KokoroAneError` handling in `NarrationService`. (The supersedes the four CoreML-era update notes above; they remain as history. Pivot decision: `docs/superpowers/research/2026-06-19-kokoro-onnx-pivot-decision.md`.)

> **Update (2026-06-20 — render-loop perf + chapter outline).** A performance pass on the render loop plus a user-facing chapter outline (a multi-agent adversarial review drove the findings; design: `docs/superpowers/specs/2026-06-20-narration-chapter-outline-design.md`). **(a) Engine front-half cached.** `OnnxKokoroEngine.synthesize` previously rebuilt its whole front end — `KokoroG2P` (which parses ~6 MB of `us_gold`/`us_silver` lexicon JSON), `KokoroPhonemeVocab`, and `KokoroVoicePack` — on **every ≤200-char sub-chunk**. They are now loaded once into a cached **`KokoroFrontEnd`** held on the engine actor (voice packs memoized by id); `synthesize` calls `frontEnd.encode(text:voice:)`. Behavior-preserving (same `(ids, refS)`); this per-chunk churn — not a retain-cycle leak (the render `Task` is `[weak self]`, audio streams to disk) — was the "memory grows" symptom. **(b) Chapter-scoped word timings.** `NarrationService.renderChapter` no longer triggers the whole-book `word_timing` rebuild every chapter (O(chapters²) across a render run): it passes `recalculateTimeline(materializeWordTimings: false)` and materializes only the just-rendered chapter's words via the new block-scoped **`WordTimingMaterializer.materializeChapter`** (+ `WordTimingDAO.deleteAll(forAudiobook:blockIDs:)`), so incremental per-word read-along still lights up per chapter. The reader's `.timelineItemsIngested` handler (`ReaderTab`) now coalesces its per-chapter whole-book reloads into one trailing reload. **(c) Chapter outline + tap-to-exclude (iOS).** The playlist surfaces the **full EPUB chapter outline** for a narration book — every narratable chapter, independent of render progress — built by the pure **`NarrationOutlineBuilder`** (→ `NarrationOutlineChapter`) from all blocks + an injected file-exists check. Tapping a chapter excludes it from narration by hiding its blocks (the existing `is_hidden` axis; new `EPubBlockDAO.unhideChapter` / `AlignmentService.unhideChapter`), so it drops from `NarrationChapterPlanner.plan(from: visibleBlocks)` — never synthesized or queued — while its rendered file is kept on disk for instant re-include. `PlayerModel.isNarrationBook` / `narrationOutline` / `toggleNarrationChapterExcluded` drive `PlaylistView`. **No schema change.**

> **Update (2026-06-21 — all 28 English voices + voiced OOV fallback).** **Voices (supersedes the "Ava only" note above):** the catalog now ships **all 28 English Kokoro voices** — American (`af_*`/`am_*`) + British (`bf_*`/`bm_*`). Their `[510,256]` fp32 style packs are bundled at `EchoCore/Resources/<id>.f32` (~14.6 MB total), fetched verbatim from `onnx-community/Kokoro-82M-v1.0-ONNX` by **`Tools/fetch_kokoro_voices.py`** — the Hub `.bin` files are byte-identical to Echo's `.f32` format (af_heart sha256 matches), so it is download + rename, no PyTorch. Non-English Kokoro voices are excluded because the G2P is English-only. `VoiceCatalog` now carries `accent`/`gender`/`grade` per voice, orders best-first by Kokoro's published grade (`af_heart`/Ava stays the default and first entry), and exposes a `sections` helper grouping voices into American/British × Female/Male for the grouped pickers — `VoicePickerView` (iOS) and the narration `Picker` in `MacSettingsView` (macOS). Voice id is already part of the render-cache key (`NarrationFileNaming.chapterFileName`), so switching voices regenerates audio correctly and `staleVoiceFiles` sweeps the rest. **OOV fallback (supersedes the "graceful stub → silent" note above):** `EnglishFallbackNetwork` is now a deterministic, **vocab-safe grapheme→IPA approximator**. An out-of-vocabulary word (e.g. the name "Jacqui" → `ʤˈækɪ`) is voiced with a best-effort pronunciation instead of emitting the `❓` glyph that `KokoroPhonemeVocab` drops to silence. It folds diacritics (café→cafe), spells ALL-CAPS initialisms (FAQ, JSON), expands digits, applies 101 ordered grapheme rules, and falls back to a schwa `ə` — so a letter-bearing word never goes silent. Every emitted symbol is in the Kokoro vocab by construction (unmapped characters are dropped, never passed through); verified over a 160-word adversarial corpus + 10 golden cases, runnable sim-free via **`Tools/oov_check.swift`**. The user `PronunciationOverrides` dictionary remains the precise escape hatch (rating 5, above the fallback).

> **Update (2026-06-21 — read-along + player-chrome UX fixes).** **Read-along:** the karaoke retint (`ReaderFeedCollectionView`) now clears the previously-highlighted card when the active word crosses a paragraph boundary (pure `KaraokeHighlightTransition`; block changes bypass the 12 Hz throttle), and the highlight is **color/background only — no font-weight swap** — on iOS (`ParagraphCardCell`/`HeadingCardCell`) and macOS (`MacReaderFeedView`), so glyph metrics stay stable. Tapping a paragraph card seeks to it **and** starts playing via the canonical `PlayerModel.seek(toSeconds:)` + `play()` (pure `CardTapDecision`; iOS + macOS), with a no-time fallback; TOC navigation stays seek-only. **Player chrome:** the sleep-timer icon and every bottom-toolbar chip use the cover-derived accent (`PlayerModel.artworkAccentColor ?? .accentColor`); the active state is carried by the filled-chip shape, not color.

**Synthesis-time word timing (Kokoro):** For Echo-narrated books, per-word
read-along timing is captured at synthesis instead of being interpolated. A
28 MB ONNX "duration head" — the encoder + duration-predictor subgraph extracted
offline from `model_fp16.onnx` (see `Tools/extract_kokoro_duration_head.py`) and
bundled as `kokoro_dur_head.onnx` — runs alongside the waveform model in
`OnnxKokoroEngine` with identical inputs. `KokoroWordTimer` splits the phoneme
token stream on the space token (id 16), sums per-token frame durations per word,
and normalizes to the true sample count. `NarrationService` accumulates these
across chunks and `WordTimingMaterializer.refineWithSynthesis` overrides the
interpolated `word_timing` rows (`source:"synthesis"`, confidence 0.9). Any
failure (head absent, run error, word-count mismatch) leaves the interpolated
baseline in place. Imported audiobooks are unaffected — they keep the
WhisperKit + `TokenDTW` path.

**Data model (reuses existing tables):** A standalone EPUB is an `AudiobookRecord` with `epub_block` rows and **no tracks** (the natural empty state). Generating narration renders **one lossless ALAC `.m4a` file per chapter** (each block split into bounded sub-chunks before synthesis — default 350 chars, under Kokoro's ~510-phoneme context — then concatenated; see the upstream-chunking note above), inserted as a `TrackRecord` (`sort_order = chapterIndex`) carrying the voice in the new `narration_voice` column (**Schema V17**; non-null marks a synthesized track). `TrackRecord.title` comes from `NarrationChapterPlanner`: `ch. N: Heading` when the EPUB exposes a useful heading/title, otherwise the existing `Chapter N` fallback; cache-hit paths update old generic title rows without re-rendering audio. Each text block gets one `AlignmentAnchorRecord` with the new **`source = .synthesized`** written at synthesis time — so read-along highlighting and the study layer work for free, and re-alignment never confuses generated anchors for recovered ones.

**Key types (engine core):**

- `TTSEngine` — the swappable `Sendable` protocol boundary: `synthesize(_ text:voice:) async throws -> TTSChunk`. Mocked in tests; the Kokoro actor implements it later. `TTSChunk` carries mono `[Float]` PCM (not a non-`Sendable` `AVAudioPCMBuffer`) so it crosses the actor→main boundary safely.
- `AudioFileWriting` — `Sendable` protocol for writing `TTSChunk`s to one on-disk **lossless ALAC `.m4a`**. Two paths: the batch `write(_:to:)` and an incremental **stream-to-sink** session, `makeStream(to:sampleRate:) -> AudioFileStream`, whose `append`/`finalize` encode each chunk straight to disk. `AVFoundationAudioWriter` (a stateless `struct`) implements it; the session is an `actor` (`ALACFileStream`) that confines the non-`Sendable` `AVAudioFile` and runs the per-chunk encode off the caller's actor. `NarrationService.renderChapter` streams, so a chapter's peak memory is one ~200-char sub-chunk's PCM rather than the whole chapter's — the half of the A14 jetsam mitigation that doesn't need the model swap (audit §7.1).
- `VoiceCatalog` / `NarrationVoice` — the curated voice set (4 voices keyed by `VoiceID`; default "Ava", US/warm).
- `TextNormalizer` — pure, deterministic prose→speakable normalization (abbreviations, thousands separators, Roman-numeral chapters, em-dash pauses); the highest naturalness-ROI unit.
- `NarrationState` — `@MainActor @Observable` progress object mirroring `AutoAlignmentState` (phases: `idle`, `preparingChapter`, `renderingAhead`, `completed`, `failed`).
- `NarrationService` — `@MainActor @Observable` orchestrator mirroring `AutoAlignmentService`. `renderChapter(chapterIndex:blocks:voice:chapterTitle:)` normalizes + synthesizes each text block, writes one chapter file, and persists one `TrackRecord` + per-block `.synthesized` anchors with monotonic `audioTime`; `renderSegment` persists the same planner title for segment-backed playback/export. Cancellable between blocks and before any DB write, so a cancelled render persists nothing. (Re-render idempotency — clearing/upserting prior `syn-…` anchors in one transaction — is owned by the later orchestration plan.)

### Chaptered M4B Export (June 2026)

Any loaded book — narrated EPUB or imported m4b/mp3 — can be exported as a single chaptered `.m4b` on both iOS and macOS. The export module lives in `EchoCore/Services/Export/` and is structured around two orthogonal seams: **source** (where the audio comes from) and **writer** (how chapter metadata is embedded).

**Source seam (`ExportSource`).**  `ExportSourceResolver` inspects the book's tracks and auto-selects:

- `NarrationCacheSource` — assembles audio from per-chapter narration cache files (used for narrated EPUBs).
- `ImportedBookSource` — reads the book's original on-disk audio files directly (used for imported m4b/mp3 books).

Both sources expose the same chapter-ordered `[URL]` list consumed by the shared compose step.

**Compose + transcode.** `AudioExportService` is the shared spine: it gaplessly composes the chapter URLs into an `AVMutableComposition`, transcodes once via `AVAssetExportSession` (AAC / `.m4b`), and hands the result to the metadata writer.

**Writer seam (chapter markers + metadata).** A single in-place pass via the `swift-audio-marker` package (`AudioMarker` product, linked on **both iOS and macOS**) writes Nero `chpl` + QuickTime `chap` chapter atoms together with the book tags and cover art in one operation — no container rebuild, so chapters and metadata coexist. `ChapterMarkerWriter` maps the book onto the audiobook tags players expect (title/album = book title; artist/albumArtist = author, Audiobookshelf reads `aART`; genre `Audiobook`; `©cmt` = the narration version stamp) landing in the `ilst` atoms; album/albumArtist/genre default only when absent so a re-exported imported m4b keeps its real tags. `ExportMetadata` + `ExportMetadataResolver` supply title/author/cover.

> **Forked `swift-audio-marker` (Echo pins `dfakkeldy/swift-audio-marker` by immutable revision, tag 0.1.3).** Upstream 0.1.1 wrote the `ilst` tags without the iTunes `mdir` handler, so ffmpeg/AVFoundation/iTunes/Audiobookshelf ignored *every* tag and the cover art (`covr` lives inside `ilst`), and wrote a chapter text track AVFoundation couldn't read (missing `gmhd.text` / `edts/elst` / `ftab` `stsd`). The fork fixes all of it at the source (upstream PR [atelier-socle/swift-audio-marker#2](https://github.com/atelier-socle/swift-audio-marker/pull/2)) and additionally fails loudly on >4 GB chapter offsets and clamps over-long chapter titles. Output is verified readable across ffprobe/Audiobookshelf, AVFoundation/Apple Books, exiftool, and AtomicParsley.

**Headless CLI export.** `echo-cli narrate` (`HeadlessNarrationRunner`) titles chapters from the same planner/outline path as the apps (`ch. N: Heading`, falling back to `Chapter N`), resolves the cover from the EPUB OPF (`EpubCoverResolver`), and stamps the version comment. `echo-cli retag` (`M4BRetagger`) re-stamps an already-rendered m4b's chapter titles/tags/cover/comment **without re-rendering** — it reads the existing chapter *times* via the package reader (stale m4bs aren't AVFoundation-readable), re-titles from the EPUB, and re-writes through `ChapterMarkerWriter` (temp-then-move makes in-place retag safe).

**Cover-art resolution (source-aware).** `ExportMetadataResolver.resolveCoverArt` walks the same cascade the app uses to *display* a book's cover, so the exported file carries whatever artwork the user already sees — "from the EPUB, or the mp3's, whatever the source was":

1. **Embedded artwork** in the first source file (`commonKeyArtwork` → MP4 `covr` / ID3 `APIC`) — covers an imported m4b/mp3 that tags its own cover.
2. Failing that, branch on the source: a **narrated EPUB** reads the EPUB's stored front-matter cover image block (`EPubBlockDAO.allBlocks` → first front-matter `image` block's `imagePath`; the narration cache files carry no embedded art), and an **imported** book reads a `cover.*` sidecar beside the source file (the same sidecar `ArtworkCache.folderArtworkImage` surfaces at runtime).
3. Whatever is found is normalised to JPEG/PNG via ImageIO, because `swift-audio-marker` embeds only those two formats — JPEG/PNG pass through byte-for-byte, anything else (HEIC/WEBP/GIF/TIFF) is transcoded to JPEG so it isn't silently dropped.

**Entry points.** iOS: player More menu (`UnifiedTopHeader`) → share sheet (one tap; a pre-filled confirm sheet appears only when author or cover art is missing). macOS: File menu command → `NSSavePanel`.

**mp3 is intentionally deferred.** Apple frameworks cannot encode mp3; it needs a vendored LAME encoder. The decided strategy (per-chapter mp3 files) is recorded but not yet implemented.

### EPUB Reader Feed (Current)

The Reader tab renders EPUB content as a feed of styled cards aligned to the audio playback position. It replaces the earlier Timeline Feed prototype with a simpler, purpose-built reader surface.

**Database tables:** The `timeline_item` materialized table continues to store alignment data linking `epub_block` records to audio timestamps, with the same purpose-built indexes for efficient range queries.

**Dual-write synchronization:** When `BookmarkDAO` or `FlashcardDAO` creates, updates, or deletes a record, it also writes to `timeline_item` with the corresponding source tracking columns. This keeps the feed in sync without polling or triggers.

**Schema evolution: EPUB block alignment**

| Schema | Change |
|---|---|
| V5 | `epub_block` and `alignment_anchor` tables; extends `timeline_item` with `epub_block_id`, `timestamp_source`, `alignment_status`, `alignment_confidence` |
| V6 | Minor schema refinements |
| V7 | `html_content` (TEXT) and `card_color` (TEXT) columns on `epub_block` — preserves inner HTML for rich text rendering and per-card tint overrides |
| V8 | `word_count` (INTEGER) column on `epub_block` — enables proportional interpolation weighted by paragraph word length instead of raw sequence index |
| V9 | `markers` (TEXT) and `text_formats` (TEXT) columns on `epub_block` — stores JSON-encoded `[SyncMarker]` and `[TextFormat]` arrays extracted during unified EPUB parsing for richer reader display |
| V10 | `chapter_theme_color` (TEXT) column on `epub_block` — chapter-level themes set by the user on headings |
| V11 | `pdf_view_state_json` (TEXT) columns on `bookmark` and `timeline_item` — persists PDF page/zoom/scroll state for PDF bookmarks and alignment anchors |
| V12 | `is_front_matter` (BOOLEAN) column on `epub_block` — front-matter blocks (cover, praise pages, printed TOC) classified during import from EPUB structural metadata; grouped separately in the reader TOC and excluded from heading synthesis |
| V13 | `epub_toc_entry` table — the publisher-declared TOC tree (NCX navPoint / EPUB 3 nav nesting) persisted per audiobook with parent links, preorder ordering, depth, publisher titles, and block targets resolved via fragment anchors at import |
| V14–V19 | Capture & context (`session_location`, bookmark/note columns), Anki decks, FSRS + cloze/transcript, `track.narration_voice` (V17, marks synthesized tracks), Audiobookshelf server, and the `word_timing` table (V19) — see CHANGELOG.md for each |
| V20 | `batch_queue` table — the persistent macOS overnight processing queue (queue position, status, nullable security-scoped bookmarks) |
| V21 | `batch_queue.kind` (TEXT, default `'align'`) — discriminates audiobook-alignment items from text-only EPUB narration items (additive; no re-import) |
| V22 | FSRS memory-state seed (`v22_fsrs_seed`) — one-time, idempotent data migration seeding `stability`/`difficulty` from each legacy SM-2 card's `(interval_days, ease_factor)` so its first FSRS review evolves existing memory instead of restarting (only rows where `stability IS NULL`; the FSRS columns themselves shipped in V16) |
| V23 | Audiobookshelf provenance columns on `audiobook` (`source_type` TEXT, `server_id` TEXT, `remote_item_id` TEXT, `topics_json` TEXT) — all nullable, additive `ALTER TABLE`, no re-import or re-alignment needed |

Key indexes: `idx_epub_block_sequence` (audiobook_id, sequence_index), `idx_epub_block_chapter` (audiobook_id, chapter_index), `idx_epub_block_hidden` (audiobook_id, is_hidden), `idx_alignment_anchor_time` (audiobook_id, audio_time), `idx_alignment_anchor_block` (audiobook_id, epub_block_id).

### Study Plans (Schema V25)

`study_plan` stores a book-level generated study configuration: cadence, chapter limit, image inclusion, queue mode, catch-up policy, pause state, and the generated deck. `study_plan_item` stores ordered generated assignments and introduction state. Existing `flashcard` rows remain the review unit; generated assignment cards keep `next_review_date` nil until first grade, then `FlashcardDAO.grade` schedules future reviews through FSRS.

**Alignment pipeline:**

```
EPUB (directory or .epub file)
  └─ EPUBImportService
       ├── Parse container.xml → OPF spine order
       ├── Parse XHTML → paragraph-level blocks
       ├── Copy images → Application Support/EPUBAssets/<safeAudiobookID>/
       └── Write epub_block records → SQL

Auto-alignment (4-tier pipeline, on-device)
  └─ AutoAlignmentService
       ├── Tier 0: ChapterTitleMatcher.matchChapterTitles() → title → heading anchors (microseconds, no ML)
       ├── Tier 1: SilenceDetectionService → captureAndTranscribe → TokenDTW.align() → word-level DTW anchors
       ├── Tier 2: compare interpolated positions → flag drifted chapters (planned)
       ├── Tier 3: bisect flagged chapters → insert correction anchors (planned)
       └── fineTuneManualAlignment(blockID:around:) → refine manual anchor time

User anchors (manual)
  └─ AlignmentService
       ├── moveBlockToCurrentTime / anchorSearchResult / anchorChapterStart/End
       ├── eraseAnchor(blockID:) / resetAlignment()
       ├── hideBlock(blockID:reason:) / unhideBlock(blockID:)
       ├── hideChapter(chapterIndex:reason:)   ← batch chapter hide
       └── recalculateTimeline (word-count-weighted interpolation + dynamic CPS projection)

Code organization (June 2026):
  ├─ TokenDTW: new word-level DTW alignment engine replacing Tier 0 silence mapping
  │   └── Uses flat Int32/Int8 arrays for memory-efficient 3000×3000 token grid alignment
  ├─ Timeline Feed prototype: REMOVED 2026-06-13 — TimelineFeedCollectionView /
  │   TimelineFeedViewModel + its 10 orphaned cell subclasses, the ContentCard /
  │   TimelineService / RealTimeEvent (struct) models, and TranscriptOverlayView were
  │   dead (the Reader feed replaced them); ~3.9k LOC deleted. RealTimeEventType
  │   survives in Models/RealTimeEventType.swift (used by PlaybackEventLogger).
  ├─ ReaderTab: 901 → 576 lines — alignment & context menu operations
  │   extracted to ReaderTab+Alignment.swift
  ├─ PlayerModel: 1,295 → 1,103 lines — Bookmarks API extracted to
  │   PlayerModel+Bookmarks.swift
  ├─ EPUB XML parsing: ~190 lines of duplicated delegates per platform
  │   consolidated into Shared/EPUBXMLParsing.swift
  └─ New shared utilities: FileLocations, KeychainStore, Logger+Subsystem,
      AnimationDurations, WhisperSession, AudioSnippetPlayer

Continuous alignment (opt-in)
  └─ ContinuousAlignmentService
       └── Background drift detection during playback

CloudKit Sync
  └─ CloudKitSyncService
       └── Cross-device anchor synchronization
```

**Reader UI architecture:**

```
ReaderTab (SwiftUI)
  ├── ReaderHeaderView          ← search bar ("Find in book..."), scroll-to-active button, TOC button, settings button
  ├── Part/Chapter/Section title bar ← three-level sticky context (part → chapter → section)
  ├── Hint banners              ← context menu tip (one-time), alignment guidance (until first anchor)
  └── ReaderFeedCollectionView  ← UICollectionView via UIViewRepresentable
       ├── 4 cell types: HeadingCardCell, ParagraphCardCell, ImageCardCell, ChapterDividerCell
       ├── Anchor labels         ← green "locked" badge on manually-aligned cards (Heading/Paragraph)
       ├── Active block tracking — blue bar on the card matching current playback position
       ├── Auto-scroll — follows playhead via binary search on timeline cache; disengages on manual scroll
       ├── Force-scroll trigger  ← counter-based invalidation for repeated scroll-to-same-block
       ├── Context menu — long-press any card for:
       │    ├── Align to Now / Align to 5s Ago
       │    ├── Align to Chapter Start / Align to Chapter End (all blocks)
       │    ├── Not in Audio (This Paragraph) / Not in Audio (Whole Chapter) ← hide non-narrated content
       │    ├── Erase Anchor (if lockedAnchor) / Reset Alignment (all anchors)
       │    ├── Change Color / Save Bookmark / Copy Text / Save Image
       └── NSDiffableDataSourceSnapshot<String> — identity from ReaderCardItem.id
            └─ ReaderFeedViewModel (@Observable)
                 ├── Loads blocks from EPubBlockDAO, grouped by chapter
                 ├── Search: filters to matching blocks via blockDAO.searchBlocks()
                 ├── Active block: binary search on timelineCache for O(log N) lookup
                 ├── alignmentStatusByBlockID: [String: String] — per-block status for anchor badge display
                 ├── audioStartTimeByBlockID: [String: TimeInterval] — per-block timestamp for anchor labels
                 └── Data: [ReaderCardSection] — sections contain [ReaderCardItem] (chapterHeader or block)
```

**Key types:**

- `ReaderCardSection` — A group of cards under a heading hierarchy (e.g. ["Chapter 1", "Section 1.1"])
- `ReaderCardItem` — Enum with cases: `.chapterHeader`, `.block`, `.bookmark`, `.ankiCard`, `.note`, `.voiceMemo`
- `EPubBlockRecord` — Database row for a parsed EPUB block (heading, paragraph, or image)
- `ReaderSettings` — Font size, line spacing, and card tint color for the reader

**Unified Feed Initiative (Phases 1–5, June 2026):** The reader feed was progressively unified into a single "Read & Study" surface across five phases:

- **Phase 1 — Collapsible accordion (iOS):** The feed opens collapsed (one row per audio chapter = a built-in table of contents). Tap to expand inline; one chapter open at a time; the playing chapter auto-expands while audio is running. Each row is honestly labelled **has-audio** (any block in the chapter carries a real `timeline_item.audio_start_time >= 0` — anchor-locked, interpolated/estimated, or synthesized) vs **text-only** via `ChapterAudioStatusResolver` (`Shared/Services/`). New pure types: `FeedAccordion` (`Shared/`), `ReaderFeedDisplayBuilder` / `ReaderChapterGroup` (`EchoCore/Models/`). No schema change.

- **Phase 2 — Inline study items + off-switch + nav consolidation (iOS):** Bookmarks and Anki cards thread through the feed at their anchor positions (`ReaderCardItem.bookmark`/`.ankiCard`, collision-safe `bm-`/`fc-` ids; `ReaderFeedDisplayBuilder.spliceExtras`). A long-press chapter menu exposes a single off-switch: `OffStateResolver` (`EchoCore/Services/`) reconciles both off-state axes — `is_hidden` on EPUB blocks (narration, display, auto-cards) and `isEnabled` on audio tracks (playback queue) — through one `ChapterOffState` write so they can no longer drift. The separate chronological **Study** tab is retired; **Read** is relabelled **"Read & Study"**; deep links to the old surface remap to the Read tab. No schema change.

- **Phase 3 — Filters + session scope (iOS):** A filter row above the feed narrows by content type (Everything / Audio / Text / Pics / Bookmarks / Cards). A scope selector switches between *Whole book* and *Last session*; last-session scope shows a recap card (when, minutes, chapter range, counts) derived at query time from `real_time_event` + `playback_event`. New pure types: `FeedFilter`/`FeedContentType`/`FeedScope`/`FeedScopeResolver` (`Shared/`). No schema change.

- **Phase 4 — Voice memos + notes (iOS, Schema V24):** Two new content types thread through the feed — **typed notes** and **recorded voice memos** (`ReaderCardItem.note`/`.voiceMemo`; `FeedItemInjector` for per-section positioning). Schema V24: `note` gains `epub_block_id` for document-order positioning; a net-new `voice_memo` table stores standalone audio file + metadata. New: `VoiceMemoRecord`/`VoiceMemoDAO`, `NoteRecord.epubBlockID`/`NoteDAO`. The recorder (`VoiceMemoRecorder`) is iOS-only (excluded from macOS/CLI build targets).

- **Phase 5 — Sessions history + macOS parity (iOS + macOS):** A browsable **Sessions history** (`SessionsListView`) lists reconstructed listening sessions. There is no `playback_session` table — `SessionSummaryService` (`Shared/Services/`) groups `playback_event` rows by 5-minute wall-clock gaps, then derives GPS route / miles (from `session_location`), chapter range (overlap join on the `chapter` table), minutes, and bookmark/card/note counts into a pure `SessionSummary` (`Shared/`). Tapping a session opens a read-only scoped reader feed via `SessionScope` / `SessionScopeReducer` (pure, `Shared/`) applied in `ReaderFeedViewModel.reload()`. **macOS parity:** `MacReaderFeedView` (`Echo macOS/`) was extended to drive a SwiftUI-native collapsible chapter accordion reusing the UIKit-free pure types (`FeedAccordion`, `ChapterAudioStatusResolver`); it does not import the iOS `ReaderFeedViewModel` / `ReaderFeedCollectionView` (UIKit/EchoCore, iOS-only). No schema change (session data is derived in-query).

### Deck Import Source Anchors (June 2026)

Imported flashcards can be linked to the EPUB text they came from, reusing the portable block-ID **suffix** (`s<i>-b<j>`) the alignment sidecar already standardized (see *Mac → device alignment handoff*). `EPUBSourceAnchorResolver` (`EchoCore/Services/`, GRDB-backed) takes a card's `sourceAnchor` — a bare suffix, or a full legacy `epub-<book>-s<i>-b<j>` id — strips it to the suffix via `AlignmentSidecar.portableSuffix`, re-prefixes it with the importing book's `audiobookID`, and resolves it against `epub_block`; the result is persisted in `flashcard.source_block_id`. Two producers feed it: JSON decks gain an optional `sourceAnchor` per card (`DeckImportService.importDeckVNext`), and `.apkg` archives may carry a root **`echo-import.json`** sidecar — `{ formatVersion, targetMediaID, cards: [{ cardID | noteGUID, sourceAnchor, startTime?, endTime?, triggerTiming? }] }` — keyed by Anki `cardID` then `noteGUID` (`ApkgImportService.importVNext`). For JSON decks, `startTime`/`endTime` are optional when `sourceAnchor` resolves; source-only JSON cards persist with `flashcard.media_timestamp = 0` and `flashcard.end_timestamp = NULL` as current-schema compatibility placeholders. The sidecar annotates a *subset* of cards (an unlisted card is normal, not a warning). Resolution is non-fatal: unresolved / malformed / wrong-book / no-EPUB-block anchors and a malformed or target-less sidecar return structured `ImportDeckWarning`s (`ImportDeckResult`) and fall back to timestamp/manual placement when the card supplies a valid time range. A source-only JSON card whose anchor cannot resolve fails validation rather than importing without a placement anchor. **Concurrency:** the JSON path resolves *before* its write transaction; the APKG path resolves *inside* `writer.write` through a `static EPUBSourceAnchorResolver.resolve(…in:)` so no reader-backed resolver crosses into the `@Sendable` write closure. The legacy `importDeck(from:db:) -> Int` / `import(from:into:) -> Int` entry points remain as thin wrappers. No migration — `flashcard.source_block_id` predates this. The JSON path additionally carries the resolved id into the card's `timeline_item.epub_block_id` (`FlashcardDAO.syncToTimeline`), and `ReaderFeedViewModel` scopes its block→chapter lookup to the active audiobook so a shared block id never resolves to the wrong book. Plan/design: `docs/superpowers/plans/2026-06-25-deck-import-source-anchors.md`; follow-up JSON timing contract: `docs/superpowers/plans/2026-06-26-anchor-first-json-deck-import.md`.

### PDF Companion Document Support (June 2026)

When a PDF file is placed alongside an audiobook (alongside or instead of an EPUB), Echo provides a PDF reader with per-page alignment and bookmarking:

```
PDF in audiobook folder
  └─ PDFImportCoordinator
       └── Copies PDF into the audiobook folder (same-folder imports are no-ops)

PDFDocumentView (SwiftUI)
  ├── PDFKitView (UIViewRepresentable wrapping PDFKit.PDFView)
  │    ├── Single-page continuous vertical scroll mode
  │    ├── Auto-scales to fit width
  │    ├── Tracks page, zoom, and scroll offset as PDFViewState
  │    └── Long-press gesture → alignment/bookmark context menu
  ├── Confirmation dialog: Align to Now / Align to Specific Time / Create Bookmark
  ├── ManualAlignmentSheet → fine-tune alignment with scrubber joystick
  └── Screenshot capture: renders current PDF page to JPEG for bookmark images

PDFViewState (Codable, Equatable, Hashable)
  ├── pageIndex: Int       ← which page is visible
  ├── zoomScale: Double    ← current magnification
  ├── offsetX: Double      ← horizontal scroll offset in page coordinates
  └── offsetY: Double      ← vertical scroll offset in page coordinates

Bookmark persistence (Schema V11):
  ├── bookmark.pdf_view_state_json  ← JSON-encoded PDFViewState
  └── timeline_item.pdf_view_state_json ← same for alignment anchors
```

**Key types:**
- `PDFDocumentView` — SwiftUI view that loads and displays a PDF from the audiobook folder, with long-press context menu for alignment and bookmarking.
- `PDFKitView` — `UIViewRepresentable` wrapping `PDFKit.PDFView` with `PDFViewPageChanged`/`PDFViewScaleChanged`/`PDFViewVisiblePagesChanged` notification observers for state tracking.
- `PDFViewState` — Codable model capturing page index, zoom scale, and scroll offset for bookmark restoration.
- `PDFImportCoordinator` — Stateless enum that copies a PDF into the target audiobook folder (security-scoped), skipping the copy when source and destination are the same file.
- `ManualAlignmentSheet` — Modal sheet for fine-tuning PDF/audio alignment with play/pause, ±5s skip, a `ScrubberJoystick` for variable-speed scrubbing (exponential mapping), and audio snippet preview during scrub.
- `ScrubberJoystick` — Horizontal drag-track control with a spring-returning knob. Maps drag offset to a -1.0…1.0 value with exponential mapping (small pulls = slow, big pulls = fast) for precise scrubbing.

**Reader tab routing:** `RootTabView` checks `model.hasPDF` when `model.hasEPUB` is false, routing to `PDFDocumentView` instead of `ReaderEmptyState`.

### Hierarchical Chapter Titles (June 2026)

`PlaylistView.computeHierarchicalTitles(for:)` detects parent-child relationships between consecutive chapter titles using prefix matching, then formats nested chapters with leading dots (e.g., "Part 1", ".Chapter 1", "..Section A"). This makes Libation-style sub-section hierarchies and multi-level EPUB structures visually scannable in the playlist without requiring explicit part/section metadata.

### Reader Tab Header Hierarchy (June 2026)

The Reader tab's sticky header now displays a three-level hierarchy: **Part** (`.headline`, primary) → **Chapter** (`.headline` or `.subheadline`, primary or secondary) → **Section** (`.caption`, secondary). When a part title exists, the chapter title renders smaller and in secondary color, creating visual depth. The `ReaderFeedCollectionView` receives a `$topPartTitle` binding alongside the existing `$topChapterTitle` and `$topSectionTitle`.

When the book declares a TOC (Schema V13 `epub_toc_entry`), the header's `headingStack` is the publisher's ancestry path for the current block — e.g. "1. A Pragmatic Philosophy › Topic 3. Software Entropy › Challenges" — computed in `ReaderFeedViewModel` by binary-searching the entry resolved at-or-before the block's `sequence_index` and appending deeper in-file headings. The previous heading-level cascade (which could pin an early `<h1>` like "Foreword" as a permanent ancestor) remains only as the fallback for books without a declared TOC.

### UI Architecture (3-Tab)

The iOS app uses a 3-tab layout managed by `RootTabView`:

```
RootTabView
├── Tab 0: NowPlayingTab   ← pure media consumption (album art, scrubber, transport)
└── Tab 1: ReaderTab        ← Read & Study: EPUB/PDF reader, search, alignment, TOC,
                              capture surfaces, review/library entry points, and empty states
```

**NowPlayingTab** focuses entirely on active playback: `AlbumArtHeroView`, `PlayerScrubberView`, and `TransportControlsView`, plus a `< Chapter Title >` chevron nav bar in `metadataArea` flanking the title marquee (gated by `PlayerModel.hasPreviousChapter` / `hasNextChapter`, reusing the chapter-aware `skipBackwardNavigation()` / `skipForwardNavigation()` the lock screen and CarPlay use). Per-listen controls live elsewhere (BookPlayer-style redesign, June 2026): **playback speed, the 3-way loop, seek/skip durations, Smart Rewind, and Volume Boost** moved into a presented `PlaybackOptionsSheet` (opened from the Now Playing speed indicator — both the static `BottomToolbarView` speed chip via an injected `onShowPlaybackOptions` closure threaded through `UnifiedBottomDock`, and the configurable `TransportControlsView` `.speed` slot via a `showPlaybackOptions` `EnvironmentKey` installed by `NowPlayingTab`). A player-scoped `PlayerMoreMenu` in the `BottomToolbarView` dock holds Chapters (presents `ChapterPickerSheet` as a jump-to-chapter navigator), Bookmarks (switches to Read & Study), an inline Sleep-timer submenu, and Settings — distinct from the app-level `UnifiedTopHeader` ellipsis menu, and wired at both `UnifiedBottomDock` call sites (NowPlayingTab + the RootTabView overlay).

**ReaderTab** (available when `model.hasEPUB` is true; `model.hasPDF` provides a `PDFDocumentView` fallback) is the EPUB-backed reading surface. It renders the book as a feed of styled cards — headings, paragraphs, and images — aligned to the audio playback position. The header auto-hides on scroll-down and reveals on scroll-up. It includes:
- A search bar for full-text search across the EPUB with inline match highlighting
- A Table of Contents sheet for structural navigation
- Auto-scroll that follows the audio playhead, highlighting the active paragraph with a blue bar
- Long-press context menus on every card for fixing alignment, changing card colors, creating bookmarks, and copying text
- Per-card alignment anchors that lock EPUB blocks to exact audio timestamps

`PlaylistView` is presented from the player-scoped menu for track/chapter browsing and reordering (with `.onMove` drag handles and per-item toggle controls).

When a book is loaded, a `PlayerControlBar` mini-player appears above the `BottomToolbarView`,
showing artwork, title/chapter metadata, and play/pause — tapping it opens the full NowPlaying view.
```

### PlayerModel Decomposition

`PlayerModel` has been decomposed from a ~2,900-line god class into a thin coordinator (~1,100 lines) that owns and wires together 20+ focused services. The Bookmarks API (~190 lines) has been extracted to `PlayerModel+Bookmarks.swift`, following the same extension-file pattern as `PlayerModel+PlaybackControllerDelegate.swift`, `PlayerModel+PlaybackLogging.swift`, and `PlayerModel+WatchState.swift`. Each service has a single responsibility:

| Service | Responsibility |
|---|---|
| `PlaybackController` | Core playback logic, track-end handling, enabled-state enforcement, navigation |
| `PlaybackState` | Shared mutable state (tracks, chapters, progress, artwork, chapterSections) as `@Observable` |
| `BookmarkStore` | Bookmark CRUD, voice memo playback, file cleanup, enabled-state toggling |
| `SleepTimerManager` | Countdown, fade-out, pause-on-end |
| `NowPlayingController` | MPNowPlayingInfoCenter, MPRemoteCommandCenter |
| `ChapterGroupingService` | Detects and collapses Libation-style sub-section chapter atoms into logical chapters, retaining section boundaries for scrubber tick marks |
| `ChapterLoadingCoordinator` | Chapter parsing, transcript loading, word cloud computation, invokes `ChapterGroupingService` |
| `PlaybackProgressPresenter` | Progress updates, elapsed time formatting, Now Playing info |
| `PlayerLoadingCoordinator` | Folder/track loading, audio session setup, persistence, seek-on-load |
| `BookmarkArtworkCoordinator` | Artwork generation, caching, Now Playing artwork updates |
| `PlayerTimelinePersistenceService` | Timeline item ingestion, EPUB presence checks |
| `EPUBImportCoordinator` | EPUB file import and block ingestion |
| `BookSettingsOverrideStore` | Per-book font, volume boost, and bookmarks-inline overrides |
| `BookPreferencesService` | Resolution logic for per-book + global preference merging |
| `WatchStateContextBuilder` | Builds the watch connectivity state dictionary |
| `WatchCommandRouter` | Routes incoming watch commands to the appropriate facade method |
| `PlaylistManager` | Track/chapter ordering, enabled-state toggling, reset |
| `PlaylistManifestService` | `.echoplaylist.json` manifest read/write/migration |
| `Persistence` | UserDefaults and on-disk state persistence |
| `SecurityScopeManager` | Security-scoped resource access grants |
| `TranscriptService` | Transcript JSON loading, word cloud computation |

PlayerModel wires these via coordinator closures in `init()` and exposes thin pass-through computed properties for view binding. The decomposition uses two patterns:

1. **Direct injection** (data-access services): `PlaylistManager`, `TranscriptService`, `SecurityScopeManager` receive `PlaybackState` and `Persistence` directly.
2. **Coordinator closures** (behavioral services): `PlaybackController`, `BookmarkStore`, `ChapterLoadingCoordinator`, etc. communicate back to `PlayerModel` through `@ObservationIgnored` closure variables wired in `init()`.

### Player Layout Styles

The iOS player supports two layout variants, selected via **Settings > Customization > Phone Player Designer > Player Layout Style** (`PhonePlayerSettingsView`):

| Style | Scrubber | Transport Controls | Target |
|---|---|---|---|
| **Default** | Slider above time labels (vertical stack) | Full-size (76pt play/pause, 64pt others) | Standard experience |
| **Compact** | Slider between time labels (horizontal row) | Reduced-size (60pt play/pause, 50pt others) | Minimalist, one-handed use |

The layout style is persisted in `SettingsManager.playerLayoutStyle` (UserDefaults key `playerLayoutStyle`) and drives conditional rendering in `PlayerScrubberView` and `TransportControlsView`.

Each transport button now supports a **dual-action model**: a tap executes the primary action (configured via `PhonePlayerSettingsView` under "Tap Actions"), while a long-press (>0.5s) executes a secondary action (configured under "Long Press"). The `TransportButton` component uses a custom `PrimitiveButtonStyle` (`TransportPrimitiveButtonStyle`) to layer both gestures onto a single control without the gesture conflicts that arise from stacking `.onTapGesture` + `.onLongPressGesture` on a standard SwiftUI `Button`. Both action sets are persisted in `SettingsManager.phonePage` and `SettingsManager.phoneLongPressPage`, and saved/loaded in `PhonePreset` data models. The `.previousTrack` / `.nextTrack` / `.loopMode` actions were retired from the *selectable* `PhonePlayerSettingsView` palettes (chapter navigation now lives in the metadata chevron bar; loop in `PlaybackOptionsSheet`). This is **passive** — every `WatchAction` enum case and its render/dispatch arm remain, so saved layouts and the watch/CarPlay wire protocol keep decoding — and the fresh-install default `Defaults.phonePage` is now `[.skipBackward, .empty, .playPause, .empty, .skipForward]`.

### Settings Restructure (BookPlayer redesign, June 2026)

`SettingsView` was gutted from a monolith into a **thin app-level shell** holding only app-level rows that link out to subscreens: Display→Appearance, Store→Pro Transcripts, Customization→(Phone Player Designer, Watch App Settings, Advanced), Flashcards, Help, and DEBUG-only sections. No inline per-listen playback controls remain in Settings — those moved to `PlaybackOptionsSheet` (see *UI Architecture*). The former inline sub-views were **extracted** into their own files — `SettingsAppearanceView`, `FontSelectionView`, `ThemeSelectionView`, `ProTranscriptsSettingsView`, `AppIconSelectionView` — plus a new `SettingsAdvancedView` (the relocated Continuous Auto-Alignment + Play-Bookmarks-Inline toggles), routed through `NavigationDestinations`. The `ThemeColor` enum moved to `EchoCore/Models/ThemeColor.swift` so the macOS Settings scene can reuse it.

### Chapter Sections & Section Navigation

Libation-ripped M4B audiobooks encode chapters as fine-grained sub-section atoms with shared base titles (e.g. "Chapter 11. A", "Chapter 11. B"). `ChapterGroupingService` collapses these into logical chapters and retains the original atoms as **sections** in `PlaybackState.chapterSections` (a `[Int: [Chapter]]` map keyed by logical chapter index).

**Section ticks on scrubber:** `PlayerScrubberView` overlays a `SectionTickOverlay` (`Canvas`-based, `allowsHitTesting(false)`) that draws hairline tick marks at each sub-section boundary. While scrubbing, the slider snaps to these boundaries with haptic feedback (`UIImpactFeedbackGenerator`), limited to a maximum of 20 visible ticks per chapter to avoid visual clutter.

**Section navigation:** Two `WatchAction` cases — `.nextSection` and `.previousSection` — are available on both phone and watch button layouts. They mirror chapter-level navigation but operate at the section level:
- `nextSection()`: seeks to the next section boundary within the current logical chapter, falling back to the next chapter.
- `previousSectionOrRestart()`: seeks to the previous section boundary (or restarts the current section if > 5 seconds in), falling back to the previous chapter.

These actions are routed through `PlaybackController` → `WatchCommandRouter` → `WatchConnectivityCoordinator` for watch-initiated commands, and directly for phone transport controls (either as tap or long-press secondary actions).

**Watch page layout:** The watch app supports up to 5 customizable pages of action slots (25 total), synced from the phone via `SettingsManager.watchPage1` through `watchPage5` App Group keys. Pages whose slots are all `.empty` are automatically hidden from the watch `TabView`. Configuration is managed in `WatchAppSettingsView` using a swipeable `TabView` with page indicators. The `watchTitleScrollSpeed` setting (Double, defaults to 30.0) controls the pixels-per-second scrolling rate for long titles in the watch player.

**Playlist disclosure groups:** In `PlaylistView`, logical chapters with section data render as `DisclosureGroup` rows, expanding to reveal tappable section rows that seek to each section boundary. A play icon indicates the currently active section.

### Reader Interaction Model

The Reader uses a tap/long-press interaction model on card cells:

| Gesture | Target | Action |
|---|---|---|
| **Tap** | Paragraph / heading card | Seek playback to the block's audio timestamp |
| **Tap** | Image card | Open image in system viewer |
| **Long press** | Any card | Context menu: Align to Now, Align to 5s Ago, Align to Chapter Start, Align to Chapter End, Not in Audio (This Paragraph), Not in Audio (Whole Chapter, if in a chapter), Erase Anchor (locked anchors), Reset Alignment (all anchors), Change Color, Save Bookmark, Copy Text, Save Image (images only) |

**Active block tracking:** The paragraph currently matching the audio playback position is highlighted with a blue leading bar (`activeBar`) on its card. The ReaderFeedViewModel performs a binary search on a cached `[(start, end, blockID)]` array for O(log N) lookup each time the playback position changes.

**Auto-scroll:** When enabled, the collection view auto-scrolls to keep the active block centered. Scrolling manually pauses auto-scroll; tapping the scroll-to-active button (↓) in the header re-engages it with an immediate forced scroll to the current playback position. The header auto-hides on scroll-down and reappears on scroll-up.

**Bookmark lifecycle:** Bookmarks created via `BottomToolbarView.addBookmarkButton` flow through `BookmarkStore.appendBookmark` → `BookmarkDAO.syncToTimeline` → `timeline_item` table. The `.bookmarksDidChange` notification triggers a feed refresh, ensuring bookmarks appear inline immediately.

**Playlist management:** `PlaylistView` (opened from the player-scoped menu) provides track/chapter reordering via drag handles in edit mode, per-item enable/disable toggles, and bookmark browsing with swipe-to-edit. The backend is handled by `PlaylistManager` (track/chapter ordering and enabled-state persistence) and `PlaylistManifestService` (`.echoplaylist.json` manifest I/O).

### EPUB/PDF-to-Audio Data Model: Handling Mismatches

The in-app alignment system estimates block timestamps from chapter boundaries and user-created anchors. When the EPUB contains content that has **no corresponding audio** — images, footnotes, skipped prose, tables — it is preserved in the feed for visual browsing.

**Un-timestamped items:**

| Property | Timestamped Segment | Un-timestamped (EPUB-only) Block |
|---|---|---|
| `startTime` (Enhanced) | `TimeInterval` (e.g. 12.5) | `nil` |
| `endTime` (Enhanced) | `TimeInterval` (e.g. 15.2) | `nil` |
| `audioStartTime` (TimelineItem) | Valid `TimeInterval` | `-1` (sentinel) |
| `sequenceIndex` (Enhanced) / `epubSequenceIndex` (TimelineItem) | Monotonic, shared with un-timestamped items | Monotonic, interleaved by EPUB position |
| `markers` | `[SyncMarker]?` from alignment | Contains the source marker (`.image`, `.footnote`, etc.) |
| `isTimestamped` | `true` | `false` |

The ingestion layer (`TimelineIngestionFactory`) converts `nil` timestamps from `EnhancedTranscriptionSegment` to `-1` in `TimelineItem.audioStartTime`. The `isTimestamped` computed property on `TimelineItem` checks `audioStartTime >= 0`, centralizing the sentinel convention.

**Ordering:** Timestamped segments sort by `startTime`. Un-timestamped blocks sort by their source marker's `epubCharOffset`. The pipeline merges both into a single `[EnhancedTranscriptionSegment]` array, assigns consecutive `sequenceIndex` values, and writes the output as enhanced transcript JSON.

**Feed behavior:**
- **Tapping** a timestamped segment seeks the audio playhead to `startTime`.
- **Tapping** an un-timestamped block (image, footnote) opens it in the system viewer — no seek occurs.
- Both types render inline in correct EPUB reading order, preserving the author's intended structure even when the audiobook narration skips content.

**Orphan threshold:** A marker is classified as "orphaned" (un-timestamped) when its `epubCharOffset` is more than 50 characters from the nearest alignment range boundary. This threshold prevents spurious un-timestamped items from minor alignment jitter while catching genuinely unmatched EPUB content.

### Reader-Specific Toolbar Controls

When the user is on the Reader tab (`selectedTab == .read`), `UnifiedBottomDock` keeps the `PlayerControlBar` visible above `BottomToolbarView` so reading, playback, and study capture stay close together:

```
UnifiedBottomDock (Reader mode)
├── PlayerControlBar     ← mini-player seek/play controls
└── BottomToolbarView
    ├── PlayerMoreMenu
    ├── speedMenu        ← inline speed presets
    ├── markPassageButton
    ├── readToggleButton ← Now Playing / Read toggle
    └── bookmarkCaptureMenu
```

The speed menu is backed by `SettingsManager.Defaults.speedPresets` and calls `PlayerModel.setSpeed(_:)` directly. Playback Options remains available from the same menu for loop and seek-duration settings.

### Anchor Status Indicators on Cards

**Reader feed cards:**
- `HeadingCardCell` and `ParagraphCardCell` include an `anchorLabel` (top-right corner) that always displays the block's audio timestamp (or "None" if unaligned). Locked-anchor timestamps render in **red** (`.systemRed`); estimated/interpolated timestamps render in **secondary label color**. The `setManuallyAligned(_:timeString:)` method controls both visibility and color.
- The alignment status and audio start time caches are maintained in `ReaderFeedViewModel` (`alignmentStatusByBlockID`, `audioStartTimeByBlockID`) and passed through `ReaderFeedCollectionView` to the coordinator for cell configuration.

**Removed feed prototype:** Timeline-specific feed cells were removed with the old prototype; locked-anchor UI now lives in Reader feed cards and alignment context menus.

### Debug Development Assets

The project includes a development assets bundle for testing the EPUB reader pipeline:

```
EchoCore/Development Assets/macbeth_m4b/
├── macbeth.epub           ← Shakespeare's Macbeth (EPUB)
└── William Shakespeare - Macbeth.m4b  ← matching audiobook
```

In `#if DEBUG` builds, `SettingsView` exposes a "Load Development Assets" button under a "Debug Menu" section. This invokes `PlayerModel.loadFolder()` with the main bundle URL, loading the Macbeth audiobook and EPUB for immediate testing of the reader, alignment, and search features without requiring external file selection.

### Swift Concurrency & Thread Safety (Swift 6 language mode, June 2026)

All Echo-owned Xcode targets compile in **Swift 6 language mode** with `SWIFT_STRICT_CONCURRENCY = complete` set explicitly per target, alongside `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (so a type with no explicit isolation is inferred `@MainActor`). SwiftPM dependencies keep their own package-declared language modes — the migration never forces them to Swift 6. Deployment floors are unchanged (iOS 18 / macOS 15 / watchOS 11).

The posture for resolving isolation across boundaries, in order of preference:
- **`isolated deinit` (SE-0371)** for `@MainActor` classes whose teardown must call main-actor methods (`DefaultChimePlayer`, `DefaultVisualizerTap`, `SecurityScopeManager`, `NowPlayingController`). A few older deinits (`PlayerModel`, `AudioEngine`, `SleepTimerManager`) still use `MainActor.assumeIsolated { … }` to avoid an iOS-26.x **simulator** `isolated deinit` bad-free bug — swap them once that is fixed.
- **`nonisolated`** on pure value types and stateless static helpers so they cross actor boundaries freely (`Bookmark`, `Chapter`, `WordFrequency`, `PDFViewState`, `SessionSummary`, `OKLCH`, `CoverTheme`, `SafeFileName`, the deck-import/source-anchor value types, …).
- **`sending`** on non-`Sendable` payloads handed off exactly once into a `@MainActor` task (WCSession messages/replies, MetricKit payloads, `AVAsset`).
- **Cancellable `Task` loops** in place of `Timer.scheduledTimer` for main-actor UI tickers (snippet/joystick scrub, audio fade, watch alarm haptics, voice-memo elapsed). `MainActor.assumeIsolated { … }` is still used for timers/observers genuinely guaranteed to fire on the main run loop or `queue: .main`.
- **`Mutex` (`Synchronization`, iOS 18+)** for state shared across isolation domains without an actor: the one-shot `AVAudioConverterInputBlock` feed in `AudioSegmentReader`, the `ProgressFanOut` terminal-replay box, and the macOS `ReadyToPlayGuard` single-resume continuation.
- **Actor-scoped resources**: `LocationCaptureService` is an `actor` and builds its `CLGeocoder` as a method-local so the non-`Sendable` value never escapes the actor's isolation region.

No `nonisolated(unsafe)` or `@unchecked Sendable` was introduced by the Swift 6 migration (the one pre-existing lock-backed `@unchecked Sendable`, `ProgressFanOut`, remains). `@preconcurrency import AVFoundation` is still used where AVFoundation's `Sendable` annotations are incomplete.

### Artwork Accent Color (June 2026)

The app can dynamically derive its accent (tint) color from the current audiobook's cover artwork, providing a personalized UI that changes with each book. The feature is exposed as the **"Artwork"** theme option in Settings (now the default).

**Extraction pipeline (`DominantColorExtractor`):**
- Downsamples the cover image to 100×100px for fast analysis.
- Converts pixels to HSL and discards near-grey, near-white, and near-black pixels.
- Builds a saturation²-weighted hue histogram with centre-distance biasing (cover subjects tend to be centred).
- Emits a `CoverSignature` — ranked identity hues (OKLCH hue + chroma + weight) with an `isNeutral` flag (vivid coverage < 2%, so a stray pixel can't theme a book). The extractor reports what the cover IS; it has no opinion about how the UI looks.

**Integration points:**
- `PlayerModel.artworkAccentColor` — computed property with version-cached extraction, invalidated automatically when `currentDisplayArtworkVersion` changes.
- `EchoCoreApp.resolvedAccentColor` — returns the artwork-derived color when the theme is `.artwork`, otherwise the static theme color.
- `ThemeSelectionView` — shows a live preview circle using the extracted color (or a dashed placeholder when no artwork is loaded), with a descriptive subtitle and fallback footer text.
- `ThemeColor.artwork` added to the enum (before `.system` so it's the first/default option).

### Cover Tonal Themes (June 2026)

Cover colors are no longer used directly in the UI. The pipeline is
construct-don't-rescue:

`UIImage → DominantColorExtractor.signature(from:) → CoverSignature → CoverThemeBuilder.build(from:scheme:) → CoverTheme`

**`CoverThemeBuilder`** converts the cover's primary hue to OKLCH and builds
role colors from per-scheme tone recipes — pale ramps in light mode
(background L≈0.93–0.96), immersive deep tones in dark mode (L≈0.21–0.26),
accent at L 0.47 (light) / 0.78 (dark) with gamut-clamped chroma. Contrast is
guaranteed by construction: `CoverThemeBuilderTests` sweeps all 360 hues in
both schemes asserting accent ≥3:1 vs backgrounds, ≥2.5:1 vs chip, and
onAccent ≥4.5:1 vs accent. A bounded lightness-stepping safety valve covers
extreme gamut corners. Roles: `accent`, `onAccent`, `secondaryAccent`
(first candidate ≥60° away with ≥15% of the primary's weight, else a +30°
sibling), `backgroundTop`/`backgroundBottom` (the `AdaptiveBackground` ramp),
and `chip` (pills/control circles). Neutral covers (greyscale or `isNeutral`)
get a warm-grey ramp with the brand accent.

**Why OKLCH:** HSL lightness is not perceptual — yellow at HSL L 0.55 is
near-white in real luminance while blue at the same L is dark. OKLab
lightness is uniform across hues, which is what makes fixed tone recipes
safe for every cover.

**Integration:** `PlayerModel.coverTheme` (cached per artwork version +
`uiColorScheme`); `PlayerModel.artworkAccentColor` remains the compatibility
facade (nil for neutral covers so `?? .accentColor` fallbacks engage);
`artworkAccentColorHex` sends the **dark-recipe** accent to the Watch, whose
surface is always dark.

**History:** this replaced the `AccentSafetyNet` two-gate rescue ladder. Its
ΔE76 chroma gate passed high-chroma/equal-luminance accents (bright gold on
beige at 1.06:1 WCAG) because chromatic distance alone cannot carry small
glyphs — see CODE_AUDIT.md §13.

### Watch Connectivity Fixes (June 2026)

WatchConnectivity reliability fixes across the phone (`WatchSyncManager`) and watch (`WatchViewModel`):
1. **Timer suspension cap**: When the watch wakes from sleep, `Timer.scheduledTimer` fires with the accumulated wall-clock delta (potentially minutes). The tick delta is now capped at 2.0 seconds — beyond that, the watch requests a fresh authoritative state from the phone instead of animating through every intermediate progress value.
2. **Stale `userInfo` handling**: `WCSessionDelegate` `didReceiveUserInfo` deliveries can be minutes stale when queued while the watch is unreachable. After applying received state, the watch immediately requests the phone's current state to converge to the authoritative position.
3. **Transport commands never ride the background queue**: Transport / navigation / seek commands are only meaningful *live*. The watch sends them via `sendMessage` only; on failure it reverts its optimistic UI and re-requests phone state rather than falling back to `transferUserInfo`. `transferUserInfo` is a persistent FIFO queue that drains (even across launches) the next time the phone is reachable, so queuing a `play`/`pause`/`seek` there replays stale intent — the cause of ignored first taps, phantom resume-after-pause, and position jumps on relaunch. As defense-in-depth the phone routes queued payloads through `WatchCommandRouter.route(queuedMessage:)`, which honors only deferred-safe commands (bookmarks, flashcard grades) and drops time-sensitive ones; live commands continue through `route(message:)`.
4. **Durable application context for significant state** (phone side, `WatchSyncManager.syncToWatch(reason:)`): `updateApplicationContext` is now the source of truth for *significant* changes (book/track switch, transport, speed, loop, sleep timer, settings) rather than a fallback used only when the watch is unreachable. Previously, when the watch was reachable the phone pushed via `sendMessage` only; that message is best-effort and foreground-only, so if it was dropped (reachability flap / app-state transition) nothing durable carried the change. A foregrounded watch — whose only pull triggers are activation, `onAppear`, and reachability change — then kept showing the old book until a button press forced a `sendCommand`/`requestState` round-trip. The context is now always refreshed on significant changes (delivered immediately to an active watch via `didReceiveApplicationContext`, and guaranteed on the next activation otherwise), with `sendMessage` retained only as a low-latency optimisation. High-frequency progress and sleep-timer ticks pass `reason: .progress` to stay live-only and avoid churning the coalesced context — the watch interpolates position locally between syncs. State no longer rides `transferUserInfo` (same FIFO replay hazard as #3).

### Bug Fixes (June 2026)

- **`AudioEngine` pause-on-disconnect**: `AudioEngine` now observes `AVAudioSession.routeChangeNotification` and pauses on `.oldDeviceUnavailable` (wired headphones / aux / Bluetooth removed). Unlike `AVPlayer`, `AVAudioEngine` does not auto-pause when the output device disappears — left unhandled it falls back to the built-in speaker and keeps rendering, so the book suddenly plays out loud when the cable is pulled. Routed through a new `AudioEngineDelegate.audioEngineOutputDeviceDisconnected` → `PlaybackController.pause()`; because it is a normal pause (not an interruption) it never arms `wasPlayingBeforeInterruption`, so playback stays paused until the user explicitly resumes.
- **`PlayerLoadingCoordinator` progress save**: Before `stop()` zeroes `audioEngine.currentTime` and `state.folderURL` changes to the new book's key, the previous book's last-known-good position is now persisted under the correct folder key.
- **`EPUBAutoImportScanner` security scope**: When a single file (not a folder) is opened directly, a temporary security-scoped resource access is started on the parent directory so sibling EPUB files can be enumerated.
- **`AlignmentService` word-position calculation**: Hidden blocks (`isHidden = true`) and image blocks (`.image` kind) now receive weight 0.0 in cumulative word-position computation. Previously they contributed their full word count, skewing proportional interpolation. Block positions also shifted from "center" to "start" positioning for more predictable interpolation behavior.
- **`SecurityScopeManager` URL reuse**: `startSelection(url:)` and `startFile(url:)` now correctly stop the previous access grant when the URL changes (previously the `guard !hasAccess else { return }` early-exit leaked the old grant). When the same URL is requested, the call is a no-op.
- **`TokenDTW` gap-cost initialization**: The DTW cost matrix boundary row and column are now initialized with cumulative gap costs (`Int32(i) * 2` for deletions, `Int32(j) * 2` for insertions) so the DP can correctly skip leading tokens that have no match in the other sequence. Previously all boundary cells were zero, causing incorrect alignment when audio or EPUB sequences had unmatched prefixes.

## Release Engineering — Promotion Ladder (June 2026)

Echo ships on a **release-train** model. The three long-lived branches are
promotion *stages*, not parallel forks, and code only ever flows one way:

```
feature/* ──▶ nightly ──▶ weekly ──▶ main (stable)
            (integrate)  (promote)  (promote + tag → App Store)
```

- **`nightly`** — the integration branch. Every feature PR merges here; it is
  allowed to be briefly rough. A nightly TestFlight build goes out daily.
- **`weekly`** — promoted from `nightly` once a week. The beta channel: more
  soak time, fewer surprises. A weekly TestFlight build goes out on Mondays.
- **`main`** — stable. Only ever fast-forwarded from a proven `weekly`. This is
  what cuts App Store releases; tagging a commit here (`vX.Y.Z`) is the release
  signal. Because promotion is one-way, anything in `main` is a strict subset of
  what has already been exercised in `weekly` and `nightly`.

**Hotfixes** are the one exception to the downhill flow: branch from `main`,
fix, merge to `main`, then merge `main` back *down* into `weekly` and `nightly`
so the fix is not lost at the next promotion.

### CI wiring

- **`.github/workflows/ci.yml`** — the existing gate runs on every push and PR
  to `main`, `weekly`, and `nightly`: it resolves a pinned iOS 26.4 simulator,
  runs `build-for-testing` for the iOS app + widget + watch + tests, executes
  `EchoTests` with `test-without-building`, then smoke-builds the macOS target.
  The required status check is named **`Build gate + tests`**; branch protection
  keys off that exact string, so it must not be renamed.
  Watch app tests are not a CI execution gate yet: CI compile-checks the embedded
  watch app through the `Echo` scheme, while `Echo Watch AppTests` stay manual
  until a pinned watchOS simulator destination is reliable on GitHub runners.
  Manual command:
  `xcodebuild test -project Echo.xcodeproj -scheme "Echo Watch App" -destination "$WATCH_DEST" -only-testing:"Echo Watch AppTests" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO`
  after setting `WATCH_DEST` to a destination from
  `xcodebuild -showdestinations -project Echo.xcodeproj -scheme "Echo Watch App"`.
- **`.github/workflows/release-trains.yml`** — scheduled builds that give the
  train branches teeth. `schedule`/`workflow_dispatch` triggers only execute the
  copy of a workflow on the **default branch**, so this file lives on `main` and
  *checks out* the train branch it was asked to build. Nightly cron builds
  `nightly`; weekly cron builds `weekly`; `workflow_dispatch` takes a `channel`
  input. Each run always compiles the branch (no secrets needed) and, when the
  App Store Connect + match secrets are present, runs the `fastlane beta` lane to
  upload to TestFlight. Missing secrets degrade to compile-only (no red-X
  nightlies). Required secrets: `APP_STORE_CONNECT_API_KEY_JSON`,
  `MATCH_PASSWORD`, `MATCH_GIT_SSH_KEY`.

### Branch protection (configured in repo Settings, not in code)

| Branch | Requires PR | Required check | Merges from |
|---|---|---|---|
| `main` | ✅ | `Build gate + tests` | promotion PR from `weekly` only |
| `weekly` | ✅ | `Build gate + tests` | promotion PR from `nightly` |
| `nightly` | optional | `Build gate + tests` | feature PRs land here |

### The rhythm

1. **Daily:** feature PRs merge into `nightly`; nightly TestFlight build auto-ships.
2. **Weekly:** open a `nightly → weekly` PR, let CI pass, merge; weekly build auto-ships.
3. **Release:** when a weekly build is solid, open a `weekly → main` PR, merge,
   then bump the version (see `.clinerules/workflows/release.md`) and tag
   `vX.Y.Z` — the tag is what the App Store `fastlane` lane keys off.

### Getting builds & testers into TestFlight

The trains map one-to-one onto TestFlight tester groups; the `fastlane beta` lane
routes each channel to its group (see `fastlane/Fastfile`):

| Channel | TestFlight group | Type | Beta App Review? | How testers join |
|---|---|---|---|---|
| `nightly` | **Nightly** | Internal | No — builds appear instantly | Added as App Store Connect users (Users and Access), then to the group. Max 100. |
| `weekly`  | **Weekly**  | External | Yes — first build of each version | Email invite **or a public link**. Max 10,000. |

**Internal vs external — the practical difference.** Internal testers must be
members of the App Store Connect team (any role), so they're for *you and a
handful of trusted people*. Builds reach them within minutes of upload, no
review. External testers are the general public; the **first build of a given
marketing version** must clear Beta App Review (a lighter, faster pass than full
App Store review — usually hours) before any external tester can install it.

**The shareable link.** "Send me a link" = a TestFlight **public link**
(`https://testflight.apple.com/join/XXXXXXXX`). It is a property of an *external*
group (Weekly), not internal, and it only goes live once that group has a build
that has passed Beta App Review. There is no fastlane/MCP action for it — enable
it once, by hand, in **App Store Connect ▸ Echo ▸ TestFlight ▸ Weekly ▸ Public
Link ▸ Enable**, then share the URL anywhere. Testers must install Apple's
**TestFlight** app first; the link opens the app to a one-tap *Install*.

**Per-build "What to Test" copy** lives in version control, not the ASC web UI:
`fastlane/testflight/what_to_test.txt` (the changelog) and
`beta_app_description.txt` (the group's Test Information). Edit those, not the
dashboard — the lane reads them on every upload.

**Nightly "What to Test" auto-draft.** On the `nightly` channel only, the
`fastlane beta` lane regenerates `what_to_test.txt` in the working tree (never
committed) from the commit delta since the last weekly promotion
(`merge-base(origin/weekly, HEAD)..HEAD`). It is a deterministic transform of
Conventional-Commit subjects — `feat`/`fix`/`perf` grouped into New/Fixed/Improved,
plus `Tester-note:` / `skip-changelog` trailer overrides — with no LLM, capped at
TestFlight's 4000 characters; on an empty delta or any error it leaves the
committed file untouched, so it can never break a build. The weekly/external
channel skips regeneration and ships the human-curated committed file (seed it
with `make whats-new` when you open the `nightly → weekly` promotion PR). The
generator lives in `Scripts/doc_automation/`, and its pure `changes.py` is the
shared change-extractor that later doc-automation phases reuse.

**Shipping the first build.** The release-train cron only uploads when the
signing secrets are present (`APP_STORE_CONNECT_API_KEY_JSON`, `MATCH_PASSWORD`,
`MATCH_GIT_SSH_KEY`); before they exist, runs degrade to compile-only. To ship
on demand without waiting for the 09:30 America/Halifax nightly / Monday weekly cron, run the
workflow manually: **Actions ▸ Release Trains ▸ Run workflow ▸ channel:**, or
`gh workflow run release-trains.yml -f channel=nightly`. The lane auto-assigns a
unique, monotonic build number from TestFlight's latest + 1, so `MARKETING_VERSION`
only moves for real releases. A purely local upload is `bundle exec fastlane beta
channel:weekly` (needs `fastlane/api_key.json` and `MATCH_PASSWORD`).

**Release checklist guardrail.** Before merging any future CarPlay scene
declaration or marketing copy, verify the App ID/provisioning profile includes
the matching CarPlay entitlement (`com.apple.developer.carplay-audio`), the
checked-in entitlements file enables it, `EchoCore/Info.plist` advertises only
matching scene roles, and TestFlight/App Store metadata names only shipped
surfaces.
