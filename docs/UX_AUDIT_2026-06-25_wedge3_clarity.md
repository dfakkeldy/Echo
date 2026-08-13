# Echo Wedge 3 UX Audit - 2026-06-25

Scope: Wedge 3 "UX audit first" before any core-surface rebuild. This names concrete regressions across player, reader/study, and library/import, including PR #77's BookPlayer-style redesign.

Method: read-only audit against the app's SwiftUI surfaces, PR #77 notes, ROADMAP Wedge 3, and the local UI-review checklist for HIG touch targets, Dynamic Type, accessibility, loading/empty/error states, and workflow clarity.

## Executive Findings

Echo's current UI is powerful but not obvious enough for the v1.0 "Clarity" gate. PR #77 moved several controls into a cleaner visual model, but it also introduced or exposed discoverability problems: first launch can look playable while doing nothing, two different overflow menus compete on Now Playing, reader study actions still depend on long press, and import/onboarding paths do not yet teach the core flow.

The next UI overhaul should not begin from a blank aesthetic preference. It should start from these concrete regressions:

1. Make the first-run and no-book state action-led.
2. Collapse or clearly separate global vs playback overflow actions.
3. Put frequent study controls where the study workflow happens.
4. Replace hidden long-press-only study actions with visible equivalents.
5. Fix stale Timeline-era language in docs/help/deep links.
6. Add empty/error recovery to import, search, Card Inbox, and review paths.

## Player / Now Playing

### P1 - Fresh/no-book Now Playing has inert playback affordances

Evidence:
- `EchoCore/Views/RootTabView.swift:63` always routes `.nowPlaying` to `NowPlayingTab`.
- `EchoCore/Views/Components/UnifiedBottomDock.swift:42` always renders `TransportControlsView` on Now Playing.
- `EchoCore/Views/TransportControlsView.swift:52` exposes the central play/pause action.
- `EchoCore/Services/PlaybackController.swift:167` no-ops when no tracks exist.

Impact: first launch or failed load can look like a playable audiobook screen, but tapping play does nothing. This conflicts with the Clarity wedge and the onboarding goal of teaching import -> align -> capture -> review quickly.

### P1 - Now Playing has two competing "More" menus with Settings

Evidence:
- `EchoCore/Views/Components/UnifiedTopHeader.swift:70` defines the app-level ellipsis menu.
- `EchoCore/Views/Components/UnifiedTopHeader.swift:96` includes Settings in that menu.
- `EchoCore/Views/PlayerMoreMenu.swift:30` defines a second player-scoped menu.
- `EchoCore/Views/PlayerMoreMenu.swift:90` also includes Settings.

Impact: PR #77 intended scoped playback controls, but duplicated overflow menus make the answer to "where do I go for this?" ambiguous.

### P1 - Chapter navigation became less discoverable and less touch-friendly

Evidence:
- `EchoCore/Services/SettingsManager.swift:50` fresh phone defaults include empty slots around play/pause.
- `EchoCore/Views/PhonePlayerSettingsView.swift:20` removes previous/next track from selectable phone palettes.
- `EchoCore/Views/NowPlayingTab.swift:198` moves chapter navigation into metadata chevrons.
- `EchoCore/Views/NowPlayingTab.swift:207` frames those chevrons at 44x32, below the 44pt HIG touch-target height.

Impact: chapter movement is a primary audiobook action, but it is now smaller and visually tied to title metadata rather than playback controls.

### P2 - Bookmark loop fails silently when unavailable

Evidence:
- `EchoCore/Views/PlaybackOptionsSheet.swift:34` shows a segmented Loop picker.
- `EchoCore/Views/PlaybackOptionsSheet.swift:121` demotes `.bookmark` to `.off` when there are no bookmarks.

Impact: the user can choose Bookmark and see the app immediately ignore that intent without an explanation, disabled state, or path to create the missing bookmark.

### PR #77 Notes

Moved forward:
- Chapter chevrons reuse the same chapter-aware skip methods as Lock Screen and CarPlay.
- Speed, loop, skip durations, Smart Rewind, and Volume Boost are consolidated into one sheet.
- Existing watch/CarPlay wire cases were preserved for compatibility.

Moved sideways/backward:
- Fresh installs lost obvious chapter prev/next and loop controls in the main row.
- Settings appears in both global and player overflow menus.
- No-content player states were not made clearer.
- Phone Player Designer is drag/drop first, which is weak for VoiceOver, Switch Control, and keyboard users.

## Reader / Study

### P1 - Reader empty and zero-result states can become dead ends

Evidence:
- `EchoCore/Views/ReaderEmptyState.swift:6` explains "No EPUB Available" but offers no import action.
- `EchoCore/ViewModels/ReaderFeedViewModel.swift:210` can create a search-results section even when no blocks match.
- `EchoCore/Views/ReaderFeedCollectionView.swift:439` applies an empty snapshot without a no-results overlay.
- `ROADMAP.md:396` explicitly calls for an educational empty state with the Read tab always visible.

Impact: users can reach Read & Study and be told what is missing, but not given the next action.

### P1 - Core study actions are still long-press first

Evidence:
- `EchoCore/Views/ReaderTab.swift:255` teaches "Long-press any card" for alignment, color, bookmark, and copy.
- `EchoCore/Views/ReaderTab+Alignment.swift:162` contains key study actions in the context menu.
- `EchoCore/Views/ReaderFeedCollectionView.swift:695` leaves bookmark/card/note/memo taps inert.
- `EchoCore/Views/ReaderFeedCollectionView.swift:711` returns no context menu for those item types.

Impact: the study moat depends on capture and review, but the main reader still hides many actions behind a gesture that is low-discoverability and weaker for accessibility.

### P1 - Reader speed and loop controls are too modal for study

Evidence:
- `EchoCore/Views/BottomToolbarView.swift:104` makes the speed chip open Playback Options.
- `EchoCore/Views/PlaybackOptionsSheet.swift:24` puts the actual speed picker inside the sheet.
- `EchoCore/Views/Components/PlayerControlBar.swift:47` only exposes speed inline if a configurable mini-player slot is set to speed.
- `ROADMAP.md:397` lists reader toolbar speed controls as a study-workflow gap.

Impact: slowing down dense passages or speeding through familiar material requires a sheet unless the user has preconfigured a speed slot.

### P1 - "Read & Study" promises one study surface, but study entry points are split

Evidence:
- `Shared/TabSelection.swift:7` says Timeline is gone and Read is the study surface.
- `EchoCore/Views/Stats/StatsView.swift:132` places study library links under Stats.
- `EchoCore/Views/Stats/StatsView.swift:352` exposes Card Inbox and Decks there.
- `EchoCore/Views/DashboardShelf.swift:33` makes review a dashboard shelf module rather than an obvious Read & Study action.

Impact: cards, decks, review, reader captures, and stats are scattered across sheets and dashboard modules instead of feeling like one study workflow.

### P2 - Capture/review failures can masquerade as empty state

Evidence:
- `EchoCore/Views/CardInboxView.swift:90` returns early when the database is unavailable.
- `EchoCore/Views/CardInboxView.swift:94` uses `try?` when fetching inbox records.
- `EchoCore/Views/CardInboxView.swift:132` logs conversion errors but does not surface recovery.
- `EchoCore/Views/RootTabView.swift:323` suppresses study-session load failures by not presenting review.

Impact: a data or load failure can look like "nothing to do", which is dangerous for a trust-building study app.

### P2 - Reader header utility buttons are below HIG target size

Evidence:
- `EchoCore/Views/ReaderTab.swift:1000`
- `EchoCore/Views/ReaderTab.swift:1011`
- `EchoCore/Views/ReaderTab.swift:1021`

Impact: several reader utility buttons are framed at 36x36 instead of the 44pt iOS target. They are also dense, icon-only, and placed in the surface where low-vision and dyslexic users are most likely to spend time.

## Library / Import / Onboarding

### P1 - First-run onboarding is not wired to launch and does not teach the wedge flow

Evidence:
- `EchoCore/EchoCoreApp.swift:75` presents `RootTabView` directly.
- `EchoCore/Views/OnboardingView.swift:4` exists but is not launch-gated.
- `ROADMAP.md:57` requires onboarding that teaches import -> align -> capture -> review in under 60 seconds.

Impact: new users land in a polished shell, not in a guided first action.

### P1 - Import actions are hidden behind the top menu and conditionally absent

Evidence:
- `EchoCore/Views/ReaderEmptyState.swift:6` has no import button.
- `EchoCore/Views/RootTabView.swift:114` only injects Add EPUB when a book is loaded and narration is not running.
- `EchoCore/Views/Components/UnifiedTopHeader.swift:78` places Add/Replace EPUB inside the top ellipsis menu.

Impact: the app tells users to import a companion EPUB but hides the import action behind a conditional overflow item.

### P1 - PDF import promise is stale from the main import path

Evidence:
- `EchoCore/Views/RootTabView.swift:243` root document importer allows only `companionEPUBTypes`.
- `EchoCore/Views/RootTabView.swift:319` defines `companionEPUBTypes` as EPUB only.
- `EchoCore/Views/HelpContent.swift:197` says the import button accepts EPUB and PDF.
- `docs/guides/user-manual.md:366` repeats that promise.

Impact: product copy promises a file type the visible import path does not accept, increasing confusion and support load.

### P2 - Audiobookshelf browse lacks empty and per-library loading states

Evidence:
- `EchoCore/Views/ABSBrowseView.swift:18` handles only global loading and error state.
- `EchoCore/Views/ABSBrowseView.swift:26` renders a List with the current `items` or `searchResults`.
- `EchoCore/Views/ABSBrowseView.swift:96` fetches library items without a per-library loading indicator.

Impact: empty libraries, zero search results, and slow library switches look like blank lists.

### P2 - Navigation and docs still describe removed Timeline surfaces

Evidence:
- `Shared/TabSelection.swift:4` has only `.nowPlaying` and `.read`.
- `ARCHITECTURE.md:749` still documents `TimelineTab`.
- `EchoCore/Views/HelpContent.swift:111` says cards can be created from scratch in the Timeline tab.
- `docs/guides/user-manual.md:135` still describes Timeline as a tab.

Impact: after PR #77, the UI and support material disagree about where study work lives.

### P2 - Some settings routes land on placeholders

Evidence:
- `EchoCore/Models/NavigationDestinations.swift:27` includes `.settingsAudio`.
- `EchoCore/Models/NavigationDestinations.swift:65` maps it to `SettingsPlaceholder(title: "Audio Settings")`.
- `EchoCore/ViewModels/PlayerModel.swift:1160` can route audio-settings deep links there.

Impact: Settings was intentionally thinned in PR #77, but old routes can still send users to placeholders instead of the real playback/settings surfaces.

## Recommended Next Order

1. First-run/no-book state: visible "Open Book", "Connect Audiobookshelf", and "Try Sample" or equivalent owner-approved path.
2. Overflow cleanup: one global menu plus one clearly player-specific control, with Settings in only one obvious place.
3. Reader study actions: visible inline actions for align, bookmark/note/memo/card, plus long press as secondary.
4. Reader toolbar controls: inline speed and loop controls that do not require entering a sheet for common study adjustments.
5. Empty/error recovery: Reader empty, search no-results, Card Inbox load failure, ABS empty/search/load states.
6. Documentation/string cleanup: remove stale Timeline tab language and reconcile PDF import promises.

## Done Definition For The Later UI Overhaul

- No first-run or no-book screen presents inert primary controls.
- The import -> align -> capture -> review path is visible without reading documentation.
- Common playback/study controls are reachable from the surface where the user needs them.
- Every empty/error state provides a next action or recovery explanation.
- Interactive controls meet 44pt iOS touch targets unless a platform-native control supplies the target.
- VoiceOver users can configure phone controls without drag/drop.
- README, Help, manual, architecture, and in-app labels agree on the current navigation model.
