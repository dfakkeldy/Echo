# Echo v1.1 — Streamlined, faster, harder to break

This plan sets the scope of Echo v1.1: a simpler UI, measured performance and hardened user workflows on iPhone, Watch, CarPlay and Mac. It merges an eight-area audit of nightly `b9c9040d` into a set of shippable items. Each item has a gate tag, an effort size, file:line evidence and an acceptance check. The audit's fact-check pass verified the line numbers on that commit. Where that pass corrected a citation, the corrected one is used here. The reader is Dan, who uses Echo hands-free on a mail route, and the agents who will implement the items. An item marked "critic-added" came from the completeness review and has not been value-checked.

Depth: this is a program plan. For each item it fixes the problem, the invariant that must hold, and the tests that prove it. Where an item needs a protocol (sync ordering, receipts, background execution), its own spec, written before code, chooses the mechanism, as ROADMAP Part A prescribes. An implementer must not treat a mechanism sketched here as settled when that spec finds a better one.

## Decision 1: what v1.1 means

The three v1.1 themes overlap two 1.0 gates that are still open. ROADMAP Wedge 2 has an unchecked "Performance budget" line (ROADMAP.md:60) and a "No-lost-progress guarantee" still marked [~] (ROADMAP.md:58). Wedge 3 has the UI overhaul and the UX-flow audit (ROADMAP.md:68-70).

- **(a)** v1.1 is the release after 1.0. It takes over specific items that are moved out of the 1.0 gate.
- **(b)** "v1.1" is just a name for finishing those 1.0 gates.

Both options are workable. Release names and tags are choices; ROADMAP.md:58-60 and :67-69 require *outcomes* (no lost progress, a performance budget, an obvious UI, no dead ends), not any particular architecture in this plan.

**Recommendation: (a), run as two tracks**, for reasons of scope and release risk:

- **Smaller 1.0.** The 1.0 closeout track holds only items tagged `1.0-gate`: fixes the existing gate text already requires, mostly S/M and mostly data-safety. The redesign-flavoured work (progressive-disclosure settings, voice intents, karaoke clock, CI restructuring) waits for 1.1, where it can change behaviour without holding up the first release.
- **Honest gates.** Option (b) keeps every UI-overhaul ambition inside the 1.0 gate. That makes 1.0 later and makes its scope harder to judge, because nothing separates "must not lose data" from "nicer layout".
- **The cost of (a)** is that some open ROADMAP lines move. Any item removed from the 1.0 gate needs an explicit ROADMAP edit that Dan approves, not just a tag flip in this document.

Architecture named here (a `Signposts` enum, a `FeedbackPresenter`, a `CaptureCoordinator`) is the proposed means, not a requirement. An implementer may meet the same acceptance criteria another way.

How a flip works: flipping a `1.0-gate` item to `1.1` ships it after the App Store 1.0 and requires the matching ROADMAP edit. Flipping a `1.1` item to `1.0-gate` delays 1.0.

## Design principles

1. **Fewer decisions mid-task.** Save first and edit later. Choose defaults once at home, not on the route.
2. **One place per action.** Each action has one primary control and at most one secondary path, and the same control does the same thing in every layout.
3. **Progressive disclosure, not deletion.** Rarely used options go behind "Advanced" or a submenu. No study capability is removed.
4. **Every state has a next action.** No endless spinner, false "Done", dead button or sheet stacked on a sheet. Each failure state names its single next step.
5. **Nothing is lost silently.** Two different signals: an immediate *acknowledgement* ("got it", within 50 ms) and a *result* (saved, queued, failed). The success cue or "Saved" plays only after a durable write or a durable outbox entry. Every failure gives a signal you can hear.
6. **Reachable without looking.** Core actions sit in the bottom thumb arc and can also be triggered by headphone, Watch, CarPlay or voice.
7. **Measured, not assumed.** Every performance change names a signpost interval, its budget and a recorded baseline.

## Where Echo stands

- **Player.** Default Now Playing shows about 14 controls and 4 menus, and 2 of the 5 transport slots ship empty (SettingsManager.swift:52-54). The sleep timer has 4 menu implementations. Speed has 5 label formatters and 2 controls that behave differently. Mark passage has 6 call sites, and only 1 shows its result. There are 5 separate WatchAction dispatch switches. Dead code: BottomToolbarView.swift:263-306 and NowPlayingTab.swift:446-485 and :518-531.
- **Reader.** The paragraph menu has about 13 items, and 7 of them are alignment actions. About 16 controls sit above the first paragraph, and 2 filter chips are permanently disabled. Each manual alignment edit does a synchronous whole-book recalculation plus a reload on main. There are 0 reader signposts.
- **Library.** One picker is reached from 7 triggers under 5 labels. ABS is 5+ taps deep, across 2 stacked sheets. The shelf runs a full regroup pass on every appearance.
- **Settings.** The root has about 22 rows. The 13-value skip array exists in 3 copies. 6 SettingsManager properties are dead. 5 of 8 NavigationDestination cases are never produced.
- **Study.** Review is reached through More, then Stats, then a scroll, and it opens as a sheet on a sheet. The Insights "Retention" and "Avg Ease" tiles read `ease_factor`, which FSRS never writes.
- **Onboarding.** First launch teaches 1 of the 4 steps (import). Help has 14 flat sections while the manual has 27. Help is covered only by the Settings-path doc contract (Scripts/doc_contracts/contracts.py:48-64, run in CI by tests/test_doc_contracts.py); nothing checks its control names or icons.
- **Mac.** 12 untyped NotificationCenter command routes, 3 of which can have no receiver. 0 FocusedValue uses. Mark Passage is implemented twice.
- **Watch.** Review skips every other card. Bookmarks are stamped with whole-book time. Each command reply runs an uncapped `allDueCards()`.
- **Performance.** There is exactly 1 OSSignposter (AutoAlignmentWorker.swift:34). A 2 Hz tick drives 4 screen bodies (inferred from code, not measured). MetricKit metric payloads are discarded.
- **CI.** One serial job of about 53 minutes with no timeout. The release train never checks CI on the SHA it ships. The UI tests are template stubs.

**June 2026 UX-audit status (docs/UX_AUDIT_2026-06-25_wedge3_clarity.md)**

| Finding | Status |
|---|---|
| P0 First launch looks playable while doing nothing | Fixed (ROADMAP.md:70), but a container-folder first pick brings back a trackless Listen surface, so partly reopened (C-6) |
| P1 Chapter navigation discoverability | 44pt size fixed. Empty default slots and top placement still open (A-3) |
| P1 Two competing More menus | Fixed on iOS. The Mac has dead menu commands instead (C-10.12) |
| P1 Core study actions are long-press first | Open: no visible action surface, inert inline rows, banner copy (A-2, A-5) |
| P1 Study entry points split | Open (A-1) |
| P1 Reader empty state has no import / import hidden | Fixed on iOS. Mac still open (A-12) |
| P1 PDF import promise | Fixed |
| P1 Onboarding | Launch gate removed. The teaching half is open (A-14). The ROADMAP Onboarding line's false "walkthrough is wired" claim was corrected in this plan's PR (4f95205e) |
| P2 Settings routes land on placeholders | Audio route fixed. Chapter route open (C-10.1) |
| P2 Capture/review failures masquerade as empty | Inbox load fixed. Stats loaders (A-8), capture feedback (C-5) and Mac capture and export (C-10.13, C-10.12) open |
| P2 ABS loading/empty states | Fixed |
| P2 Timeline copy in docs | Fixed |
| P2 Bookmark loop fails silently | Fixed (including on Mac) |
| "Recommended Next Order": Try Sample | Open and unscheduled; see Open Question 6 |
| "Recommended Next Order": empty/error recovery | Library still open (C-10.3) |

The June audit had no findings for the Watch.

## A. Simplified UI

**A-1 · study-today-entry · One study hub with due counts · 1.0-gate · M**
Review, Card Inbox and Decks are reachable only from the Stats sheet, after the charts (StatsView.swift:146-150, :406-426). If loading SRS data fails, all three entry points disappear (:146-149). `echoaudio://study` opens Read (DeepLinkHandler.swift:75-76). The chapter-checkpoint notification ("Chapter finished" / "How did … go?", with Good and Again actions, StudyCheckpointNotificationService.swift:23-46) ignores a default tap (:63-78).
Precondition (A-1a, S): `playCheckpointItem()` loads a book, sleeps 300 ms, then seeks and plays whatever is loaded (PlayerModel+StudyCheckpoint.swift:95-104), while post-load work is asynchronous (PlayerLoadingCoordinator.swift:776-780). Replace the sleep with a load-completion continuation that checks book identity and load generation, and cancels if another selection arrives. Test a delayed load, a failed load and two competing selections. This lands before any new study entry point.
Proposal: replace "Stats" in More with "Study", which opens a root-presented hub listing Review N due, Card Inbox (N), Decks, this book's Plan, then Insights. Add a due-count row at the top of Read & Study that starts review directly. General study links (`.study`, the Watch review link) land on the hub. A default tap on the checkpoint notification opens that checkpoint's grading prompt; if the checkpoint is stale or already graded, it opens the hub with a one-line note. Every notification carries the checkpoint's persisted id, and the Good and Again actions apply only to that id (today they act on whatever checkpoint is current, StudyCheckpointNotificationService.swift:67-73); a stale or already-graded action is ignored and logged, and a duplicate grade is applied once. Replace the `try?` calls in StudySessionViewModel (:72-73, :119-120, :130) with surfaced errors. Do not mount DashboardShelf.
Acceptance: review starts in 1 tap from the Read row, or 3 taps from Now Playing (More → Study → Review) with no scrolling. VoiceOver reads "Review, 12 due" as one element. A checkpoint-notification tap test lands on that checkpoint, and a stale one lands on the hub. A delayed Good from checkpoint A after checkpoint B is active leaves B ungraded. A source test confirms StudyLibraryLinksView is no longer inside StatsView.
Merges: review-one-tap-and-notification. Deleting DashboardShelf and FlashcardReviewSession goes to a separate cleanup PR; DailyReviewViewModel stays because the Mac uses it.

**A-2 · reset-alignment-guard + block-actions-visible · Visible paragraph actions, study-first menu, guarded reset · 1.0-gate · M**
Every paragraph's menu, and its VoiceOver actions, include "Reset Alignment" (ReaderTab+Alignment.swift:449-456, :275-279). It runs with no confirmation and deletes hand-placed anchors (AlignmentService.swift:155-162), even though the code marks those as unrecoverable (AlignmentAnchorRecord.swift:58-75). The Mac has the same problem (MacReaderFeedView.swift:582-583). Auto-Align comes first in the menu, and Save Bookmark and Copy come last (:349-475). The VoiceOver list is a second, hand-maintained copy (:184-313).
The June audit asks for "visible inline actions … plus long press as secondary"; paragraph actions are still wired only through context menus (ReaderTab.swift:216-223), so reordering the menu alone does not meet it.
Proposal: (1) the paragraph being spoken, and any paragraph the user taps, shows a small visible action bar (Bookmark, Card, Copy, More). Tapping keeps its current seek behaviour. Whether the bar is always shown on the spoken paragraph or appears only after a tap is Open Question 7. (2) Build the action bar, the UIMenu and the VoiceOver actions from one `ReaderBlockAction` array. Order it Save Bookmark, Make Card, Copy, word actions (lookup, vocabulary), Color, Theme, image actions, then a single "Alignment…" submenu. No existing capability is removed. (3) Move book-level actions (Auto-Align, Reset) to one "Alignment tools" entry. Reset opens a dialog that shows how many anchors are hand-placed and offers "Reset automatic anchors" (the default) or "Reset everything". (4) Rewrite the banner (ReaderTab.swift:321-326) and user-manual.md:160, :176.
Acceptance: a UI or presenter test bookmarks a paragraph without a long press. The menu has at most 7 top-level items. Save Bookmark is the first VoiceOver action. A same-source test covers all three lists. A test seeds 3 human and 5 synthesized anchors, runs the default reset, and finds the same 3 human anchors (by id and time). Keep the "Reset Alignment" string key, or update LocalizationFormattingTests.swift:67. Coordinate AlignmentService changes with #421.

**A-3 · now-playing-dedupe-thumb-zone · No empty default slots, honest menu items · 1.0-gate · S (bugs) + owner decision (defaults)**
More > "Bookmarks" actually switches to Read (RootTabView.swift:351, PlayerMoreMenu.swift:61-62). The `.speed` slot opens a sheet while the dock chip opens a menu (TransportControlsView.swift:215-232 vs BottomToolbarView.swift:162-190). The default row contains `.empty` slots (SettingsManager.swift:52-54). Those slots render as Color.clear (TransportControlsView.swift:280-282) and were a deliberate default (commit d8c77fee).
Proposal: (a) now, make "Bookmarks" open bookmarks, and make the speed slot open the same preset menu as the chip. (b) After Dan decides (Open Question 1), change the default row to `[.previousSection, .skipBackward, .playPause, .skipForward, .nextSection]`. Those two cases are already in the palette and fall back to chapter navigation (PlaybackController.swift:649-680), so PhonePlayerPaletteTests does not change. Change only the defaults and Reset, using `Defaults.phonePage` instead of the literal at PhonePlayerSettingsView.swift:180 (update PhonePlayerPaletteTests.swift:61 and EchoCoreTests.swift:369). (c) Limiting the folder chip to Library is a #407 item that rides with A-13.
Acceptance: More > Bookmarks lands on bookmarks. With (b), the default layout has 0 empty slots.
Merges: phone-designer-defaults-and-cruft.

**A-4 · filter-row-collapse · Wire or hide the dead filter chips · 1.0-gate (S) / 1.1 (M)**
The Bookmarks and Cards chips are permanently disabled behind a stale comment (ReaderTab.swift:785-806), and the filter passes those item types straight through (ReaderFeedDisplayBuilder+Filter.swift:14-15, :53-56).
Proposal: 1.0 (A-4a): implement the existing bookmarks and cards filters (keep those items plus their headers). Hiding the chips is the fallback only if that slips. 1.1 (A-4b): one "Show: Everything ▾" menu that includes a "My captures" option and always labels the active filter. Keep the "Show Everything" recovery (ReaderTab.swift:550-575).
Acceptance: 0 disabled controls in the reader chrome. If A-4a ships the filters, filter tests confirm `.bookmarks` returns only bookmarks and `.cards` only cards, each with its chapter headers; if it falls back to hiding, a source test confirms neither chip is rendered. A-4b: a `.captures` test returns bookmarks, cards, notes and memos and nothing else.

**A-5 · inline-capture-rows-tappable · Captures act on tap · 1.0-gate · M**
Taps on bookmark, card, note and memo rows are no-ops (ReaderFeedCollectionView.swift:1429-1431), and these rows have no context menu (:1465-1468). Memo playback uses `try?` and does not pause the book (ReaderTab.swift:284-294).
Proposal: tapping a bookmark seeks and plays. A card opens its review. A note opens the editor. Add Edit, Delete (with confirmation) and Copy, plus matching VoiceOver actions. Memo playback pauses the book and, like the existing voice-memo path (PlayerModel.swift:2056-2066), resumes it only if it was playing, the same book is still loaded, and the user did not pause or get interrupted meanwhile.
Acceptance: every ReaderCardItem case has a non-nil tap outcome. Memo tests: a playing book pauses and resumes; a paused book stays paused; a book switch during the memo does not resume the new book. ReaderFollowState is not disturbed.

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
The same stale grade≥3 retention logic also lives in StatsAggregator.swift:316-324.
Proposal: replace them with a "Recall (30 days)" tile and a "Mature cards" tile, with definitions that match the scheduler. Recall is the share of first reviews of a card on a given day, in the last 30 local days, graded Hard, Good or Easy, because FSRSScheduler.swift:54-60 treats grade ≥2 (Hard) as recall. Skips and same-day repeats are excluded, and an empty denominator shows "—". Mature means FSRS stability ≥21 days. Fix StatsAggregator in the same PR. Add a ContentUnavailableView with Try Again. Update the manual and Help.
Acceptance: FSRS-only fixtures cover a Hard-only day, a same-day repeat, a skip, the 30-day boundary, an empty window, and stability 20.9 vs 21.0 days. A throwing repository shows the error state.

**A-9 · reader-empty-state-gaps · Explain disabled and unfamiliar actions · 1.0-gate · S**
"Add Document" is disabled during narration with no reason given (ReaderEmptyState.swift:29-33, RootTabView.swift:270). "Transcribe Audiobook" has no explanation (RootTabView.swift:274-283). The copy leaves out PDF, Markdown and text (ReaderEmptyState.swift:51).
Proposal: add a caption ("Available when narration finishes"), a one-line description of Transcribe, and the full list of formats. Update Wedge3ClarityOnRampTests.swift:31-38 in the same PR.
Acceptance: every disabled action has a visible reason next to it.

**A-10 · help-copy-contract-and-drift-fix + markdown rendering · Accurate, rendered Help · 1.0-gate · S**
Help says Settings is a "gear icon in the top-right" (HelpContent.swift:240), describes a "speaker icon" control that does not exist (:70), and says speed "cycles" (:57). Loop, sleep and bookmark are configurable slots, so those lines are roughly right. HelpView renders `Text(String)` as plain text, so `**…**` appears literally (HelpView.swift:16, HelpContent.swift:28). The existing doc contract checks Help's Settings paths only (Scripts/doc_contracts/contracts.py:48-64).
Proposal: fix the stale lines. Render bodies with `AttributedString(markdown:)`. Fix the format list (HelpContent.swift:18). Extend the existing Help contract in contracts.py with must_not_contain entries for the stale claims, and add an EchoTests check that each control Help names exists as a label or system image.
Acceptance: 0 contradicted location claims, and no literal `**` in any section. 1.1: a searchable section list with `echoaudio://help/<id>` links, plus filling coverage gaps by hand with a test mapping each manual H2 to Help or to a web-only allowlist (help-coverage-from-manual).

**A-11 · watch-no-book-state · Watch empty state · 1.0-gate · S**
With no book loaded, the Watch shows "No track selected" above controls that look live (WatchViewModel.swift:86, :400; PlayerPage.swift:598-606).
Proposal: add a `hasLoadedBook` flag derived from synced state, and show "Open a book in Echo on your iPhone" with Review and Inbox still available. Test separately that remote resume still works from a stale cache.
Acceptance: 0 enabled transport controls when no book has synced.

**A-12 · mac-open-paths (part 1) · Actionable Mac reader empty state · 1.0-gate · S**
The Mac reader shows "No EPUB Content" with no action (MacReaderFeedView.swift:120-125). Transcribe is available only as an icon (MacTriPaneView.swift:528-564).
Proposal: add labelled buttons for Transcribe this audiobook, Attach EPUB/PDF and Narrate a document. Make the no-book player bar a button. Drag-and-drop and Finder document types are 1.1.
Acceptance: each button performs its action in a Mac test (Transcribe starts a job, Attach opens the picker, Narrate routes to narration), and each has a text label.

**A-13 · one-verb-per-add-intent · Two verbs · 1.1 · S (rides with C-6)**
The same picker carries five labels (LibraryView.swift:80, :276; UnifiedTopHeader.swift:40; ReaderEmptyState.swift:35; RootTabView.swift:597, :608). NowPlayingTab declares closures it never uses (:6, :9). CHANGELOG.md:150 says the folder chip appears only on Library, which is not true.
Proposal: use "Add to Library" and "Open Book" everywhere. Remove the dead parameters. Either gate the chip to Library or correct the CHANGELOG. Update the pinned "Open a Folder" tests.

**A-14 · live-getting-started-card · Data-driven Getting Started card · 1.0-gate · M**
The ROADMAP Wedge 3 Onboarding line (ROADMAP.md:69) used to say the walkthrough "is wired", while tests assert it is gone (Wedge3ClarityOnRampTests.swift:19-25). That correction is done (commit 4f95205e, in this plan's PR); the teaching work below is not.
Proposal: add one dismissible "Getting started" card that teaches by doing, with four rows ticked from real data. Each row has one action button that performs the step:
- *Add a book*: done when a book with at least one playable track, or a standalone document, is open. Action: Add to Library (C-6), then a list of the books just found with an Open button each; a single EPUB, PDF, Markdown or text file opens directly.
- *Follow along*: done when the loaded book shows text that tracks the audio. That means aligned text for an audiobook with an EPUB/PDF, the generated text for a narrated document, or a transcript for an audio-only book. A book with partial alignment counts. Action: the matching step (Attach text, Align, Narrate or Transcribe), chosen from the book's type; the row explains why when none applies.
- *Make a card*: done after the first flashcard exists for this book. Action: Mark passage, which saves the passage and offers "Make a card" from it (the Card Inbox editor, prefilled). Bookmarks alone do not enter the review queue, which is built from flashcards and study plans (StudyQueueBuilder.swift:15-38), so this row is about a card, not a bookmark.
- *Review*: done after the first graded review. Action: Review now, which starts review directly.
Row queries run off the main actor. Whether to bundle a short sample book so a new user can finish without their own files is Open Question 6.
Acceptance: unit tests for every row's state derivation, including audio-only, narrated and partially aligned books. An end-to-end UI test starting from an empty database (no pre-seeded cards) completes all four rows from the card alone, once with an audiobook folder and once with a standalone document. With the fixture already imported, the capture and review rows take under 60 s of user time; import and alignment time are measured separately and shown as progress, not counted.

**A-15 · 1.1 simplification set** (slices per the Item map)
- **A-15.1** *one-tap-capture* (Open Question 2): a bookmark saves on the first tap, with Edit and Undo in the capsule for 4 s, and the two draft sheets merge into one (RootTabView.swift:511-516). The bookmark stays editable afterwards from Bookmarks, as today (user-manual.md:120-122). Acceptance: 1 tap saves durably (C-5), Undo removes it, and the saved bookmark can be edited later from Bookmarks with VoiceOver.
- **A-15.2** *single-action-dispatcher* (narrowed): delete the dead members listed above. Use one `SpeedFormat.label` and one shared `SleepTimerMenuContent`. Point SettingsNowPlayingView at `PlaybackOptionsSheet.seekDurationOptions`. Fix the experimental loop-icon drift. Acceptance: one test drives every sleep-timer menu (dock, slot, Playback Options, experimental) and gets the same options and the same timer state; one test checks every speed label against `SpeedFormat.label`.
- **A-15.3** *customization-progressive-disclosure*: lead with one "Bottom row" section using grid pickers, and put the rest under Advanced. Fix the false footers at PhonePlayerSettingsView.swift:82 and :50-52 now.
- **A-15.4** *player-style-one-picker*: move the Experimental toggle next to Player Layout, and hide the slot designer while it is on (SettingsNowPlayingView.swift:68-82).
- **A-15.5** *playback-knobs-single-source*: one `seekDurationOptions` in `SettingsManager.Defaults` and one shared `SkipDurationRows`. Keep both surfaces.
- **A-15.6** *watch-settings-progressive-disclosure* (merged): Controls first. Show only the sensitivity slider for the active crown mode. Move Inbox to the bottom under "Integrations". Put Face and Progress under Appearance. Drop the performance half.
- **A-15.7** *study-plan-one-tap-start*: "Start studying" with pacing behind a disclosure, labelled "1 new chapter/day, 2 new cards/day (app limit 20)" (StudyPlanViewModel.swift:15-16). Relabel "New AI Card Offer Cap" (SettingsView.swift:296).
- **A-15.8** *study-notes-split-actions*: plain-language stepper labels and a single feedback entry. Book-overrides placement is an owner decision (Open Question 4).
- **A-15.9** *pro-single-purchase-surface*: title the screen "Echo Pro" and keep one purchase path, PaywallView's `store.purchase` (ProTranscriptsSettingsView.swift:90 vs PaywallView.swift:134).
- **A-15.10** *narration-section*: an iOS Default Voice row, and route all `narrationQAClassifier` reads through SettingsManager (NarrationQAReviewModel.swift:156, :172; NarrationService.swift:138). Land after the Phonon trial.
- **A-15.11** *chapter-menu-dedupe*: one "Turn off audio for this chapter" (ReaderTab.swift:243-265).
- **A-15.12** *dead-settings-and-routes*: delete 6 dead properties and 5 NavigationDestination cases that nothing produces.
- **A-15.13** *inbox-one-pass-triage*: undoable dismiss and inline row errors (CardInboxView.swift:152-177), a Play button, batch "Draft cards" (depends on C-5), and a single-query load.
- **A-15.14** *mac-playback-controls-single-source*, *mac-menu-bar-transport-completeness* (verify bare-Space conflicts in a 1.0 test), *mac-study-window-first-slice* (1.1: one Study window; the 1.0 parity work it builds on is A-16), *watch-review-glance-and-order*, *watch-player-code-consolidation* (one label source, delete WatchBookmarksView), *ready-to-start* (now 1.0, in C-6), *G3 "Where things moved" card* (critic-added, 1.1).

**A-16 · mac-study-parity · Usable Mac decks, editor and Insights · 1.0-gate · L**
ROADMAP.md:95 requires Mac parity for decks and the card editor, deep Insights and Chapter Study ergonomics. Compiling the iOS views for the Mac is not enough.
Proposal: break the line into reachable Mac features, each with its own PR: Decks (list, create, rename, delete, assign cards), the full card editor, Insights with A-8's metrics, and Chapter Study Plan start and grading. Each has a menu or sidebar entry point, saves through the shared repositories, and shows load and save errors.
Acceptance: per feature, a Mac test creates or edits data and reads it back after relaunch, and a forced repository error shows recovery. ROADMAP.md:95 is ticked feature by feature.

## B. Performance budgets

All intervals come from one `Signposts` enum in Shared. It compiles for iOS, macOS and echo-cli with no UIKit, takes its subsystem from Logger+Subsystem.swift, and has one category per area. A new `docs/PERFORMANCE_BUDGET.md` ships with its EchoTests doc assertion in the same PR. Budget numbers are proposals until a device baseline on an A14 iPhone 12 Pro (and an M-series Mac for Mac rows) is recorded. PR-blocking CI gates assert only statement counts, EXPLAIN plans, observation fan-out and "ran off main" probes, never wall time. The one exception is D-3's scheduled nightly lane, which compares wall-time metrics against its own previous runs and only warns.

**Measurement contract.** Signpost intervals measure elapsed time between a named begin and end. Hangs come from the Instruments Hangs instrument or MetricKit hang diagnostics, and scroll hitches from `XCTOSSignpostMetric.scrollDecelerationMetric` or the Animation Hitches instrument; neither is an interval. All rows use a Release build, median of 5 runs after one warm-up, unless stated.

| Interval / metric | Begins → ends | Fixture | Target (proposed) | Tool | Policy |
|---|---|---|---|---|---|
| Launch.AppInit → first frame | `App.init` → first `onAppear` of the root | real library | ≤400 ms iPhone, ≤600 ms Mac | XCTApplicationLaunchMetric + signpost | nightly warn |
| Launch.DatabaseOpen | open start → migrator done | shipped-shape DB | ≤100 ms | signpost | nightly warn |
| Launch.RestoreSelection | restore start → title/cover shown (elapsed); main-thread time inside it | 1 restored book | elapsed ≤300 ms; main ≤150 ms | signpost; Time Profiler main-thread lane | decides B-6 |
| Launch.ContainerRepair | repair start → end | moved container | measure only | signpost | decides the dropped steady-state skip |
| Player.Tick | timer fire → presenter writes done | playing book | ≤1 ms | signpost | nightly warn |
| Reader.open | tab shown → first paragraph visible | F-Book (150k words, 5,000 blocks) | ≤500 ms | signpost | nightly warn |
| Reader.edit.ack | tap → acknowledgement pulse | F-Book | ≤100 ms | signpost | nightly warn |
| Reader.edit.result | tap → committed snapshot published | F-Book | ≤1 s, no hang >250 ms | signpost + Hangs instrument | nightly warn |
| ReaderTabSwitch | tab tap → first paragraph visible | F-Book | measure only; decides B-7 | signpost | — |
| PDF.open | open → first page drawn | F-PDF (300 pages) | ≤500 ms, 0 ms main-thread DB | signpost + probe | nightly warn / CI probe |
| Shelf.snapshot | load start → snapshot ready | F-Library (1,000 books) | ≤150 ms off-main | signpost | nightly warn |
| StatsLoad | load start → tiles ready | F-Stats (20,000 segment rows) | ≤150 ms p95 | signpost | nightly warn |
| Capture.ack / Capture.result | tap → acknowledgement; tap → durable result | any book | ≤50 ms / ≤500 ms | signpost | nightly warn |
| ResumeCheckpoint | trigger → durable commit (elapsed); main-thread time inside it | any book | elapsed ≤250 ms; main ≤1 ms | signpost; Time Profiler | nightly warn |
| WatchContextBuild | build start → payload ready | F-Stats + 200 due cards | ≤48 KB serialized | signpost + byte count test | CI test (bytes) |
| Narration.firstAudio | render start → first buffer | F-Book chapter 1 | measure only | signpost | — |
| Reader scroll hitches | — | F-Book | ≤5 ms/s hitch time | XCTOSSignpostMetric | nightly warn |

The fixtures F-Book, F-PDF, F-Library and F-Stats are generated once by a script (`Scripts/perf/make-fixtures`) into files: a SQLite database plus the media and documents it points to. A test-only launch argument (`-EchoPerfFixture <path>`) makes a Release-optimised performance build copy that database into a scratch container and open it; the argument is compiled into a separate `Echo Perf` configuration (Release optimisation plus a `PERF_FIXTURES` flag) and never into App Store builds. The Mac runs the same configuration, with the on-disk database (the DEBUG in-memory Mac database, Echo_macOSApp.swift:502-506, is not used). Debug measurements never stand in for these budgets.

**B-1 · Foundations: signposts + MetricKit + fan-out tests · 1.0-gate · M**
Merges launch-signposts-budget, perf-budget-harness, signposts-and-metrickit-metrics, ui-perf-budget-harness, metrickit-launch-metrics and the signpost halves of other items. Today: 1 signposter. `didReceive([MXMetricPayload])` is empty (MetricKitDiagnosticsController.swift:84-87). `start()` re-archives past payloads on every launch, keyed by receivedAt, which duplicates them inside the 30-file retention window (:21-28, MetricKitDiagnosticsArchive.swift:17-27). The launch test is the template (EchoCoreUITests.swift:37-42).
Proposal: add every interval in the table above, plus Reader.{reload, tapSeek}, Shelf.regroup and Narration.{prepare, renderSegment}. Archive metric payloads, deduplicated by time range, and move `start()` out of App.init. Add the `PerformanceFixtures` helper and RenderFanoutTests.
Acceptance: all intervals appear in a single Instruments os_signpost + Hangs trace on device. The ROADMAP Wedge 2 "Performance budget" line (ROADMAP.md:60) is rewritten with the ratified numbers.

**B-2 · tick-isolation-screen-bodies · Keep the 2 Hz clock out of screen bodies · 1.0-gate · M**
NowPlayingTab.swift:100, ReaderTab.swift:489 and PDFDocumentView.swift:271 attach `.onChange(of: currentPlaybackTime)` at the screen root. The clock is a 0.5 s Timer (AudioEngine.swift:687). TransportControlsView reads progress in its parent (:47-51). The presenter writes four Observable fields on every tick (PlaybackProgressPresenter.swift:125-131, :149-155). On Mac, `playerBar` reads `player.currentTime` directly (MacTriPaneView.swift:436, :445).
Proposal: move the clock into leaf observers, or push it through a closure into the view models. Add a `ProgressRing` leaf. Make every presenter write conditional on a change. Make the Mac playerBar its own View.
Budget: 0 root-body evaluations per tick for NowPlayingTab, ReaderTab, PDFDocumentView and MacTriPaneView over 60 s (SwiftUI Instruments View Body lane). Over 20 ticks, `durationText` fires 0 times. The ReaderActiveBlockResolver tests stay green.
Merges: now-playing-tick-invalidation-budget, transport-progress-leaf, progress-presenter-equality-guards.

**B-3 · manual-align-off-main · Alignment edits off the main actor · 1.0-gate · M**
Align, hide, erase and reset each call the synchronous service and then a synchronous `reload()` (ReaderTab+Alignment.swift:21-23, :76-77, :89-90, :102-103, :116-117, :174-175). Delete, upsert and recalc are not atomic (AlignmentService.swift:101-122), and Snapshot.read runs twice per edit (:450, :470). The Mac `Task {}` inherits the main actor (MacReaderFeedView.swift:431-450). `recalculateTimelineAsync` (:61-71) and `reloadOffMain` (ReaderFeedViewModel.swift:305) already exist.
Proposal: add async twins that do a single write transaction, give an immediate acknowledgement haptic (not a success cue), and coalesce rapid edits through the reload revision. Serve tap-to-seek and bookmark times from memory: tapBlock currently reads the DB through `audioStartTime` (ReaderFeedViewModel.swift:1071-1080), and `wordTiming()` should use `wordIndex`.
Budget: Reader.edit.ack ≤100 ms and Reader.edit.result ≤1 s with no hang over 250 ms, on F-Book. The pulse is an acknowledgement; a failed write shows an error and restores the previous anchor. 0 DB reads on tapBlock and tapWord. 5 rapid aligns cause at most 2 rebuilds. Coordinate with #421.
Merges: interactive-edits-off-main.

**B-4 · pdf-open-off-main · PDF loads once, off main · 1.0-gate · S then M**
On every `.timelineItemsIngested`, the handler bumps `pdfLoadToken` (which re-parses the PDFDocument on main) and also calls `readAlong?.load` (PDFDocumentView.swift:354-364, :246-258, :378). The controller is @MainActor and runs synchronous fetchAlls (PDFReadAlongController.swift:15-17, :58-140).
Proposal: S first: one load per notification, coalesced through ReaderIngestionReloadTracker. M: a `@concurrent` snapshot builder that reuses ReaderPlaybackSnapshot, with the four columns projected (lean-word-cache step 1). Add a load-failed ContentUnavailableView with Retry (:233-238).
Budget: one controller load per notification (test). On F-PDF, main-thread DB time is 0 ms and PDF.open is ≤500 ms.

**B-5 · shelf-regroup-once · Library appears without churn · 1.0-gate · S**
Library reloads in both `.onAppear` and `.task(id:)` (LibraryView.swift:119-125). The second fetch is cheap because of cancel and single-flight (LibraryViewModel.swift:58-60, :98-106). The real cost is that every appearance and axis switch runs four `fetchAll` passes in regroupForShelfLoad (LibraryService.swift:694-726), and the prune has no attempted-ID memo (:886-911).
Proposal: drop the onAppear reload, gate regroup on a change fingerprint set by the rescan and import writers, memoize the prune, and use EXISTS probes in place of DISTINCT. Pruning also depends on age: a row becomes eligible an hour after it was seen (LibraryService.swift:883-899) with no write. So the fingerprint check also runs regroup when the earliest pending eligibility time has passed, and the prune memo stores that time rather than a permanent "seen" flag.
Budget: on a second visit with no writes and no eligibility time passed, 0 regroup scans and 1 snapshot. A test visits before and after the one-hour threshold with no writes in between; the second visit prunes. Shelf.snapshot ≤150 ms off-main on F-Library.
Merges: library-shelf-load-budget.

**B-6 · Launch path · 1.1 unless noted**
- **B-6.1** *no-audio-session-activation-on-restore* (S): a cold restore with autoplay off still calls `setActive(true)` with non-mixable `.spokenAudio` (PlayerLoadingCoordinator.swift:893, AudioEngine.swift:139-157), which stops Dan's podcast. `configureEngineGraph()` (:160) is private to AudioEngine, so add an internal `prepareForPlayback()` on AudioEngine that builds the graph and installs the interruption and route observers without calling `setActive`. Activate the session on the first real play, including a remote play from AirPods, the Watch or CarPlay. Acceptance: a unit test that restore with autoplay off never calls `setActive(true)`, plus a device test that AirPods play, Watch play and an interruption still behave after a cold launch. No `.mixWithOthers` fallback; Echo keeps non-mixable spoken audio once it plays.
- **B-6.2** *restore-selection-off-main* (L, conditional): do it only if Launch.RestoreSelection exceeds 150 ms on main. The first slice shows the title and cover from the DB row before the audio item is ready.
- **B-6.3** *macos-async-db-open*: the silent in-memory fallback in Release (Echo_macOSApp.swift:502-508) is **1.0-gate, S** (C-10.10). Moving the open off App.init (:46) is 1.1.

**B-7 · Reading and narration rate · 1.1**
- **B-7.1** *karaoke-word-clock* (M): currentTime is written only by the 2 Hz Timer (AudioEngine.swift:683-694), so the word highlight cannot keep up with roughly 3 words/s. The "12.5 Hz" comment (ReaderFeedViewModel.swift:51-53) is stale. Feed a non-mutating precise clock at 10-15 Hz, and only when the reader is visible, playing, has word_timing and Reduce Motion is off. Respect the monotonic guard (:715-724), and use no CADisplayLink in the first version. Budget: ≥8 Hz updates, ≤1 ms per tick, ≤100 ms lag measured against word starts in a trace. Validate after #421. Merges: karaoke-display-link.
- **B-7.2** *boundary-precise-scheduling* (M): the chapter-end window is a fixed 0.5 s (PlaybackController.swift:1001) and the bookmark look-ahead is `max(0.5, 0.3×speed)` (:1060-1061). At 3x, about 1 s of the next chapter plays through sleep timers and checkpoints, and at 1x the boundary fires up to 0.5 s early. Arm a one-shot fire through a pure `BoundaryScheduler`, reusing the existing claims. Budget: ≤100 ms of media error at every preset, and one fire per boundary.
- **B-7.3** *tick-fanout-coalescing* (narrowed): gate the reader, PDF and visual-listening tick work on visibility. The progress callback that drives Watch sync and position publication (PlayerModel.swift:1023, :1387) fires only when the fraction moved more than 0.5% since the *previous tick* (PlaybackProgressPresenter.swift:125-133, :149-157), and the comparison value is updated every tick. With the 0.5 s timer (AudioEngine.swift:687), a 20-minute chapter moves about 0.04% per tick, so on long chapters the callback never fires from playback alone. Requirement: Watch and App Group positions are never more than 5 s stale while playing, and are published at once on significant events (seek, chapter change, pause), whatever the chapter length; total publications stay at or below one per 5 s in steady playback. The spec chooses the mechanism. Tests: a deterministic 20-minute and a 3-hour chapter with the sleep timer off, over 120 ticks, including small seeks; and the accuracy of the Siri and Watch bookmark positions. This bug is **1.0-gate** (it is a no-lost-progress row in C-13); the coalescing is 1.1.
- **B-7.4** *root-shell-narration-fanout* (S): RootTabView reads `isRunning` 8 times (:270, :357-366, :415-421), and it is derived from a snapshot rewritten on every block. Store a Bool that changes only when the state flips.
- **B-7.5** *reader-vm-survives-tab-switch* (M, conditional on a ReaderTabSwitch baseline over 300 ms): a single-slot view-model cache above the tab switch (RootTabView.swift:193).

**B-8 · Memory, data and assets · 1.1**
- **B-8.1** *narration-engine-residency* (S): the only iOS unload happens after a full successful render (PlayerModel+Narration.swift:897-900). Cancel, error and book switch never unload, and there are 0 memory-pressure handlers. Unload on those paths and on a memory warning while idle. Gate the 60 s idle unload on each engine's measured reload cost, and exempt Phonon until its trial reports. Budget: footprint within 40 MB of baseline 10 s after a cancel.
- **B-8.2** *narration-memory-regression-gate*: replace `self.runOptions = try? Self.makeRunOptions()` (OnnxKokoroEngine.swift:466) with a logged error and a non-nil test now. Add a per-chapter RSS slope to narration_benchmark.py (≤5 MB/chapter, ≤1.2 GB peak at jobs=1) after one baseline run.
- **B-8.3** *thermal-aware-render-ahead* (S): look-ahead 0 at `.serious` or above, 1 under Low Power Mode. Depends on the residency helper.
- **B-8.4** *v45-playback-event-index* (S): add one index, `playback_event(event_type, audiobook_id)`. playback_event has no event_type index (Schema_V1.swift:410-411), while real_time_event does have one (:418). The migrator currently ends at V44 (Shared/Database/DatabaseService.swift:294-301), and V1-V44 stay unchanged. The index takes the next free migration number when it lands (V45 if it is first). Its PR also adds the upgrade test from the previous shipped version (C-10.16). Acceptance: an EXPLAIN assertion on the actual playback-event queries used by Insights and the library (for example LibraryService.swift:531-535) shows the index is used. Check open branches, Phonon and #637 for a pending migration first. A `word_timing(audiobook_id, audio_start_time)` index, if the harness shows it matters, is a separate later migration.
- **B-8.5** *watch-context-payload-budget*: stop sending `wordCloudJSON`, which nothing displays (WatchViewModel.swift:886-891). Card text is unbounded (PlayerModel+WatchState.swift:142-151), so cap the queue by serialized bytes, not count: fetch due cards with a bounded query in due order (today FlashcardDAO.swift:66-74 fetches every due card), add cards until the payload reaches 48 KB, and truncate any single card's text at 2 KB with a "continue on iPhone" marker. Send the total due count separately. The Watch shows "12 of 40 due on Watch" when partial, asks for the next page when it empties, and says "All done" only when the total due count is 0 (today WatchReviewView.swift:61-65 says all done whenever its local list is empty). Always include the queue in application contexts, and omit it only from replies and ticks (WatchSyncManager.swift:170-175). Acceptance: a test with 200 cards of 3 KB each produces a payload ≤48 KB, a correct total count, and a second page on request. The signpost is WatchContextBuild.
- **B-8.6** *bookmark-artwork-offmain-bounded*, *artwork-off-main*: decode off-main with CGImageSource downsampling and a 16 MB bounded cache. Decoding happens only when the artwork key changes (BookmarkArtworkCoordinator.swift:111), not per tick. Keep the #542 baseWatchThumbnailData lifecycle.
- **B-8.7** *image-cache-sizing*: make ReaderImageLoader a real LRU (a hit at :16 never reorders) and size images to the cell. Changing the blur backdrop needs Dan to look at it.
- **B-8.8** *insights-single-scan-budget*: one segments read per load. Budget: StatsLoad ≤150 ms p95 at 20k segment rows, and a parity test.
- **B-8.9** *abs-cover-cache-downsample*: in-memory NSCache only, cleared on sign-out, because the code deliberately does not cache account-scoped covers on disk (AudiobookshelfService.swift:209-210).
- **B-8.10** *audio-graph-cpu-measure* (S): decide whether `pitch = 0.01` (AudioEngine.swift:169) or its "old workaround" comment (:436-443) is wrong, after a listening check.
- **B-8.11** *mac-reader-and-feed-signposts* (S): the Mac reader already shares `ReaderPlaybackSnapshot` and its indexes with iOS (Shared/Services/ReaderPlaybackSnapshot.swift:5-15, MacReaderFeedView.swift:79), so no further sharing is funded here. What remains is measurement: add the Reader.open and Reader.edit signposts to the Mac reader, a per-word-update signpost on both platforms (*feed-word-rate-update-cost*), and stateless first-run funnel events (*first-run-funnel-signposts*, no identifiers, nothing leaves the device). Acceptance: the Mac rows of the measurement table can be recorded. Any Mac reader refactor waits for those numbers.

## C. Hardened workflows

**C-1 · G2 FeedbackPresenter · One feedback policy · 1.0-gate · S (critic-added; not value-checked)**
The repo makes exactly one VoiceOver announcement (RootTabView.swift:789). The capture items each invent their own feedback.
Proposal: add a concrete `FeedbackPresenter(result, context: screenOn/screenOff/remote/CarPlay)` that chooses between haptic, earcon, announcement and capsule, with thin Watch and Mac adapters. Its input is a `CaptureResult` with four cases: `.acknowledged` (input received, nothing saved yet), `.committed` (durable SQL write), `.queued` (durable outbox entry, will send later) and `.failed(reason)`. Only `.committed` and `.queued` play a success cue, and they sound different. In the "Continue Without Saving" mode the database is in memory (EchoCoreApp.swift:99-102, DatabaseService.swift:149-156), so nothing can be `.committed`: capture controls stay usable but every capture returns `.failed(.notSaving)`, spoken as "Not saved: Echo is running without storage". It ships before its consumers (C-5, C-8, C-9, C-10).
Acceptance: a table test maps every result × context pair to its cue, no context maps `.acknowledged` to the success cue, and a capture in the in-memory mode returns `.failed(.notSaving)`.

**C-2 · ios-periodic-resume-checkpoint · Resume survives jetsam · 1.0-gate · S**
On iOS, progress is saved only on pause, load or switch, and background (PlaybackController.swift:338; PlayerLoadingCoordinator.swift:89, :800; RootTabView.swift:712). The tick never saves (PlayerModel+PlaybackControllerDelegate.swift:8-22). The Mac calls a throttled save from its tick, at most every 5 s (MacPlayerModel.swift:256, :1335-1356). On iOS the save writes defaults plus a manifest (Persistence.swift:186-194), and manifest errors are swallowed (PlaylistManifestService.swift:22-25).
Proposal: a pure `ResumeCheckpointPolicy` that checkpoints every 15 s of wall time *or* every 15 s of media time, whichever comes first (so 3x speed saves every 5 s), after a jump of more than 5 s, and on chapter change. Each checkpoint is an immutable value (book id, track, offset, sequence number). One serial writer applies them in order, drops any with a lower sequence than the last written for that book, and also serializes the other manifest writers (PlaylistManifestService.swift:105-164). A failed write is logged, retried on the next checkpoint, and surfaced after 3 failures in a row.
Budget: the loss is measured from the last *durable commit*, not from the last trigger. Triggering every 15 s leaves room for the ResumeCheckpoint commit budget (≤250 ms) inside a 20 media-second bound, so the guarantee is at most 20 media-seconds lost at every speed preset while storage works. If storage keeps failing, the bound no longer holds and the user is told after 3 failures (above). Under 1 ms on main per checkpoint (signpost ResumeCheckpoint). Tests: every speed preset, a stale checkpoint arriving after a newer one, termination during a write (the previous checkpoint survives), and a delayed writer terminated just after a trigger (loss stays within 20 media-seconds). The persistence call gains a completion result so the policy knows when a commit happened (today Persistence.swift:186-194 returns nothing). `simctl terminate` is one verification case; jetsam on a device is a C-13 row.

**C-3 · abs-progress-push-durable · ABS push actually sends · 1.0-gate · M**
`pause()` sets `isPlaying = false` (PlaybackController.swift:319) before the non-forced push, and `shouldPush` then refuses (ABSProgressSync.swift:13). So a pause never pushes to ABS. Pushes use `try?` with no retry (PlayerModel+Audiobookshelf.swift:237-240), and the background push has no background task (PlayerModel.swift:1418).
Several servers can be configured (PlayerModel+Audiobookshelf.swift:25-28, :146-183), and each push captures an item and fires an independent request (:220-240).
Proposal: (C-3a) force the push on pause, after C-4a's guard is in place. (C-3b) Persist the latest pending position per server, account and remote item, each with a monotonic sequence number; a response for an older sequence never clears a newer pending record. Writes for one server, account and item go through one serial sender that coalesces to the newest pending position, so an older position is never sent after a newer one. After an uncertain outcome (timeout, lost connection) the sender re-sends the newest pending position, which converges because each write is a full position. Run the throttled push from C-2's checkpoint and retry pending records on the next checkpoint or launch. Wrap the background push in `beginBackgroundTask`. If the server reports newer progress (by its timestamp) than the pending record, C-4's reconciler decides; pending records for an account are discarded on sign-out.
Acceptance: with stubbed failures, the final server position equals the last local checkpoint, tested with two books, two servers, a delayed older response arriving after a newer one, retries failing then succeeding, and a stub server that records the order it applied writes (it must end at the newest position). A device check against the ABS web UI. Status UI is in C-12 (*sync-health-single-surface*).

**C-4 · container-move-resume-ids · Resume survives container moves · 1.0-gate · M**
`Track.id` is the absolute URL (Track.swift:6). Track restore matches IDs exactly and falls back to index 0 (PlayerLoadingCoordinator.swift:662-674, PlayerModel.swift:1068). ContainerPathRepair never touches the manifest or the progress keys. The reconciler can return `.pushLocal` when the local position is 0 (ABSProgressReconciler.swift:20-29), which would overwrite the good copy on the server.
Separately, `reconcileABSProgressOnLoad()` captures an item and timestamp, awaits the server, then seeks the *current* player without checking that the same book is still loaded (PlayerModel+Audiobookshelf.swift:246-265).
Proposal: (C-4a, S, first) two guards. Trust is checked at the one place every push passes through, the enqueue in front of C-3b's sender, so it covers the reconciler, pause (PlayerModel.swift:1231-1237) and the forced push on book switch (:1485-1487): a position is pushed only when restoration has completed and the position is trusted (restored from a checkpoint, or chosen by the user, including a deliberate restart at 0); an untrusted 0 from an incomplete restore never pushes. Before applying either branch, the load path checks that book, server and load generation still match. (C-4b, M) match tracks by folder-relative path, and rebase the manifest and progress keys during ContainerPathRepair.
Acceptance: C-4a tests: incomplete restore at 0 (no push), pause and book switch during an incomplete restore (no push), deliberate restart at 0 (push), no remote progress, newer remote progress, and a response for book A delivered after book B loaded (B's position and server state unchanged). C-4b: an old-UUID manifest restores the saved offset.

**C-5 · Capture path: CaptureCoordinator + truthful feedback + real text · 1.0-gate · M**
Five call sites discard `MarkPassageResult`: PlayerControlBar.swift:120, TransportControlsView.swift:261, TransportControlsView+LongPress.swift:75, ExperimentalControlLayer.swift:339 and the CarPlay observer at PlayerModel.swift:1364. The three on-screen buttons play `Haptic.light` whatever the outcome; the long-press path and the CarPlay observer give no feedback at all. The Watch gets no commandResult (WatchCommandRouter.swift:153-154). The snippet is only "Chapter: X" or a timestamp (PlayerModel+MarkedPassages.swift:45-51).
Bookmark creation schedules asynchronous persistence whose non-deferred errors only log and return (BookmarkStore.swift:420-458), so a synchronous return does not mean the bookmark is saved. Capture passes `audioEngine.currentTime`, a track-local time, with only a book id (PlayerModel+MarkedPassages.swift:23-34), and MarkedPassageRecord.swift:7-16 stores no track or segment.
Proposal: (C-5a) one concrete `CaptureCoordinator.markPassage()/addBookmark()`. It emits `.acknowledged` at once, then `.committed` when the SQL write finishes or `.failed` if it throws, through C-1. It returns `markPassageSaved` or `markPassageFailed` to the Watch. A source test confirms no view calls `markPassageAtCurrentTime` directly. (C-5b) one coordinate contract for capture, text resolution, card playback and export: every new capture stores a stable track identity (the book-relative track path) plus the track-local offset, with a coordinate version. Track index and book-absolute time are derived from the current ordering, never stored as identity, because tracks can be reordered (PlaylistManager.swift:105-116). Existing rows keep coordinate version 1 with an unknown track. They are converted only when other data establishes the track (a single-track book, or a linked bookmark that stores it); otherwise the UI shows them as "position approximate" and does not seek or resolve text from an assumed track. Storing the track needs an additive migration, numbered in landing order, with its own upgrade test (C-10.16). (C-5c) a `PassageTextResolver` in Shared, off-main: word_timing first, then the overlapping epub_block, then the chapter title. Mac aligned books already get word timings (MacAlignmentService.swift:172-179), so the epub_block fallback is for unaligned books. C-5c is 1.1 if 1.0 is tight.
Acceptance: write-failure and terminate-before-commit tests show no success cue. Two tracks with the same local timestamp each resolve to their own passage, before and after a reorder, a relaunch and a container move. Migration tests cover a legacy single-track row (converted), a legacy multi-track row (left approximate) and an already-converted row (unchanged).
Budget: Capture.ack ≤50 ms from tap; Capture.result ≤500 ms from tap.
Merges: mark-passage-truthful-feedback, inbox-capture-real-text, and the capture parts of one-tap-capture and single-action-dispatcher.

**C-6 · Add-to-Library and first pick · 1.0-gate · M**
Every pick runs `registerLibraryRoot` and then `loadFolder` with autoplay on (RootTabView.swift:473-479, PlayerModel.swift:1485). So adding a folder stops the current audio, and root-registration errors are only logged (:1535-1551). A parent-folder pick sets `folderURL` with no tracks (PlayerLoadingCoordinator.swift:130-131, :184-190), and the listened-only shelf (LibraryViewModel.swift:33) stays empty, with circular empty-state copy (LibraryView.swift:266-267).
Proposal: "Add to Library" uses `FolderPicker(.folder)` and the existing `vm.addRoot` (LibraryViewModel.swift:227-238, currently Mac-only), and never touches playback. A container pick never calls loadFolder. Announce "Found 12 books in Audiobooks". Add a collapsed, lazily loaded "Ready to start (N)" row, and leave the listened-only main shelf unchanged.
Acceptance: Add leaves `folderURL` and `isPlaying` unchanged. A 3-subfolder root shows Ready (3), and playing one moves it to the shelf. Update Wedge3ClarityOnRampTests.swift:15, :76 and NowPlayingLayoutTests.swift:213.
Merges: split-add-to-library-from-open-book, container-folder-first-pick-dead-end, ready-to-start-shelf-section, one-verb-per-add-intent (labels).

**C-7 · align-survives-tab-switch · Alignment survives leaving the Reader · 1.0-gate · M**
`tearDownReader` cancels the run (ReaderTab.swift:504, :765). The pipeline deletes the previous automatic anchors before any new work (AutoAlignmentService.swift:139-146). Failure paths return without throwing, so the success haptic fires (:126-133, :196-199). The sheet can be swiped away, and it shows the raw log (AutoAlignmentProgressView.swift:44-106).
Proposal: move task ownership to PlayerModel. Swap anchors atomically at the end of the run, inside AutoAlignmentService rather than by changing the DAO's meaning. Throw on failure. Add a persistent "Aligning… chapter N of M" chip, Retry on failure, and put the log behind Details.
Acceptance: a run cancelled after Tier 0 leaves the previous anchors and word_timing rows identical by id, time and source (a content comparison, not a count). A source test confirms tearDownReader does not reference the task.

**C-8 · CarPlay mic: hide for 1.0, finish in 1.x · 1.0-gate (hide, S) / later (workflow, M)**
`carPlayVoiceMemoRecorder` is assigned at PlayerModel.swift:2094 and never read or stopped. The comment at :2073-2076 promises a save path that does not exist. The button image never changes (CarPlayManager.swift:69-74). The CarPlay entitlement is commented out (EchoCore.entitlements:9-16), and ROADMAP.md:103 defers "CarPlay capture buttons" to 1.x.
Proposal: (C-8a, 1.0) remove the mic button from the CarPlay template so a future entitlement cannot ship a recorder that never stops. (C-8b, later, with the 1.x capture buttons) a toggle with a 2-minute cap; disconnect or interruption stops it; stopping saves through the voice_memo path, links the memo to a new bookmark, resumes playback and plays an earcon; if microphone permission was denied, keep the bookmark and say so.
Acceptance: C-8a: a source test confirms the CarPlay template has no mic button. C-8b: two taps produce 1 bookmark and 1 memo, the session category is `.playback` again, and a disconnect still saves.
Merges: carplay-voice-memo-dead-end.

**C-9 · Watch capture correctness · 1.0-gate · S + M**
(1) *watch-voice-memo-file-race*: the delegate hops to a `Task` before copying the file (WatchSyncManager.swift:325-330), and WatchConnectivity deletes the file when the delegate returns. A failed copy only logs (WatchCommandRouter.swift:228-233). Fix: before the delegate returns, synchronously write an envelope (capture UUID, command, book and position metadata from `file.metadata`, WatchCommandRouter.swift:212-220, :236-239) next to the moved file in an App Group inbox, using a write-then-rename so a half-written envelope is never read as complete. Drain the inbox on launch and after each delivery; an orphaned file or envelope is kept and retried, never discarded. Tests: delete the source right after the move, and terminate after staging but before the drain (the capture is recovered on relaunch).
(2) *watch-bookmark-timebase*: the Watch sends book-absolute time (WatchViewModel.swift:1367-1373, PlayerModel+WatchState.swift:36), and the phone stores it as a per-track offset (PlayerModel+Bookmarks.swift:261-277). Fix: send the live `addBookmark` when reachable. When queued, send `bookTime` and convert it on the phone. Test: 3,700 s maps to track 2 at 100 s.
(3) *watch-honest-capture-feedback*: Quick Bookmark plays `.success` even after a failure (PlayerPage.swift:841-845). The haptic setting is false until the first sync (WatchViewModel.swift:232-235). markPassage is not deferred-safe (WatchCommandRouter.swift:192-194). The Watch already sends a `bookmarkID` (WatchViewModel.swift:1367-1372), but the phone builds a new `Bookmark` without it (PlayerModel+Bookmarks.swift:254-282), so a redelivered capture becomes a duplicate. Fix, as a receipt contract: every capture carries one UUID from the Watch to SQL. The phone inserts by that UUID (insert-or-ignore), reusing the existing staging and SQL merge (:284-330), and replies with a receipt only after the SQL commit. The Watch keeps the capture, and any memo file, in its outbox until that receipt arrives, then deletes it. A duplicate delivery of the same UUID, metadata or file, converges on one row and gets the same receipt. The Watch shows "Saved on Watch" (`.queued`) until the receipt and "Saved" (`.committed`) after it; failure is always signalled, and the haptic default is true.
Tests: duplicate delivery, relaunch of either device between send and receipt, and a book switch on the phone between capture and delivery.
(4) *watch-review-index-skip*: `currentIndex += 1` after the card is removed skips every other card (WatchReviewView.swift:75-85, WatchViewModel.swift:930). Fix: track the card by id and always show `dueCards.first`. Each grade gets a UUID and stays pending on the Watch until the phone replies with a receipt after the SQL commit (today the phone only logs a failed grade, PlayerModel.swift:827-840). An incoming queue (WatchViewModel.swift:893-897) never re-shows a card with a pending grade, and a duplicate grade UUID is applied once. Tests: a page arriving before a grade's receipt, a failed grade (the card returns with a notice), a duplicate delivery and a relaunch with a pending grade. The review tab disappears when the queue empties (ContentView.swift:129), so acceptance is presenter-level (each card shown exactly once) plus a defined landing page.
(5) *watch-skip-grades-checkpoint*: Watch skips bypass `consumeRemoteSkipAsCheckpointGrade` (WatchCommandRouter.swift:82-93 vs PlayerModel.swift:1975-1993). Add it to the facade protocol, with a router test.
(6) *watch-sync-status-surface*: a no-book state, a hidden-by-default stale/unreachable line, and "Saved on Watch, will send later", all from one `WatchLinkStatus`.
Merges: watch-capture-receipts.

**C-10 · Dead ends in routes and states · 1.0-gate · S each**
- **C-10.1** *deep-link-dead-ends*: `echoaudio://<host>/chapter/N` pushes a placeholder (NavigationDestinations.swift:37-38, :47-60). Make it seek to the chapter. `settings` opens Appearance instead of the Settings sheet (PlayerModel.swift:1650-1652). `navigateToBookmark` only switches tabs (:1662-1664).
- **C-10.2** *abs-open-dismisses-all-sheets*: nothing ever sets `showingSettings = false`, so "Open in Echo" leaves Settings on screen. Add a root "dismiss modals" request.
- **C-10.3** *library-load-error-state*: a load failure shows the first-run empty state and an alert titled "Couldn't open book" (LibraryViewModel.swift:78-83, LibraryView.swift:132-136). Add a LoadState with Try Again, on both platforms.
- **C-10.4** *reader-loading-error-recovery*: a nil DB leaves "Loading EPUB..." on screen forever (ReaderTab.swift:960-961, :542-548). Add a ReaderLoadState and fix the named silent sites (:292, :628-630, :653-655, :1112-1117; ReaderTab+Alignment.swift:55-59, :565-613). Every capture announces through C-1.
- **C-10.5** *alignment-banner-predicate*: `hasUserAlignmentAnchors` uses `source != 'auto'` (ReaderFeedViewModel.swift:1047-1055), but no source is named `auto` (AlignmentAnchorRecord.swift:47-55), so it treats automatic and synthesized anchors as user anchors. Use `humanAnchorSources`. Derive the estimated-alignment banner separately, from the timeline's estimated state, because having no human anchors does not mean the alignment shown is estimated. Tests: no anchors, machine-only, human-only and mixed.
- **C-10.6** *transcription-false-done*: failed chapters still advance the count (StandaloneTranscriptionService.swift:57-65, :247-252). Add `failedChapterIndices`, "Retry failed chapters" and a visible finalize error.
- **C-10.7** *import-deferred-retry*: `DatabaseWorkDeferred` has no LocalizedError (DatabaseWorkProtection.swift:6). Show a specific message with Retry and Cancel, and keep the staged copy.
- **C-10.8** *narration-partial-failure-retry*: NarrationStatusView has no action (:15-60). Add "Try again" / "Stop generating" through NarrationResumeResolver, engine-agnostic so it works with Phonon.
- **C-10.9** *launch-state-recovery*: rename the button to "Continue Without Saving", add a persistent banner and a 2 s explanatory spinner (EchoCoreApp.swift:75-78, :99-106). Retry relaunches the open.
- **C-10.10** *macos-async-db-open* (part a): the Mac Release fallback to an in-memory DB shows an error instead.
- **C-10.11** *mac-quit-resume-and-pause-highlight* (M): `applicationShouldTerminate` returns `.terminateNow` (Echo_macOSApp.swift:562-564), and AppKit gives no time for async work after `applicationWillTerminate`. Write the resume checkpoint and the pending ABS record (C-3b) synchronously, then return `.terminateLater`, attempt the ABS push, and call `reply(toApplicationShouldTerminate: true)` on success, failure or a 1 s deadline, whichever comes first. Unsent progress stays in the pending record for the next launch. Separately, keep `currentBlockID` when paused (MacReaderFeedView.swift:503-507). Acceptance: a test that the reply always fires within the deadline, and a relaunch after quit restores the position.
- **C-10.12** *mac-dead-menu-commands*: ⌘F has no receiver. ⌘N and ⇧⌘E are dead while Notes is hidden (MacReaderNotesSplit.swift:44-48). Open Notes before acting, alert on export errors (MacNotesPane.swift:52), and remove or disable Find. (C-10.12b, 1.1) migrate the menu commands to FocusedValue.
- **C-10.13** *mac-mark-passage-parity*: both Mac paths write a point timestamp with `try?` (Echo_macOSApp.swift:335-345, MacTriPaneView.swift:510-520). Route them through MarkedPassageCapture and C-1 (S-M).
- **C-10.14** *mac-batch-off-main* (narrowed): stage failures already surface `errorMessage` (MacBatchQueueView.swift:183). Add Retry for failed rows. (C-10.14b, 1.1) the off-main refactor, after #421.
- **C-10.15** *G1 StoragePreflight* (critic-added; not value-checked): there are 0 free-space checks. ABS: before download, require the item's reported size plus its estimated extracted size plus 10% headroom; before extraction, recheck with the archive's actual size plus the declared uncompressed total the extractor already sums (ABSImportService.swift:45, :69-76, :226-234). If the size is unknown, start, and stop cleanly at a low-space floor (500 MB). On failure, delete partial output, keep the archive if it fits, and offer Retry. Narration: before each chapter, require the chapter's word count × a measured bytes-per-word for the voice (recorded in the B-1 baseline) plus 10%. Acceptance: stubbed volume-capacity tests for each branch.
- **C-10.16** *G4 V44→V45 upgrade test* (critic-added): run against a shipped-shape DB plus a defaults snapshot.

**C-11 · siri-bookmark-dead-on-watch · Truthful Siri claims · 1.0-gate · S**
CreateBookmarkIntent needs `currentTrackTime`, and only the iPhone writes it (WidgetStatePublisher.swift:90), so on Watch it always throws. Bookmarks drained into `bookmarks_*` never leave the Watch.
Proposal: route it through C-9's durable path, or remove the shortcut and fix user-manual.md:120, with its assertion, in the same PR.

**C-12 · Further workflow items · mixed tags**
- **C-12.1** *siri-capture-intents* (1.1, M+): an iOS AppShortcutsProvider with Mark passage, Bookmark, Skip back, Sleep 15 and Resume, all going through CaptureCoordinator (C-5a) and speaking a short result ("Saved", "Saved, will sync", "Couldn't save"). These are Siri phrases, reachable through AirPods' Siri; they do not change what headphone play/pause or double-press do, which stay remote transport commands. StartReview comes after A-1, and CheckpointGrade after C-9(5) and C-12.2. Keep them out of the macOS and echo-cli targets by target membership, not `#if os`. Don't clash with the Watch phrase (AppIntent.swift:80). If Siri is off or the intent is denied, the phone's next foreground shows nothing lost because nothing was captured; the manual says so. Budget: a spoken mark lands within 2 s while the phone is pocketed (device check).
- **C-12.2** *checkpoint-countdown-survives-suspension* (**1.0-gate**, M): the checkpoint pauses playback (PlayerModel+StudyCheckpoint.swift:38) and pause ends the background task (PlaybackController.swift:318-329), so a countdown cannot run while the phone is locked and suspended. A persisted deadline alone only fixes the state on the next wake (StudyCheckpointCoordinator.swift:240-253). Requirement: on a locked phone, with no tap, the no-tap auto-Again happens within a few seconds of the window ending. The spec chooses the mechanism; candidates are keeping the audio session alive through the window (a quiet prompt or earcon loop) or a scheduled local notification whose expiry is applied on the next wake. The existing interruption rule stays: `suspendCountdown()` freezes the remaining time during a call (:215-225), so a long call never auto-grades. On a grade failure, restore or defer and play a spoken cue (:145-170). Acceptance: a locked-phone device check without a debugger, an eviction-during-window test (the grade is applied once on relaunch), and a long-call test (no grade). Edit the Wedge 1 "Chapter Study Mode" line (ROADMAP.md:43) only after the device check.
- **C-12.3** *remote-skip-interval-stale* (1.1, S): `preferredIntervals` is set once (NowPlayingController.swift:50-62). Add `updateSkipIntervals`, driven by a SettingsManager `didSet`, shared with the Mac. Acceptance: changing the skip setting updates the lock-screen buttons without relaunch.
- **C-12.4** *abs-download-survives-navigation* phase 1 (1.1, M): an app-owned coordinator and a Library progress card. Closing the sheet keeps the download running (ABSBrowseView.swift:62). Acceptance: close the sheet mid-download and the file still lands.
- **C-12.5** *open-in-document-types* and *mac-open-paths* part 2 (1.1, M): Viewer-role document types at Alternate rank, file-URL routing, and Mac drop handling. Acceptance: opening an .epub from Files or Finder imports it.
- **C-12.6** *ios-resumable-job-queue* phase 1 (1.1, M): an "interrupted job" marker and a Resume banner, reusing the existing `batch_queue` (Schema_V20.swift:7, Schema_V21.swift:4-10). No migration unless columns are missing. Acceptance: kill during alignment, relaunch, and the banner resumes it.
- **C-12.7** *watch-hands-free-entry-points* (1.1, S): Watch onOpenURL, retire the dead toggle path, and add an Inbox complication.
- **C-12.8** *app-scoped-launch-coordinator-carplay* (1.1, S): an observer on `databaseService`, so CarPlay works when the phone UI never launched.
- **C-12.9** *sync-health-single-surface* (1.1, M): one status line for article iCloud (`waitForUser`) and pending ABS records (C-3b), with the next action for each.
- **C-12.10** *mac-help-and-empty-state-parity* (**1.0-gate**, S): HelpContent membership on the Mac app only, with SettingsManager injected.

**C-13 · no-lost-progress-verification-matrix · 1.0-gate · M**
docs/qa/no-lost-progress-matrix.md lists call, route change, terminate, container move, offline ABS, unreachable Watch and Mac quit, each with a maximum loss. Back it with tests, a simctl terminate script run through xcode-build-slot, and a per-promotion device checklist.
Acceptance: ≤20 media-seconds lost for every playback row (C-2's bound) and 0 lost captures for every capture row. The ROADMAP Wedge 2 "No-lost-progress guarantee" line (ROADMAP.md:58) is ticked only when every row passes.

## D. CI and release hardening

- **D-1 · train-require-ci-green-on-sha · 1.1 (highest-value CI item) · S.** plan() never reads check-runs (release_delivery.py:209-243). Require the "Build gate + tests" check to have succeeded on `source_sha`, treat cancelled as not green, and accept docs-only. Keep the train's build-for-testing step, because it guards against runner Xcode skew (release-trains.yml:150-161). Acceptance: fake-api tests for success, failure and missing.
- **D-2 · ui-launch-smoke-gate · 1.0-gate · M.** Delete the template UI tests and add EchoSmokeUITests (launch, open, play, background/resume). There is no committed audio fixture (`*.m4b` is gitignored), so add a generated tone first. Assert the persisted position, not wall time. Run it on nightly first, and make it PR-blocking after 20 consecutive green runs.
- **D-3 · perf-budget-nightly-lane · 1.0-gate · M.** A separate scheduled workflow on the `Echo Perf` configuration: XCTApplicationLaunchMetric for launch, XCTOSSignpostMetric for the signpost intervals and scroll hitches, and the Hangs instrument for hangs. Warn on regressions over 20% across 5 iterations. Absolute numbers are on-device targets.
- **D-4 · ci-split-parallel-jobs · 1.1 · M.** Add timeouts now. Split into contracts (ubuntu), ios and mac jobs under one aggregator named "Build gate + tests". Keep renderer-install-test on macOS (store.py:42, :255, :274). The repo is public, so the cost is runner concurrency, not minutes.
- **D-5 · ci-cover-orphan-suites · 1.1 · S.** Add doc-automation, pronunciation-pack, audit-pack and the stdlib-only neural-g2p tests to CI. Add a doc_contracts test that every `*-test` target is either wired or explicitly excluded.
- **D-6 · release-receipt-script · 1.1 · M.** Write a receipt block to the step summary. A missing Mac receipt produces `::error`, not a red run, until a Mac .pkg ships (Fastfile:405-418), and only when the plan called for a Mac build.
- **D-7 · pin-resolved-packages · 1.1 · S.** Add `-onlyUsePackageVersionsFromResolvedFile` at release-trains.yml:222 and to the gym xcargs. Measure the warning count from a fresh xcresult; the CODE_AUDIT §3.4 baseline is stale.
- **D-8 · G5 rename-sweep checklist · 1.0-gate · S (critic-added).** Add to the PR template: grep EchoTests (Wedge3ClarityOnRamp, SettingsExtraction, the 31 Mac source-scan files, the doc tests) before renaming any UI string.

## Slices

Each slice is a PR series, not one PR. Slices group work by area; ordering comes from the item-level "Needs" column in the Item map, not from whole slices finishing. Slices 1 and 2 can start at once. Every PR that adds a migration takes the next free number when it lands, never edits V1-V44, and ships an upgrade test from the previous shipped version (C-10.16).

1. **No lost progress (recommended first).** Value: it closes the most serious open risk in the 1.0 gate (ROADMAP.md:58) without any design decision. Order inside the slice:
   1. C-13a *spec*: write docs/qa/no-lost-progress-matrix.md with the maximum loss per row, so each later PR names the row it fixes.
   2. C-4a reconciler guards (trusted position, book/server/load-generation check). Must land before anything pushes more often.
   3. C-2 resume checkpoint (serial writer, media-time bound).
   4. C-3a force push on pause, then C-3b per-item pending records and the background task.
   5. C-9(1) Watch voice-memo file race.
   6. C-10.10 Mac in-memory fallback becomes an error (S), and C-10.11 Mac quit through `.terminateLater` (M, estimated separately).
   7. C-4b track matching by relative path and manifest rebase (M).
   8. B-7.3's progress-freshness bug fix (Watch and App Group positions on long chapters).
   9. C-13b *verification*: run the matrix and tick the No-lost-progress line only when every row passes. Its prerequisites are the 1.0 items in its Item map row (including C-5a and C-9(3) from slice 3), not the whole of slice 3; 1.1 work never blocks it.
   The ResumeCheckpoint signpost and budget arrive with slice 2; until then the checkpoint is covered by its unit tests only.
2. **Foundations.** B-1 signposts, measurement table, fixtures and MetricKit; C-1 FeedbackPresenter and `CaptureResult`; D-8. Must land before slices 3-6 measure or announce anything.
3. **Capture path.** C-5a, C-5b, C-9(2) timebase, then C-9(3) receipts and outbox, C-9(4-6), C-10.13 Mac Mark Passage, C-11, C-8a. Then, in 1.1, C-5c real text, A-15.1 one-tap capture, A-15.13 inbox triage and, once A-1 (slice 5) has landed, C-12.1 Siri intents. The 1.0 part needs slice 2.
4. **Reader.** A-2, which includes the banner rewrite (before A-10 and C-10.5), C-7, B-3, A-5, A-4a, B-4, C-10.4, B-2's reader half; in 1.1, A-4b and B-7. Needs slice 2. Coordinate every AlignmentService edit with #421.
5. **Library, study and first run.** A-1a (before any new study entry point), then A-1, C-6, C-10.1-C-10.3, A-8, C-12.2, A-14, A-10, A-9, A-11, A-12, C-12.10, A-16; in 1.1, C-12.4, C-12.5, C-12.9, A-13, A-15.7, A-15.8, Ready-to-start polish and G3. A-14 needs C-5a from slice 3; the rest needs only slice 2 where its row says so.
6. **Player and settings dedupe.** A-3, A-6, A-7, B-2's player half, B-5, C-10.6-C-10.9, C-10.12, C-10.14, C-10.15; in 1.1, A-15.2-A-15.6, A-15.9-A-15.12, A-15.14, B-6, B-8, C-12.3, C-12.6-C-12.8, C-10.12b and C-10.14b. Needs slice 2.
7. **CI and release.** D-2 and D-3 (1.0); D-1, D-4 to D-7 (1.1). Only D-3 depends on other work (B-1's signposts and fixtures). D-1 does not need D-4.

### Item map

| Item | Tag | Slice | Needs |
|---|---|---|---|
| A-1a checkpoint load race | 1.0-gate | 5 | — |
| A-1 study hub | 1.0-gate | 5 | A-1a |
| A-2 visible actions, menu, reset | 1.0-gate | 4 | B-1 |
| A-3 player menu fixes / defaults | 1.0-gate (defaults: Q1) | 6 | — |
| A-4a bookmark and card filters | 1.0-gate | 4 | — |
| A-4b one Show menu | 1.1 | 4 | A-4a |
| A-5 tappable capture rows | 1.0-gate | 4 | C-1 |
| A-6 experimental-layout trap | 1.0-gate | 6 | — |
| A-7 Focus in Playback Options | 1.0-gate | 6 | — |
| A-8 FSRS-true Insights | 1.0-gate | 5 | — |
| A-9 reader empty-state reasons | 1.0-gate | 5 | — |
| A-10 Help accuracy | 1.0-gate (index/links 1.1) | 5 | A-2 |
| A-11 Watch no-book state | 1.0-gate | 5 | — |
| A-12 Mac reader empty state | 1.0-gate (drop/Finder 1.1) | 5 | — |
| A-13 two verbs | 1.1 | 5 | C-6 |
| A-14 Getting started card | 1.0-gate | 5 | C-6, C-5a, A-1 |
| A-15.1 one-tap capture | 1.1 | 3 | C-5a, Q2 |
| A-15.2 single action dispatcher | 1.1 | 6 | — |
| A-15.3-A-15.6 settings and player disclosure | 1.1 | 6 | A-3 |
| A-15.7 study plan one-tap start | 1.1 | 5 | A-1 |
| A-15.8 study notes actions | 1.1 | 5 | Q4 |
| A-15.9 Pro purchase surface | 1.1 | 6 | — |
| A-15.10 narration section | 1.1 | 6 | Phonon trial report |
| A-15.11-A-15.12 menu and settings cleanup | 1.1 | 6 | — |
| A-15.13 inbox triage | 1.1 | 3 | C-5c |
| A-15.14 Mac controls, menu bar, Study window, Watch review and player code | 1.1 | 6 | A-16, C-9(4) |
| A-16 Mac study parity | 1.0-gate | 5 | A-8 |
| B-1 signposts and measurement | 1.0-gate | 2 | — |
| B-2 tick isolation | 1.0-gate | 4 (reader), 6 (player) | B-1 |
| B-3 alignment edits off main | 1.0-gate | 4 | B-1, C-7 |
| B-4 PDF open off main | 1.0-gate | 4 | B-1 |
| B-5 shelf regroup once | 1.0-gate | 6 | B-1 |
| B-6.1 no session activation on restore | 1.1 | 6 | B-1 |
| B-6.2 restore selection off main | 1.1, only if Launch.RestoreSelection misses | 6 | B-1 baseline |
| B-6.3 Mac DB open off App.init | 1.1 | 6 | C-10.10 |
| B-7.1 karaoke word clock | 1.1 | 4 | B-2, #421 |
| B-7.2 boundary-precise scheduling | 1.1 | 6 | B-1 |
| B-7.3 progress publication freshness (bug) | 1.0-gate | 1 | — |
| B-7.3 coalescing, B-7.4 narration fan-out | 1.1 | 4 | B-2 |
| B-7.5 reader VM cache | 1.1, only if ReaderTabSwitch misses | 4 | B-1 baseline |
| B-8.1-B-8.3 narration residency, memory gate, thermal | 1.1 | 6 | B-1, Phonon trial report |
| B-8.4 playback_event index migration | 1.1 | 6 | C-10.16 |
| B-8.5 Watch payload budget | 1.1 | 6 | C-9(4) grade receipts |
| B-8.6-B-8.10 artwork, images, Insights, ABS covers, audio graph | 1.1 | 6 | B-1 |
| B-8.11 Mac reader and feed signposts | 1.1 | 6 | B-1 |
| C-1 FeedbackPresenter | 1.0-gate | 2 | — |
| C-2 resume checkpoint | 1.0-gate | 1 | C-4a |
| C-3a force push on pause | 1.0-gate | 1 | C-4a |
| C-3b per-item pending ABS records | 1.0-gate | 1 | C-2 |
| C-4a reconciler guards | 1.0-gate | 1 | — |
| C-4b path-relative track match | 1.0-gate | 1 | C-4a |
| C-5a CaptureCoordinator | 1.0-gate | 3 | C-1 |
| C-5b capture coordinates | 1.0-gate | 3 | C-5a |
| C-5c passage text | 1.1 | 3 | C-5b |
| C-6 Add to Library | 1.0-gate | 5 | — |
| C-7 alignment job ownership | 1.0-gate | 4 | — |
| C-8a hide CarPlay mic | 1.0-gate | 3 | — |
| C-8b CarPlay recording | later | — | ROADMAP 1.x capture buttons |
| C-9(1) Watch file race | 1.0-gate | 1 | — |
| C-9(2) bookmark timebase | 1.0-gate | 3 | — |
| C-9(3) receipts and outbox | 1.0-gate | 3 | C-1, C-9(2) |
| C-9(4) review skip | 1.0-gate | 3 | — |
| C-9(5) skip grades | 1.0-gate | 3 | — |
| C-9(6) Watch link status | 1.0-gate | 3 | C-9(3) |
| C-10.1-C-10.3 routes, sheets, library errors | 1.0-gate | 5 | — |
| C-10.4 reader load errors | 1.0-gate | 4 | C-1 |
| C-10.5 alignment banner predicate | 1.0-gate | 4 | A-2 |
| C-10.6-C-10.9 transcription, import, narration, launch recovery | 1.0-gate | 6 | — |
| C-10.10 Mac in-memory fallback | 1.0-gate | 1 | — |
| C-10.11 Mac quit | 1.0-gate | 1 | C-2, C-3b |
| C-10.12 Mac dead menu commands | 1.0-gate | 6 | — |
| C-10.12b FocusedValue commands | 1.1 | 6 | C-10.12 |
| C-10.13 Mac Mark Passage | 1.0-gate | 3 | C-5a |
| C-10.14 Mac batch retry | 1.0-gate | 6 | — |
| C-10.14b Mac batch off main | 1.1 | 6 | #421 |
| C-10.15 storage preflight | 1.0-gate | 6 | B-1 baseline (narration bytes per word) |
| C-10.16 migration upgrade test | 1.0-gate | with each migration | — |
| C-11 Siri bookmark on Watch | 1.0-gate | 3 | C-9(3) |
| C-12.1 Siri capture intents | 1.1 | 3 (after A-1 lands) | C-5a, A-1; CheckpointGrade also C-9(5), C-12.2 |
| C-12.2 checkpoint countdown | 1.0-gate | 5 | A-1a |
| C-12.3 remote skip intervals | 1.1 | 6 | — |
| C-12.4 ABS download survives navigation | 1.1 | 5 | C-10.15 |
| C-12.5 open-in document types | 1.1 | 5 | C-6 |
| C-12.6 resumable job queue | 1.1 | 6 | C-7 |
| C-12.7 Watch entry points | 1.1 | 6 | A-11 |
| C-12.8 CarPlay launch coordinator | 1.1 | 6 | — |
| C-12.9 sync health surface | 1.1 | 5 | C-3b |
| C-12.10 Mac Help parity | 1.0-gate | 5 | A-10 |
| C-13a no-lost-progress matrix spec | 1.0-gate | 1 | — |
| C-13b matrix verification | 1.0-gate | 1 (closes last) | C-2, C-3a, C-3b, C-4a, C-4b, C-9(1), C-9(3), C-5a, C-10.11, B-7.3 (callback fix) |
| D-1, D-4-D-7 | 1.1 | 7 | — |
| D-2 UI launch smoke | 1.0-gate | 7 | — |
| D-3 nightly perf lane | 1.0-gate | 7 | B-1 |
| D-8 rename-sweep checklist | 1.0-gate | 2 | — |

## Out of scope / dropped

- **audio-first-checkpoint-quiz** (later): L effort, audio-session risk, and depends on the checkpoint countdown fix.
- **container-repair-steady-state-skip** (later): a premature optimisation until Launch.ContainerRepair is measured. The comment about the first launch after a move describes the UPDATE, not the scan.
- **scoped-word-rematerialize** (later): high risk to read-along correctness. Revisit only if B-3 misses its budget, and only after #421.
- **mac-batch-engine-reuse** (later): ONNX prepare takes about 0.7 s per book. Measure Mac against CLI first, after Phonon and #421.
- **full-study-backup-restore** (later): needs a decision memo on scope and Pro gating. Bookmarks are already authoritative in SQL after reconciliation (BookmarkStore.swift:341-387; the comment at Persistence.swift:8-18 is stale), but playback progress and settings still live in defaults.
- **watch-pomodoro-wrist-down-alarm** (later): the Watch timer is a foreground timer (WatchViewModel.swift:1404-1415) and the only background mode is audio (Echo Watch App/Info.plist:24-27). A wrist-down alarm needs its own design (a scheduled local notification or an extended runtime session) before it can be planned.
- **automate-backmerge** (later): a maintainer chore. A main→weekly PR would skip the ladder.
- **tick-delegate-bookmark-scan**: microseconds of cost. The tick signpost will show whether it matters.
- Struck sub-proposals: the net −200-line metric; an "every property has a reader" lint; making the DEBUG in-memory DB opt-in; a Settings Diagnostics UI; per-chapter word windowing; a Help build-time generator; a warning-count ratchet script; a "Keep downloading?" dialog; auto-retrying imports on didBecomeActive; `isIdleTimerDisabled` for imports and alignment (the phone is locked in a pocket on the route); a CADisplayLink for karaoke in the first version; the Watch settings performance half.

## Open questions for Dan

1. **Default transport row.** Should fresh installs get `[section back, skip back, play, skip forward, section forward]` in place of the deliberate empty slots from d8c77fee? Saved layouts would not change.
2. **One-tap bookmark.** Should a bookmark save on the first tap, with Edit and Undo in a capsule, replacing the draft sheet the transport slot opens today?
3. **Study hub.** Is it acceptable to replace "Stats" with "Study" in the More menu, with Insights moving inside the hub?
4. **Settings root.** Should the per-book override sections that sit inline in Settings today become a single "This book's settings" row? (Moving Focus Tools into Playback Options is A-7 and needs no decision unless you object.)
5. **Experimental player.** Keep it parked and opt-in for v1.1, with only the trap fixed, or schedule it to graduate?
6. **Sample book.** Should Echo bundle a short public-domain sample (audio plus text) so a new user can finish the Getting started card (A-14) without their own files? The June audit's "Recommended Next Order" lists a Try Sample path; it is unscheduled until you decide.
7. **Paragraph action bar.** Should the visible action bar (A-2) sit on the paragraph being spoken all the time, or appear only on a paragraph after you tap it?
