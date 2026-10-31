# Echo v1.1 — Streamlined, faster, harder to break

This plan sets the scope of Echo v1.1: a simpler UI, measured performance and hardened user workflows on iPhone, Watch, CarPlay and Mac. It merges an eight-area audit of nightly `b9c9040d` into a set of shippable items. Each item has a gate tag, an effort size, file:line evidence and an acceptance check. The audit's fact-check pass verified the line numbers on that commit. Where that pass corrected a citation, the corrected one is used here. The reader is Dan, who uses Echo hands-free on a mail route, and the agents who will implement the items. An item marked "critic-added" came from the completeness review and has not been value-checked.

## Decision 1: what v1.1 means

The three v1.1 themes overlap two 1.0 gates that are still open. ROADMAP Wedge 2 has an unchecked "Performance budget" line (ROADMAP.md:59) and a "No-lost-progress guarantee" still marked [~] (ROADMAP.md:57). Wedge 3 has the UI overhaul and the UX-flow audit (ROADMAP.md:67-69).

- **(a)** v1.1 is the release after 1.0. It takes over specific items that are moved out of the 1.0 gate.
- **(b)** "v1.1" is just a name for finishing those 1.0 gates.

**Recommendation: (a), run as two tracks.** The *1.0 closeout* track holds every item tagged `1.0-gate`. These are mostly S/M hardening fixes that the gates already require. The *v1.1* track holds everything tagged `1.1`. Option (b) does not work, for two reasons:

1. The dependency chain puts 1.0-gate foundations ahead of almost every 1.1 consumer. Those foundations are the Signposts enum, FeedbackPresenter, the resume checkpoint and the no-lost-progress matrix. Renaming the gates "1.1" would only relabel that prerequisite work, and the real 1.1 items would be left with no release.
2. Under (b) the `1.1` tag stops meaning anything, because every current 1.1 item would have to become `later`.

How a flip works: if a `1.0-gate` item is flipped to `1.1`, it ships after the App Store 1.0. If a `1.1` item is flipped to `1.0-gate`, it delays 1.0.

## Design principles

1. **Fewer decisions mid-task.** Save first and edit later. Choose defaults once at home, not on the route.
2. **One place per action.** Each action has one primary control and at most one secondary path, and the same control does the same thing in every layout.
3. **Progressive disclosure, not deletion.** Rarely used options go behind "Advanced" or a submenu. No study capability is removed.
4. **Every state has a next action.** No endless spinner, false "Done", dead button or sheet stacked on a sheet. Each failure state names its single next step.
5. **Nothing is lost silently.** A haptic, chime or "Saved" is played only after the data is durable. Every failure gives a signal you can hear.
6. **Reachable without looking.** Core actions sit in the bottom thumb arc and can also be triggered by headphone, Watch, CarPlay or voice.
7. **Measured, not assumed.** Every performance change names a signpost interval, its budget and a recorded baseline.

## Where Echo stands

- **Player.** Default Now Playing shows about 14 controls and 4 menus, and 2 of the 5 transport slots ship empty (SettingsManager.swift:52-54). The sleep timer has 4 menu implementations. Speed has 5 label formatters and 2 controls that behave differently. Mark passage has 6 call sites, and only 1 shows its result. There are 5 separate WatchAction dispatch switches. Dead code: BottomToolbarView.swift:263-306 and NowPlayingTab.swift:446-485 and :518-531.
- **Reader.** The paragraph menu has about 13 items, and 7 of them are alignment actions. About 16 controls sit above the first paragraph, and 2 filter chips are permanently disabled. Each manual alignment edit does a synchronous whole-book recalculation plus a reload on main. There are 0 reader signposts.
- **Library.** One picker is reached from 7 triggers under 5 labels. ABS is 5+ taps deep, across 2 stacked sheets. The shelf runs a full regroup pass on every appearance.
- **Settings.** The root has about 22 rows. The 13-value skip array exists in 3 copies. 6 SettingsManager properties are dead. 5 of 8 NavigationDestination cases are never produced.
- **Study.** Review is reached through More, then Stats, then a scroll, and it opens as a sheet on a sheet. The Insights "Retention" and "Avg Ease" tiles read `ease_factor`, which FSRS never writes.
- **Onboarding.** First launch teaches 1 of the 4 steps (import). Help has 14 flat sections while the manual has 27. No test covers Help.
- **Mac.** 12 untyped NotificationCenter command routes, 3 of which can have no receiver. 0 FocusedValue uses. Mark Passage is implemented twice.
- **Watch.** Review skips every other card. Bookmarks are stamped with whole-book time. Each command reply runs an uncapped `allDueCards()`.
- **Performance.** There is exactly 1 OSSignposter (AutoAlignmentWorker.swift:34). A 2 Hz tick drives 4 screen bodies (inferred from code, not measured). MetricKit metric payloads are discarded.
- **CI.** One serial job of about 53 minutes with no timeout. The release train never checks CI on the SHA it ships. The UI tests are template stubs.

**June 2026 UX-audit status (docs/UX_AUDIT_2026-06-25_wedge3_clarity.md)**

| Finding | Status |
|---|---|
| P0 First launch looks playable while doing nothing | Fixed (ROADMAP.md:69), but a container-folder first pick brings back a trackless Listen surface, so partly reopened (C-6) |
| P1 Chapter navigation discoverability | 44pt size fixed. Empty default slots and top placement still open (A-3) |
| P1 Two competing More menus | Fixed on iOS. Mac analogue open (A-12) |
| P1 Core study actions are long-press first | Open: menu order, inert inline rows, banner copy (A-5, A-6) |
| P1 Study entry points split | Open (A-1) |
| P1 Reader empty state has no import / import hidden | Fixed on iOS. Mac still open (C-13) |
| P1 PDF import promise | Fixed |
| P1 Onboarding | Launch gate removed. The teaching half is open, and ROADMAP.md:68 is false (A-14) |
| P2 Settings routes land on placeholders | Audio route fixed. Chapter route open (C-10) |
| P2 Capture/review failures masquerade as empty | Inbox load fixed. Stats loaders, capture feedback and Mac capture/export open |
| P2 ABS loading/empty states | Fixed |
| P2 Timeline copy in docs | Fixed |
| P2 Bookmark loop fails silently | Fixed (including on Mac) |
| Rec. #1 Try Sample | Open (B-later list, A-15) |
| Rec. #5 Empty/error recovery | Library still open (C-11) |

The June audit had no findings for the Watch.

## A. Simplified UI

**A-1 · study-today-entry · One study hub with due counts · 1.0-gate · M**
Review, Card Inbox and Decks are reachable only from the Stats sheet, after the charts (StatsView.swift:146-150, :406-426). If loading SRS data fails, all three entry points disappear (:146-149). `echoaudio://study` opens Read (DeepLinkHandler.swift:75-76), and a default tap on the review notification is ignored (StudyCheckpointNotificationService.swift:63-78).
Proposal: replace "Stats" in More with "Study", which opens a root-presented hub listing Review N due, Card Inbox (N), Decks, this book's Plan, then Insights. Add the same due-count row at the top of Read & Study. `.study`, the notification's default tap and the Watch review link all land on the hub. Replace the `try?` calls in StudySessionViewModel (:72-73, :119-120, :130) with surfaced errors. Do not mount DashboardShelf.
Acceptance: Review is at most 2 taps from Now Playing with no scrolling. VoiceOver reads "Review, 12 due" as one element. A source test confirms StudyLibraryLinksView is no longer inside StatsView.
Merges: review-one-tap-and-notification. Deleting DashboardShelf and FlashcardReviewSession goes to a separate cleanup PR; DailyReviewViewModel stays because the Mac uses it.

**A-2 · reset-alignment-guard + block-menu-study-first · Study-first paragraph menu, guarded reset · 1.0-gate · M**
Every paragraph's menu, and its VoiceOver actions, include "Reset Alignment" (ReaderTab+Alignment.swift:449-456, :275-279). It runs with no confirmation and deletes hand-placed anchors (AlignmentService.swift:155-162), even though the code marks those as unrecoverable (AlignmentAnchorRecord.swift:58-75). The Mac has the same problem (MacReaderFeedView.swift:582-583). Auto-Align comes first in the menu, and Save Bookmark and Copy come last (:349-475). The VoiceOver list is a second, hand-maintained copy (:184-313).
Proposal: build both the UIMenu and the VoiceOver actions from one `ReaderBlockAction` array. Order it word actions, Save Bookmark, Copy, Color, Theme, image actions, then a single "Alignment…" submenu. Move book-level actions (Auto-Align, Reset) to one "Alignment tools" entry. Reset opens a dialog that shows how many anchors are hand-placed and offers "Reset automatic anchors" (the default) or "Reset everything". Rewrite the banner (ReaderTab.swift:321-326) and user-manual.md:160, :176.
Acceptance: at most 7 top-level items. Save Bookmark is among the first 3 VoiceOver actions. A same-source test covers both lists. A test seeds 3 human and 5 synthesized anchors, runs the default reset, and finds 3 left. Keep the "Reset Alignment" string key, or update LocalizationFormattingTests.swift:67. Coordinate AlignmentService changes with #421.

**A-3 · now-playing-dedupe-thumb-zone · No empty default slots, honest menu items · 1.0-gate · S (bugs) + owner decision (defaults)**
More > "Bookmarks" actually switches to Read (RootTabView.swift:351, PlayerMoreMenu.swift:61-62). The `.speed` slot opens a sheet while the dock chip opens a menu (TransportControlsView.swift:215-232 vs BottomToolbarView.swift:162-190). The default row contains `.empty` slots (SettingsManager.swift:52-54). Those slots render as Color.clear (TransportControlsView.swift:280-282) and were a deliberate default (commit d8c77fee).
Proposal: (a) now, make "Bookmarks" open bookmarks, and make the speed slot open the same preset menu as the chip. (b) After Dan decides (Open Question 1), change the default row to `[.previousSection, .skipBackward, .playPause, .skipForward, .nextSection]`. Those two cases are already in the palette and fall back to chapter navigation (PlaybackController.swift:649-680), so PhonePlayerPaletteTests does not change. Change only the defaults and Reset, using `Defaults.phonePage` instead of the literal at PhonePlayerSettingsView.swift:180 (update PhonePlayerPaletteTests.swift:61 and EchoCoreTests.swift:369). (c) Limiting the folder chip to Library is a #407 item that rides with A-13.
Acceptance: More > Bookmarks lands on bookmarks. With (b), the default layout has 0 empty slots.
Merges: phone-designer-defaults-and-cruft.

**A-4 · filter-row-collapse · Wire or hide the dead filter chips · 1.0-gate (S) / 1.1 (M)**
The Bookmarks and Cards chips are permanently disabled behind a stale comment (ReaderTab.swift:785-806), and the filter passes those item types straight through (ReaderFeedDisplayBuilder+Filter.swift:14-15, :53-56).
Proposal: 1.0: implement the bookmarks and cards filters (keep those items plus their headers), or hide the chips. 1.1: one "Show: Everything ▾" menu that includes a "My captures" option and always labels the active filter. Keep the "Show Everything" recovery (ReaderTab.swift:550-575).
Acceptance: 0 disabled controls in the reader chrome. A filter test confirms `.captures` returns only capture items.

**A-5 · inline-capture-rows-tappable · Captures act on tap · 1.0-gate · M**
Taps on bookmark, card, note and memo rows are no-ops (ReaderFeedCollectionView.swift:1429-1431), and these rows have no context menu (:1465-1468). Memo playback uses `try?` and does not pause the book (ReaderTab.swift:284-294).
Proposal: tapping a bookmark seeks and plays. A card opens its review. A note opens the editor. Add Edit, Delete (with confirmation) and Copy, plus matching VoiceOver actions. Memo playback pauses the book and resumes it afterwards.
Acceptance: every ReaderCardItem case has a non-nil tap outcome. A memo test confirms the book pauses and then resumes. ReaderFollowState is not disturbed.

**A-6 · experimental-player-parity-or-park · Fix the experimental-layout trap, keep it opt-in · 1.0-gate · S**
With the experimental layout on, the dock is hidden (RootTabView.swift:343), so Library is unreachable. Its PlayerMoreMenu also omits Video Export (ExperimentalControlLayer.swift:156-169 vs RootTabView.swift:362-364).
Proposal: add a fixed way back to Library and pass the full closure set to the menu. Add a source-scan parity test for both PlayerMoreMenu constructions. Graduating the layout is deferred (Open Question 5).
Acceptance: Library is at most 2 taps away, and the parity test passes.

**A-7 · focus-tools-contextual · Soundscape and Chime inside Playback Options · 1.0-gate · S**
The only path to these tools is Playback Options > More Controls > Focus Tools, which opens a second sheet (PlaybackOptionsSheet.swift:85-95, PhonePlayerSettingsView.swift:110-122, :190-195). NavigationDestinations.swift:27-28 builds `ChimeSettingsView(engine: nil)`.
Proposal: add a Focus section to Playback Options that pushes to the existing screens with the live engine. Remove the section from the button designer and delete the nil-engine route.
Acceptance: Soundscape is at most 2 taps from Now Playing, with no sheet stacked on a sheet.

**A-8 · insights-fsrs-honest-metrics · FSRS-true tiles and Stats error state · 1.0-gate · S**
"Retention" and "Avg Ease" are computed from `ease_factor` (StatsRepository.swift:280-302), which FSRS never changes. Only SM2Scheduler.swift:29 writes it. If loading fails, the screen spins forever (StatsView.swift:93-95, :218-302).
Proposal: replace them with a "Recall (30 days)" tile (share of reviews graded Good or better) and a "Mature cards" tile. Add a ContentUnavailableView with Try Again. Update the manual and Help.
Acceptance: an FSRS-only test fixture matches the expected Good+ share. A throwing repository shows the error state.

**A-9 · reader-empty-state-gaps · Explain disabled and unfamiliar actions · 1.0-gate · S**
"Add Document" is disabled during narration with no reason given (ReaderEmptyState.swift:29-33, RootTabView.swift:270). "Transcribe Audiobook" has no explanation (RootTabView.swift:274-283). The copy leaves out PDF, Markdown and text (ReaderEmptyState.swift:51).
Proposal: add a caption ("Available when narration finishes"), a one-line description of Transcribe, and the full list of formats. Update Wedge3ClarityOnRampTests.swift:31-38 in the same PR.
Acceptance: every disabled action has a visible reason next to it.

**A-10 · help-copy-contract-and-drift-fix + markdown rendering · Accurate, rendered Help · 1.0-gate · S**
Help says Settings is a "gear icon in the top-right" (HelpContent.swift:240), describes a "speaker icon" control that does not exist (:70), and says speed "cycles" (:57). Loop, sleep and bookmark are configurable slots, so those lines are roughly right. HelpView renders `Text(String)` as plain text, so `**…**` appears literally (HelpView.swift:16, HelpContent.swift:28). No test covers Help.
Proposal: fix the stale lines. Render bodies with `AttributedString(markdown:)`. Fix the format list (HelpContent.swift:18). Add HelpContentContractTests that check labels and system images only.
Acceptance: 0 contradicted location claims, and no literal `**` in any section. 1.1: a searchable section list with `echoaudio://help/<id>` links, plus filling coverage gaps by hand with a test mapping each manual H2 to Help or to a web-only allowlist (help-coverage-from-manual).

**A-11 · watch-no-book-state · Watch empty state · 1.0-gate · S**
With no book loaded, the Watch shows "No track selected" above controls that look live (WatchViewModel.swift:86, :400; PlayerPage.swift:598-606).
Proposal: add a `hasLoadedBook` flag derived from synced state, and show "Open a book in Echo on your iPhone" with Review and Inbox still available. Test separately that remote resume still works from a stale cache.
Acceptance: 0 enabled transport controls when no book has synced.

**A-12 · mac-open-paths (part 1) · Actionable Mac reader empty state · 1.0-gate · S**
The Mac reader shows "No EPUB Content" with no action (MacReaderFeedView.swift:120-125). Transcribe is available only as an icon (MacTriPaneView.swift:528-564).
Proposal: add labelled buttons for Transcribe this audiobook, Attach EPUB/PDF and Narrate a document. Make the no-book player bar a button. Drag-and-drop and Finder document types are 1.1.
Acceptance: a source test confirms the button is not icon-only.

**A-13 · one-verb-per-add-intent · Two verbs · 1.1 · S (rides with C-6)**
The same picker carries five labels (LibraryView.swift:80, :276; UnifiedTopHeader.swift:40; ReaderEmptyState.swift:35; RootTabView.swift:597, :608). NowPlayingTab declares closures it never uses (:6, :9). CHANGELOG.md:150 says the folder chip appears only on Library, which is not true.
Proposal: use "Add to Library" and "Open Book" everywhere. Remove the dead parameters. Either gate the chip to Library or correct the CHANGELOG. Update the pinned "Open a Folder" tests.

**A-14 · roadmap-onboarding-line-correction-and-live-checklist · Data-driven Getting Started card · 1.0-gate · S (doc) + M (card)**
ROADMAP.md:68 says the walkthrough "is wired", but tests assert it is gone (Wedge3ClarityOnRampTests.swift:19-25).
Proposal: correct the ROADMAP line now. Add one dismissible card with four rows, each ticked from real data: Book loaded, Text matched, First capture, First review. Each row has one action button, and "Review now" opens the hub directly. Row queries run off the main actor.
Acceptance: unit tests on how each row is derived. "Review now" bypasses More.

**A-15 · 1.1 simplification set** (ride with slice 6 unless noted)
- *one-tap-capture* (Open Question 3): a bookmark saves on the first tap, with Edit and Undo in the capsule for 4 s, and the two draft sheets merge into one (RootTabView.swift:511-516). Acceptance: 1 tap saves, Undo removes it.
- *single-action-dispatcher* (narrowed): delete the dead members listed above. Use one `SpeedFormat.label` and one shared `SleepTimerMenuContent`. Point SettingsNowPlayingView at `PlaybackOptionsSheet.seekDurationOptions`. Fix the experimental loop-icon drift. Acceptance: a grep for `setSleepTimer(.minutes(15))` under Views returns 1 hit.
- *customization-progressive-disclosure*: lead with one "Bottom row" section using grid pickers, and put the rest under Advanced. Fix the false footers at PhonePlayerSettingsView.swift:82 and :50-52 now.
- *player-style-one-picker*: move the Experimental toggle next to Player Layout, and hide the slot designer while it is on (SettingsNowPlayingView.swift:68-82).
- *playback-knobs-single-source*: one `seekDurationOptions` in `SettingsManager.Defaults` and one shared `SkipDurationRows`. Keep both surfaces.
- *watch-settings-progressive-disclosure* (merged): Controls first. Show only the sensitivity slider for the active crown mode. Move Inbox to the bottom under "Integrations". Put Face and Progress under Appearance. Drop the performance half.
- *study-plan-one-tap-start*: "Start studying" with pacing behind a disclosure, labelled "1 new chapter/day, 2 new cards/day (app limit 20)" (StudyPlanViewModel.swift:15-16). Relabel "New AI Card Offer Cap" (SettingsView.swift:296).
- *study-notes-split-actions*: plain-language stepper labels and a single feedback entry. Book-overrides placement is an owner decision (Open Question 4).
- *pro-single-purchase-surface*: title the screen "Echo Pro" and keep one purchase path, PaywallView's `store.purchase` (ProTranscriptsSettingsView.swift:90 vs PaywallView.swift:134).
- *narration-section*: an iOS Default Voice row, and route all `narrationQAClassifier` reads through SettingsManager (NarrationQAReviewModel.swift:156, :172; NarrationService.swift:138). Land after the Phonon trial.
- *chapter-menu-dedupe*: one "Turn off audio for this chapter" (ReaderTab.swift:243-265).
- *dead-settings-and-routes*: delete 6 dead properties and 5 NavigationDestination cases that nothing produces.
- *inbox-one-pass-triage*: undoable dismiss and inline row errors (CardInboxView.swift:152-177), a Play button, batch "Draft cards" (depends on C-5), and a single-query load.
- *mac-playback-controls-single-source*, *mac-menu-bar-transport-completeness* (verify bare-Space conflicts in a 1.0 test), *mac-study-window-first-slice* (Decks and Insights views compiled for Mac is **1.0-gate, M** per ROADMAP.md:94; the Study window itself is 1.1), *watch-review-glance-and-order*, *watch-player-code-consolidation* (one label source, delete WatchBookmarksView), *ready-to-start* (now 1.0, in C-6), *G3 "Where things moved" card* (critic-added, 1.1).

## B. Performance budgets

All intervals come from one `Signposts` enum in Shared. It compiles for iOS, macOS and echo-cli with no UIKit, takes its subsystem from Logger+Subsystem.swift, and has one category per area. A new `docs/PERFORMANCE_BUDGET.md` ships with its EchoTests doc assertion in the same PR. Budget numbers are proposals until a device baseline on an A14 iPhone 12 Pro is recorded. CI gates assert statement counts, EXPLAIN plans, observation fan-out and "ran off main" probes. They never assert wall time.

**B-1 · Foundations: signposts + MetricKit + fan-out tests · 1.0-gate · M**
Merges launch-signposts-budget, perf-budget-harness, signposts-and-metrickit-metrics, ui-perf-budget-harness, metrickit-launch-metrics and the signpost halves of other items. Today: 1 signposter. `didReceive([MXMetricPayload])` is empty (MetricKitDiagnosticsController.swift:84-87). `start()` re-archives past payloads on every launch, keyed by receivedAt, which duplicates them inside the 30-file retention window (:21-28, MetricKitDiagnosticsArchive.swift:17-27). The launch test is the template (EchoCoreUITests.swift:37-42).
Proposal: add intervals Launch.{AppInit, DatabaseOpen, RestoreSelection}, Player.Tick, Reader.{open, reload, edit.align, tapSeek}, Shelf.{snapshot, regroup}, PDF.open, Narration.{prepare, renderSegment, firstAudio} and Capture.markPassage. Archive metric payloads, deduplicated by time range, and move `start()` out of App.init. Add a DEBUG synthetic fixture (a 150k-word / 3,000-block book and a 1,000-book library) and RenderFanoutTests.
Acceptance: all intervals appear in a single Instruments os_signpost + Hangs trace on device. ROADMAP.md:59 is rewritten with the ratified numbers.

**B-2 · tick-isolation-screen-bodies · Keep the 2 Hz clock out of screen bodies · 1.0-gate · M**
NowPlayingTab.swift:100, ReaderTab.swift:489 and PDFDocumentView.swift:271 attach `.onChange(of: currentPlaybackTime)` at the screen root. The clock is a 0.5 s Timer (AudioEngine.swift:687). TransportControlsView reads progress in its parent (:47-51). The presenter writes four Observable fields on every tick (PlaybackProgressPresenter.swift:125-131, :149-155). On Mac, `playerBar` reads `player.currentTime` directly (MacTriPaneView.swift:436, :445).
Proposal: move the clock into leaf observers, or push it through a closure into the view models. Add a `ProgressRing` leaf. Make every presenter write conditional on a change. Make the Mac playerBar its own View.
Budget: 0 root-body evaluations per tick for NowPlayingTab, ReaderTab, PDFDocumentView and MacTriPaneView over 60 s (SwiftUI Instruments View Body lane). Over 20 ticks, `durationText` fires 0 times. The ReaderActiveBlockResolver tests stay green.
Merges: now-playing-tick-invalidation-budget, transport-progress-leaf, progress-presenter-equality-guards.

**B-3 · manual-align-off-main · Alignment edits off the main actor · 1.0-gate · M**
Align, hide, erase and reset each call the synchronous service and then a synchronous `reload()` (ReaderTab+Alignment.swift:21-23, :76-77, :89-90, :102-103, :116-117, :174-175). Delete, upsert and recalc are not atomic (AlignmentService.swift:101-122), and Snapshot.read runs twice per edit (:450, :470). The Mac `Task {}` inherits the main actor (MacReaderFeedView.swift:431-450). `recalculateTimelineAsync` (:61-71) and `reloadOffMain` (ReaderFeedViewModel.swift:305) already exist.
Proposal: add async twins that do a single write transaction, give optimistic haptic feedback, and coalesce rapid edits through the reload revision. Serve tap-to-seek and bookmark times from memory: tapBlock currently reads the DB through `audioStartTime` (ReaderFeedViewModel.swift:1071-1080), and `wordTiming()` should use `wordIndex`.
Budget: reader.edit.align ≤100 ms from tap to pulse with no hang over 250 ms on the 5k-block fixture. 0 DB reads on tapBlock and tapWord. 5 rapid aligns cause at most 2 rebuilds. Coordinate with #421.
Merges: interactive-edits-off-main.

**B-4 · pdf-open-off-main · PDF loads once, off main · 1.0-gate · S then M**
On every `.timelineItemsIngested`, the handler bumps `pdfLoadToken` (which re-parses the PDFDocument on main) and also calls `readAlong?.load` (PDFDocumentView.swift:354-364, :246-258, :378). The controller is @MainActor and runs synchronous fetchAlls (PDFReadAlongController.swift:15-17, :58-140).
Proposal: S first: one load per notification, coalesced through ReaderIngestionReloadTracker. M: a `@concurrent` snapshot builder that reuses ReaderPlaybackSnapshot, with the four columns projected (lean-word-cache step 1). Add a load-failed ContentUnavailableView with Retry (:233-238).
Budget: one controller load per notification (test). On a 300-page fixture, main-thread DB time is 0 ms and pdf.open is ≤500 ms.

**B-5 · shelf-regroup-once · Library appears without churn · 1.0-gate · S**
Library reloads in both `.onAppear` and `.task(id:)` (LibraryView.swift:119-125). The second fetch is cheap because of cancel and single-flight (LibraryViewModel.swift:58-60, :98-106). The real cost is that every appearance and axis switch runs four `fetchAll` passes in regroupForShelfLoad (LibraryService.swift:694-726), and the prune has no attempted-ID memo (:886-911).
Proposal: drop the onAppear reload, gate regroup on a change fingerprint set by the rescan and import writers, memoize the prune, and use EXISTS probes in place of DISTINCT.
Budget: on a second visit with no writes, 0 regroup scans and 1 snapshot. shelf.snapshot ≤150 ms off-main for 1,000 books.
Merges: library-shelf-load-budget.

**B-6 · Launch path · 1.1 unless noted**
- *no-audio-session-activation-on-restore* (S): a cold restore with autoplay off still calls `setActive(true)` with non-mixable `.spokenAudio` (PlayerLoadingCoordinator.swift:893, AudioEngine.swift:139-157), which stops Dan's podcast. Defer activation to the first play, calling the existing private `configureEngineGraph()` (:160) directly. The acceptance must include a device test that AirPods play and Watch play still start the Echo book after a cold launch. Fallback: use `.mixWithOthers` until the first play.
- *restore-selection-off-main* (L, conditional): do it only if Launch.RestoreSelection exceeds 150 ms on main. The first slice shows the title and cover from the DB row before the audio item is ready.
- *macos-async-db-open*: the silent in-memory fallback in Release (Echo_macOSApp.swift:502-508) is **1.0-gate, S** (see C-9). Moving the open off App.init (:46) is 1.1.

**B-7 · Reading and narration rate · 1.1**
- *karaoke-word-clock* (M): currentTime is written only by the 2 Hz Timer (AudioEngine.swift:683-694), so the word highlight cannot keep up with roughly 3 words/s. The "12.5 Hz" comment (ReaderFeedViewModel.swift:51-53) is stale. Feed a non-mutating precise clock at 10-15 Hz, and only when the reader is visible, playing, has word_timing and Reduce Motion is off. Respect the monotonic guard (:715-724), and use no CADisplayLink in the first version. Budget: ≥8 Hz updates, ≤1 ms per tick, ≤100 ms lag measured against word starts in a trace. Validate after #421. Merges: karaoke-display-link.
- *boundary-precise-scheduling* (M): the chapter-end window is a fixed 0.5 s (PlaybackController.swift:1001) and the bookmark look-ahead is `max(0.5, 0.3×speed)` (:1060-1061). At 3x, about 1 s of the next chapter plays through sleep timers and checkpoints, and at 1x the boundary fires up to 0.5 s early. Arm a one-shot fire through a pure `BoundaryScheduler`, reusing the existing claims. Budget: ≤100 ms of media error at every preset, and one fire per boundary.
- *tick-fanout-coalescing* (narrowed): gate the reader, PDF and visual-listening tick work on visibility. Throttle the App Group position write to 5 s plus significant events. Those writes and the Watch messages fire only on a progress change of more than 0.5%, not every tick (PlaybackProgressPresenter.swift:126, :133). Test the accuracy of the Siri and Watch bookmark positions.
- *root-shell-narration-fanout* (S): RootTabView reads `isRunning` 8 times (:270, :357-366, :415-421), and it is derived from a snapshot rewritten on every block. Store a Bool that changes only when the state flips.
- *reader-vm-survives-tab-switch* (M, conditional on a ReaderTabSwitch baseline over 300 ms): a single-slot view-model cache above the tab switch (RootTabView.swift:193).

**B-8 · Memory, data and assets · 1.1**
- *narration-engine-residency* (S): the only iOS unload happens after a full successful render (PlayerModel+Narration.swift:897-900). Cancel, error and book switch never unload, and there are 0 memory-pressure handlers. Unload on those paths and on a memory warning while idle. Gate the 60 s idle unload on each engine's measured reload cost, and exempt Phonon until its trial reports. Budget: footprint within 40 MB of baseline 10 s after a cancel.
- *narration-memory-regression-gate*: replace `self.runOptions = try? Self.makeRunOptions()` (OnnxKokoroEngine.swift:466) with a logged error and a non-nil test now. Add a per-chapter RSS slope to narration_benchmark.py (≤5 MB/chapter, ≤1.2 GB peak at jobs=1) after one baseline run.
- *thermal-aware-render-ahead* (S): look-ahead 0 at `.serious` or above, 1 under Low Power Mode. Depends on the residency helper.
- *v45-hot-path-indexes* (S): **V45 is reserved for `playback_event(event_type, audiobook_id)` only**. playback_event has no event_type index (Schema_V1.swift:410-411), while real_time_event does have one (:418). Add `word_timing(audiobook_id, audio_start_time)` only if the harness shows the temp B-tree sort matters. That index would also serve C-5's passage resolver. Check open branches, Phonon and #637 for a pending V45 first. Acceptance: an EXPLAIN test confirms no SCAN of playback_event.
- *watch-context-payload-budget*: cap the Watch queue at 50 cards and stop sending `wordCloudJSON`, which nothing displays (WatchViewModel.swift:886-891). Always include the queue in application contexts, and omit it only from replies and ticks (WatchSyncManager.swift:170-175). Budget: ≤48 KB per context. The signpost is WatchContextBuild.
- *bookmark-artwork-offmain-bounded*, *artwork-off-main*: decode off-main with CGImageSource downsampling and a 16 MB bounded cache. Decoding happens only when the artwork key changes (BookmarkArtworkCoordinator.swift:111), not per tick. Keep the #542 baseWatchThumbnailData lifecycle.
- *image-cache-sizing*: make ReaderImageLoader a real LRU (a hit at :16 never reorders) and size images to the cell. Changing the blur backdrop needs Dan to look at it.
- *insights-single-scan-budget*: one segments read per load. Budget: StatsLoad ≤150 ms p95 at 20k segment rows, and a parity test.
- *abs-cover-cache-downsample*: in-memory NSCache only, cleared on sign-out, because the code deliberately does not cache account-scoped covers on disk (AudiobookshelfService.swift:209-210).
- *audio-graph-cpu-measure* (S): decide whether `pitch = 0.01` (AudioEngine.swift:169) or its "old workaround" comment (:436-443) is wrong, after a listening check.
- *mac-reader-share-feed-vm-and-signpost* steps 1-2, *feed-word-rate-update-cost* (signpost only), *first-run-funnel-signposts* (stateless events).

## C. Hardened workflows

**C-1 · G2 FeedbackPresenter · One feedback policy · 1.0-gate · S (critic-added; not value-checked)**
The repo makes exactly one VoiceOver announcement (RootTabView.swift:789). The capture items each invent their own feedback.
Proposal: add a concrete `FeedbackPresenter(result, context: screenOn/screenOff/remote/CarPlay)` that chooses between haptic, earcon, announcement and capsule, with thin Watch and Mac adapters. It ships first, and about ten items consume it.

**C-2 · ios-periodic-resume-checkpoint · Resume survives jetsam · 1.0-gate · S**
On iOS, progress is saved only on pause, load or switch, and background (PlaybackController.swift:338; PlayerLoadingCoordinator.swift:89, :800; RootTabView.swift:712). The tick never saves (PlayerModel+PlaybackControllerDelegate.swift:8-22), while the Mac saves on every tick (MacPlayerModel.swift:447).
Proposal: a pure `ResumeCheckpointPolicy` that saves every 15 s, after a jump of more than 5 s, and on chapter change. The manifest write (Persistence.swift:189-194) runs off-main.
Budget: after `simctl terminate`, at most 15 s lost. Under 1 ms on main per checkpoint (signpost ResumeCheckpoint).

**C-3 · abs-progress-push-durable · ABS push actually sends · 1.0-gate · M**
`pause()` sets `isPlaying = false` (PlaybackController.swift:319) before the non-forced push, and `shouldPush` then refuses (ABSProgressSync.swift:13). So a pause never pushes to ABS. Pushes use `try?` with no retry (PlayerModel+Audiobookshelf.swift:237-240), and the background push has no background task (PlayerModel.swift:1418).
Proposal: force the push on pause. Run the throttled push from C-2's checkpoint. Wrap the background push in `beginBackgroundTask`. Keep one persisted pending position and retry it on the next checkpoint or launch.
Acceptance: with stubbed failures, the final server position equals the last local checkpoint. A device check against the ABS web UI. Status UI is in C-14.

**C-4 · container-move-resume-ids · Resume survives container moves · 1.0-gate · M**
`Track.id` is the absolute URL (Track.swift:6). Track restore matches IDs exactly and falls back to index 0 (PlayerLoadingCoordinator.swift:662-674, PlayerModel.swift:1068). ContainerPathRepair never touches the manifest or the progress keys. The reconciler can return `.pushLocal` when the local position is 0 (ABSProgressReconciler.swift:20-29), which would overwrite the good copy on the server.
Proposal: land the reconciler guard first (never `pushLocal` at 0 or while a restore is pending). Then match tracks by folder-relative path, and rebase the manifest and keys during repair.
Acceptance: an old-UUID manifest restores the saved offset, and the guard has a test.

**C-5 · Capture path: CaptureCoordinator + truthful feedback + real text · 1.0-gate · M**
Five call sites discard `MarkPassageResult` and play `Haptic.light` regardless of outcome: PlayerControlBar.swift:120, TransportControlsView.swift:261, TransportControlsView+LongPress.swift:75, ExperimentalControlLayer.swift:339 and the CarPlay observer at PlayerModel.swift:1364. The Watch gets no commandResult (WatchCommandRouter.swift:153-154). The snippet is only "Chapter: X" or a timestamp (PlayerModel+MarkedPassages.swift:45-51).
Proposal: one concrete `CaptureCoordinator.markPassage()/addBookmark()` that goes through C-1, returns `markPassageSaved` or `markPassageFailed` to the Watch, and has a source test confirming no view calls `markPassageAtCurrentTime` directly. Add a `PassageTextResolver` in Shared, off-main: word_timing first, then the overlapping epub_block (required, because Mac books lack word timing until #421), then the chapter title. The real text is 1.1 if 1.0 is tight.
Budget: Capture.markPassage ≤50 ms from tap to feedback.
Merges: mark-passage-truthful-feedback, inbox-capture-real-text, and the capture parts of one-tap-capture and single-action-dispatcher.

**C-6 · Add-to-Library and first pick · 1.0-gate · M**
Every pick runs `registerLibraryRoot` and then `loadFolder` with autoplay on (RootTabView.swift:473-479, PlayerModel.swift:1485). So adding a folder stops the current audio, and root-registration errors are only logged (:1535-1551). A parent-folder pick sets `folderURL` with no tracks (PlayerLoadingCoordinator.swift:130-131, :184-190), and the listened-only shelf (LibraryViewModel.swift:33) stays empty, with circular empty-state copy (LibraryView.swift:266-267).
Proposal: "Add to Library" uses `FolderPicker(.folder)` and the existing `vm.addRoot` (LibraryViewModel.swift:227-238, currently Mac-only), and never touches playback. A container pick never calls loadFolder. Announce "Found 12 books in Audiobooks". Add a collapsed, lazily loaded "Ready to start (N)" row, and leave the listened-only main shelf unchanged.
Acceptance: Add leaves `folderURL` and `isPlaying` unchanged. A 3-subfolder root shows Ready (3), and playing one moves it to the shelf. Update Wedge3ClarityOnRampTests.swift:15, :76 and NowPlayingLayoutTests.swift:213.
Merges: split-add-to-library-from-open-book, container-folder-first-pick-dead-end, ready-to-start-shelf-section, one-verb-per-add-intent (labels).

**C-7 · align-survives-tab-switch · Alignment survives leaving the Reader · 1.0-gate · M**
`tearDownReader` cancels the run (ReaderTab.swift:504, :765). The pipeline deletes the previous automatic anchors before any new work (AutoAlignmentService.swift:139-146). Failure paths return without throwing, so the success haptic fires (:126-133, :196-199). The sheet can be swiped away, and it shows the raw log (AutoAlignmentProgressView.swift:44-106).
Proposal: move task ownership to PlayerModel. Swap anchors atomically at the end of the run, inside AutoAlignmentService rather than by changing the DAO's meaning. Throw on failure. Add a persistent "Aligning… chapter N of M" chip, Retry on failure, and put the log behind Details.
Acceptance: a run cancelled after Tier 0 keeps the previous anchor and word_timing counts. A source test confirms tearDownReader does not reference the task.

**C-8 · CarPlay mic: stop, save, confirm · 1.0-gate · S**
`carPlayVoiceMemoRecorder` is assigned at PlayerModel.swift:2094 and never read or stopped. The comment at :2063-2066 promises a save path that does not exist. The button image never changes (CarPlayManager.swift:69-74). The CarPlay entitlement is commented out (EchoCore.entitlements:9-16), so this fix, or hiding the mic button, is a precondition for re-enabling CarPlay.
Proposal: make the button a toggle with a 2-minute cap. Disconnect or interruption stops it too. Stopping always saves through the voice_memo path, links the memo to the new bookmark, resumes playback and plays an earcon. If microphone permission was denied, keep the bookmark and say so.
Acceptance: two taps produce 1 bookmark and 1 memo, the session category is `.playback` again, and a disconnect still saves.
Merges: carplay-voice-memo-dead-end.

**C-9 · Watch capture correctness · 1.0-gate · S + M**
(1) *watch-voice-memo-file-race*: the delegate hops to a `Task` before copying the file (WatchSyncManager.swift:325-330), and WatchConnectivity deletes the file when the delegate returns. A failed copy only logs (WatchCommandRouter.swift:228-233). Fix: move the file synchronously into an App Group inbox and drain it on launch. Test: delete the source right after the move.
(2) *watch-bookmark-timebase*: the Watch sends book-absolute time (WatchViewModel.swift:1367-1373, PlayerModel+WatchState.swift:36), and the phone stores it as a per-track offset (PlayerModel+Bookmarks.swift:261-277). Fix: send the live `addBookmark` when reachable. When queued, send `bookTime` and convert it on the phone. Test: 3,700 s maps to track 2 at 100 s.
(3) *watch-honest-capture-feedback*: Quick Bookmark plays `.success` even after a failure (PlayerPage.swift:841-845). The haptic setting is false until the first sync (WatchViewModel.swift:232-235). markPassage is not deferred-safe (WatchCommandRouter.swift:192-194). Fix: a durable outbox keyed by capture UUID, success only after a reply or enqueue, failure always signalled, and the haptic default true.
(4) *watch-review-index-skip*: `currentIndex += 1` after the card is removed skips every other card (WatchReviewView.swift:75-85, WatchViewModel.swift:930). Fix: track the card by id and always show `dueCards.first`. The review tab disappears when the queue empties (ContentView.swift:129), so acceptance is presenter-level (each card shown exactly once) plus a defined landing page.
(5) *watch-skip-grades-checkpoint*: Watch skips bypass `consumeRemoteSkipAsCheckpointGrade` (WatchCommandRouter.swift:82-93 vs PlayerModel.swift:1975-1993). Add it to the facade protocol, with a router test.
(6) *watch-sync-status-surface*: a no-book state, a hidden-by-default stale/unreachable line, and "Saved on Watch, will send later", all from one `WatchLinkStatus`.
Merges: watch-capture-receipts (UUID and dedupe).

**C-10 · Dead ends in routes and states · 1.0-gate · S each**
- *deep-link-dead-ends*: `echoaudio://<host>/chapter/N` pushes a placeholder (NavigationDestinations.swift:37-38, :47-60). Make it seek to the chapter. `settings` opens Appearance instead of the Settings sheet (PlayerModel.swift:1650-1652). `navigateToBookmark` only switches tabs (:1662-1664).
- *abs-open-dismisses-all-sheets*: nothing ever sets `showingSettings = false`, so "Open in Echo" leaves Settings on screen. Add a root "dismiss modals" request.
- *library-load-error-state*: a load failure shows the first-run empty state and an alert titled "Couldn't open book" (LibraryViewModel.swift:78-83, LibraryView.swift:132-136). Add a LoadState with Try Again, on both platforms.
- *reader-loading-error-recovery*: a nil DB leaves "Loading EPUB..." on screen forever (ReaderTab.swift:960-961, :542-548). Add a ReaderLoadState and fix the named silent sites (:292, :628-630, :653-655, :1112-1117; ReaderTab+Alignment.swift:55-59, :565-613). Every capture announces through C-1.
- *alignment-banner-predicate*: `source != 'auto'` matches no case (ReaderFeedViewModel.swift:1047-1056). Use `humanAnchorSources` and show the banner only for estimated anchors.
- *transcription-false-done*: failed chapters still advance the count (StandaloneTranscriptionService.swift:57-65, :247-252). Add `failedChapterIndices`, "Retry failed chapters" and a visible finalize error.
- *import-deferred-retry*: `DatabaseWorkDeferred` has no LocalizedError (DatabaseWorkProtection.swift:6). Show a specific message with Retry and Cancel, and keep the staged copy.
- *narration-partial-failure-retry*: NarrationStatusView has no action (:15-60). Add "Try again" / "Stop generating" through NarrationResumeResolver, engine-agnostic so it works with Phonon.
- *launch-state-recovery*: rename the button to "Continue Without Saving", add a persistent banner and a 2 s explanatory spinner (EchoCoreApp.swift:75-78, :99-106). Retry relaunches the open.
- *macos-async-db-open* (part a): the Mac Release fallback to an in-memory DB shows an error instead.
- *mac-quit-resume-and-pause-highlight*: flush in `applicationWillTerminate` with an ABS push capped at 1 s, and keep `currentBlockID` when paused (MacReaderFeedView.swift:503-507).
- *mac-dead-menu-commands*: ⌘F has no receiver. ⌘N and ⇧⌘E are dead while Notes is hidden (MacReaderNotesSplit.swift:44-48). Open Notes before acting, alert on export errors (MacNotesPane.swift:52), and remove or disable Find. Migrating to FocusedValue is 1.1.
- *mac-mark-passage-parity*: both Mac paths write a point timestamp with `try?` (Echo_macOSApp.swift:335-345, MacTriPaneView.swift:510-520). Route them through MarkedPassageCapture and C-1 (S-M).
- *mac-batch-off-main* (narrowed): stage failures already surface `errorMessage` (MacBatchQueueView.swift:183). Add Retry for failed rows. The off-main refactor is 1.1, after #421.
- *G1 StoragePreflight* (critic-added; not value-checked): there are 0 free-space checks. Check before an ABS download (zip size ×2.1) and before each narration chapter.
- *G4 V44→V45 upgrade test* (critic-added): run against a shipped-shape DB plus a defaults snapshot.

**C-11 · siri-bookmark-dead-on-watch · Truthful Siri claims · 1.0-gate · S**
CreateBookmarkIntent needs `currentTrackTime`, and only the iPhone writes it (WidgetStatePublisher.swift:90), so on Watch it always throws. Bookmarks drained into `bookmarks_*` never leave the Watch.
Proposal: route it through C-9's durable path, or remove the shortcut and fix user-manual.md:120, with its assertion, in the same PR.

**C-12 · 1.1 workflow items**
- *voice-and-headphone-capture-intents* (M+): an iOS AppShortcutsProvider with Mark passage, Bookmark, Skip back, Sleep 15 and Resume, all going through CaptureCoordinator and speaking a short dialog. StartReview comes after A-1, and CheckpointGrade after C-9(5) and C-13. Keep them out of the macOS and echo-cli targets by target membership, not `#if os`. Don't clash with the Watch phrase (AppIntent.swift:80). Budget: a spoken mark lands within 2 s while the phone is pocketed.
- *checkpoint-countdown-survives-suspension* is **1.0-gate, M**: use a persisted deadline and reconcile on scenePhase or remote command (StudyCheckpointCoordinator.swift:240-253). On a grade failure, restore or defer and play a spoken cue (:145-170). Edit ROADMAP.md:42 only after a device check. Only auto-Again was verified to exist.
- *remote-skip-interval-stale* (S): `preferredIntervals` is set once (NowPlayingController.swift:50-62). Add `updateSkipIntervals`, driven by a SettingsManager `didSet`, shared with the Mac.
- *abs-download-survives-navigation* phase 1 (M): an app-owned coordinator and a Library progress card. Closing the sheet keeps the download running (ABSBrowseView.swift:62).
- *open-in-document-types*, *mac-open-paths* part 2: Viewer-role document types at Alternate rank, file-URL routing, and Mac drop handling.
- *ios-resumable-job-queue* phase 1: an "interrupted job" marker and a Resume banner, reusing the existing `batch_queue` (Schema_V20.swift:7, Schema_V21.swift:4-10). No migration unless columns are missing.
- *watch-hands-free-entry-points*: Watch onOpenURL, retire the dead toggle path, and add an Inbox complication.
- *watch-pomodoro-wrist-down-alarm*, *app-scoped-launch-coordinator-carplay* (an S observer on `databaseService`), *sync-health-single-surface* (article iCloud `waitForUser` plus pending ABS first), *mac-help-and-empty-state-parity* (**1.0-gate**: HelpContent membership on the Mac app only, with SettingsManager injected).

**C-13 · no-lost-progress-verification-matrix · 1.0-gate · M**
docs/qa/no-lost-progress-matrix.md lists call, route change, terminate, container move, offline ABS, unreachable Watch and Mac quit, each with a maximum loss. Back it with tests, a simctl terminate script run through xcode-build-slot, and a per-promotion device checklist.
Acceptance: ≤15 s loss for every playback row and 0 lost captures for every capture row. ROADMAP.md:57 is ticked only when every row passes.

## D. CI and release hardening

- **D-1 · train-require-ci-green-on-sha · 1.1 (highest-value CI item) · S.** plan() never reads check-runs (release_delivery.py:209-243). Require the "Build gate + tests" check to have succeeded on `source_sha`, treat cancelled as not green, and accept docs-only. Keep the train's build-for-testing step, because it guards against runner Xcode skew (release-trains.yml:150-161). Acceptance: fake-api tests for success, failure and missing.
- **D-2 · ui-launch-smoke-gate · 1.0-gate · M.** Delete the template UI tests and add EchoSmokeUITests (launch, open, play, background/resume). There is no committed audio fixture (`*.m4b` is gitignored), so add a generated tone first. Assert the persisted position, not wall time. Run it on nightly first, and make it PR-blocking after 20 consecutive green runs.
- **D-3 · perf-budget-nightly-lane · 1.0-gate · M.** A separate scheduled workflow with XCTOSSignpostMetric for launch, scroll hitch and hangs. Warn on regressions over 20% across 5 iterations. Absolute numbers are on-device targets.
- **D-4 · ci-split-parallel-jobs · 1.1 · M.** Add timeouts now. Split into contracts (ubuntu), ios and mac jobs under one aggregator named "Build gate + tests". Keep renderer-install-test on macOS (store.py:42, :255, :274). The repo is public, so the cost is runner concurrency, not minutes.
- **D-5 · ci-cover-orphan-suites · 1.1 · S.** Add doc-automation, pronunciation-pack, audit-pack and the stdlib-only neural-g2p tests to CI. Add a doc_contracts test that every `*-test` target is either wired or explicitly excluded.
- **D-6 · release-receipt-script · 1.1 · M.** Write a receipt block to the step summary. A missing Mac receipt produces `::error`, not a red run, until a Mac .pkg ships (Fastfile:405-418), and only when the plan called for a Mac build.
- **D-7 · pin-resolved-packages · 1.1 · S.** Add `-onlyUsePackageVersionsFromResolvedFile` at release-trains.yml:222 and to the gym xcargs. Measure the warning count from a fresh xcresult; the CODE_AUDIT §3.4 baseline is stale.
- **D-8 · G5 rename-sweep checklist · S (critic-added).** Add to the PR template: grep EchoTests (Wedge3ClarityOnRamp, SettingsExtraction, the 31 Mac source-scan files, the doc tests) before renaming any UI string.

## Slices

Each slice is a PR series, not one PR.

1. **No-lost-progress S fixes (recommended first).** C-2 resume checkpoint, C-9(1) Watch file race, C-3 force push on pause plus the background task, the C-4 reconciler guard, the Mac flush-on-quit and the Mac in-memory error. Pure S work, no design decisions, and the biggest gain in trust. These items have no dependencies beyond the existing seams.
2. **Foundations.** B-1 Signposts, budgets doc and MetricKit; C-1 FeedbackPresenter; G4 upgrade test; D-8. This must land before slices 3, 4 and 7 measure or announce anything.
3. **Capture path.** C-5, C-8, C-9(2-6), Mac Mark Passage, C-11. Then, in 1.1, one-tap bookmark, voice intents and inbox triage. Depends on 2. watch-bookmark-timebase lands before the outbox.
4. **Reader.** A-2 menu and reset (before the A-10 banner copy and the alignment-banner predicate), C-7 job ownership, then B-3, A-5, A-4 (S), B-4 and B-2's reader half. Coordinate with #421 for every AlignmentService edit.
5. **Library, study and first run.** C-6, C-10 library/ABS dead ends, A-1 study hub (before the StartReview intent, notification and Watch review links), A-8, checkpoint countdown, A-14, A-10 Help, A-9, A-11, Mac Help. Then, in 1.1, ABS downloads, Ready-to-start polish and G3.
6. **Player and settings dedupe.** A-3, A-6, A-7, B-2's player half, B-5. Then the A-15 set in 1.1.
7. **CI and release.** D-2 and D-3 (1.0). D-1, D-4 to D-7 (1.1). D-1 does not need D-4.

Migration order: V45 holds only the playback_event index. Later tables take V46 and up, in the order they land. `launch_marker` uses app-group defaults rather than a table.

## Out of scope / dropped

- **audio-first-checkpoint-quiz** (later): L effort, audio-session risk, and depends on the checkpoint countdown fix.
- **container-repair-steady-state-skip** (later): a premature optimisation until Launch.ContainerRepair is measured. The comment about the first launch after a move describes the UPDATE, not the scan.
- **scoped-word-rematerialize** (later): high risk to read-along correctness. Revisit only if B-3 misses its budget, and only after #421.
- **mac-batch-engine-reuse** (later): ONNX prepare takes about 0.7 s per book. Measure Mac against CLI first, after Phonon and #421.
- **full-study-backup-restore** (later): needs a decision memo on scope and Pro gating. Bookmarks and progress still live in UserDefaults (Persistence.swift:8-18).
- **automate-backmerge** (later): a maintainer chore. A main→weekly PR would skip the ladder.
- **tick-delegate-bookmark-scan**: microseconds of cost. The tick signpost will show whether it matters.
- Struck sub-proposals: the net −200-line metric; an "every property has a reader" lint; making the DEBUG in-memory DB opt-in; a Settings Diagnostics UI; per-chapter word windowing; a Help build-time generator; a warning-count ratchet script; a "Keep downloading?" dialog; auto-retrying imports on didBecomeActive; `isIdleTimerDisabled` for imports and alignment (the phone is locked in a pocket on the route); a CADisplayLink for karaoke in the first version; the Watch settings performance half.

## Open questions for Dan

1. **Default transport row.** Should fresh installs get `[section back, skip back, play, skip forward, section forward]` in place of the deliberate empty slots from d8c77fee? Saved layouts would not change.
2. **One-tap bookmark.** Should a bookmark save on the first tap, with Edit and Undo in a capsule, replacing the draft sheet the transport slot opens today?
3. **Study hub.** Is it acceptable to replace "Stats" with "Study" in the More menu, with Insights moving inside the hub?
4. **Settings root.** Should the inline book-override sections (the audit E1 decision) become a single "This book's settings" row, and should Focus Tools move into Playback Options?
5. **Experimental player.** Keep it parked and opt-in for v1.1, with only the trap fixed, or schedule it to graduate?
