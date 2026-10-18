# UI Cleanup — Single Overflow Menu, Reader Chrome, Watch Editor, Library Editions, Front Matter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the five UI problems surfaced in the 2026-07-05 screenshot review: (A) two competing "more" ellipsis menus, (B) top-bar clutter that steals reader vertical space, (C) the Watch settings editor's redundant/broken "Available Actions" palette, (D) duplicate library cards for the audio and text editions of the same book, and (E) EPUB front matter inflating the chapter list.

**Architecture:** All iOS work in `EchoCore` + `Shared`. The app already has exactly one top header (`UnifiedTopHeader`, overlaid by `RootTabView` on every tab) and one bottom utility row (`BottomToolbarView` inside the root-owned `UnifiedBottomDock`), so consolidation means *moving menu items down* into `PlayerMoreMenu` and *deleting the top ellipsis*, not building new chrome. Library dedupe is presentation-level grouping (new nullable `edition_group_id` on `audiobook`, migration **V35**), not a data merge. Front matter is a parser/navigation fix, grouped behind failing tests first.

**Tech Stack:** SwiftUI, `@Observable` `PlayerModel`, GRDB (`DatabaseService` migration chain), Swift Testing (`make test-only FILTER=EchoTests/<Suite>`).

## Global Constraints

- **Branch/PR:** work in a worktree cut from `origin/nightly`; PR targets `nightly` (`gh pr create --base nightly`). Never push `main`/`weekly`/`nightly` directly. Conventional Commits.
- **Builds:** `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>` per loop. Builds are gated by `~/.claude/bin/xcode-build-gate.sh` — prefix long builds with `"$HOME/.claude/bin/xcode-build-gate.sh" --wait &&`. Never enable uncapped parallel testing.
- **CI ordering trap:** hosted CI runs iOS tests → macOS build → echo-cli build; `make build-tests` is iOS-only. Any new `EchoCore` file must copy the **target membership of its sibling files** (e.g. `EditionMatcher.swift` mirrors `LibraryService.swift`). `Shared/` files join all targets including watchOS — keep them UIKit-free.
- **Migration number:** next free slot is **V35** (`v34_study_auto_export` is taken). Before committing, re-verify with `ls Shared/Database/Migrations | sort -V | tail -1` and `grep registerMigration Shared/Database/DatabaseService.swift` — parallel branches have collided before (V27, V33). Mirror the file shape of `Schema_V34.swift`, register after `v34_*`, add `EchoTests/SchemaV35Tests.swift` modeled on the latest `SchemaV3xTests`.
- **SwiftFormat PostToolUse hook** reflows entire files on edit; verify `// SPDX-License-Identifier: GPL-3.0-or-later` stays **line 1** of every touched Swift file.
- **Localization:** match file conventions — user-facing strings via `String(localized:)` / string literals in `Label`, as the surrounding code does.
- **Known-flaky:** iOS-sim Keychain tests (ABSTokenStore/auth-refresh) are environmentally flaky under `CODE_SIGNING_ALLOWED=NO`; unrelated failures there are not caused by this work.
- **SwiftLint** must be clean before each commit.

## Out of Scope (deliberate)

- **True edition merge** (attaching EPUB text blocks to the audio book's record) — that is the alignment/import flow; Track D only groups cards visually.
- **macOS chrome parity** — `UnifiedTopHeader`/`BottomToolbarView` are iOS-only; macOS has separate chrome. Track C's `Shared/WatchAction.swift` change compiles for watchOS and is parity-safe.
- **Reimplementing watch drag-and-drop** — the palette is removed, not fixed (owner decision 2026-07-05).
- **Re-import migration for existing books' front matter** — E fixes classification for future imports; existing books re-classify on next re-import/re-scan only.
- Tab-bar redesign, filter-chip redesign, Liquid Glass adoption — untouched.

## Track Map (independent tracks; tasks within a track are sequential)

| Track | Deliverable | Files (primary) |
|-------|-------------|-----------------|
| A | One overflow menu (bottom); top ellipsis deleted; sleep-timer submenu deduped | `PlayerMoreMenu.swift`, `UnifiedTopHeader.swift`, `RootTabView.swift`, `UnifiedBottomDock.swift`, `BottomToolbarView.swift` |
| B | Folder chip library-only; pill trailing; reader chrome auto-hides; "None" labels gone; mini-player title de-noised | `UnifiedTopHeader.swift`, `RootTabView.swift`, `ReaderTab.swift`, `PlayerModel.swift`, `ReaderFeedCollectionView.swift`, `PlayerControlBar.swift`, `Shared/String+TrackPrefix.swift` |
| C | Watch editor: palette + dead drag removed; localized action names everywhere | `WatchAppSettingsView.swift`, `Shared/WatchAction.swift` |
| D | One library card per book: album-tag titles, EPUB cover backfill, V35 edition grouping | `LibraryScanner.swift`, `LibraryService.swift`, `EditionMatcher.swift` (new), `Schema_V35.swift` (new), `AudiobookDAO.swift`, `LibraryCoverCell.swift`, `LibraryViewModel.swift` |
| E | Front matter = one chapter group in nav and counts | `EPUBBlockParser.swift`, `EPUBStructureChaptering.swift`, `PlaybackController.swift`, `ReaderFeedDisplayBuilder.swift` |
| F | Doc sync + changelog | `ARCHITECTURE.md`, `CHANGELOG.md` |

Recommended order: A → B (visible wins, shared files), then C, D, E in any order, F last.

---

## Track A — Single Overflow Menu

**Why (HIG):** two ellipsis affordances on one screen violate Consistency — the user cannot predict which menu holds what. The bottom menu survives because it sits in the thumb zone next to the transport controls it relates to; the top-right slot becomes the sleep-timer status pill (Track B). The sleep-timer submenu inside `PlayerMoreMenu` also duplicates the pill ("the single timer home", audit B1) and is removed.

### Task A1: Move app-level actions into `PlayerMoreMenu`, delete the top ellipsis

**Files:**
- Modify: `EchoCore/Views/PlayerMoreMenu.swift` (whole body)
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift:27-40, 42-125`
- Modify: `EchoCore/Views/RootTabView.swift:265-280` (header call) and the `UnifiedBottomDock(...)` call (~line 288)
- Modify: `EchoCore/Views/Components/UnifiedBottomDock.swift` (thread new closures)
- Modify: `EchoCore/Views/BottomToolbarView.swift` (thread new closures into `PlayerMoreMenu`)

**Interfaces:**
- Produces: `PlayerMoreMenu(onShowChapters:onShowBookmarks:onStats:onFidget:onSettings:onHelp:onAddDocument:onExport:onStudyNotesExport:)` — the last three are `(() -> Void)?` and hidden when `nil`.
- Produces: `UnifiedTopHeader(onFolderTap:)` — single closure; all other params deleted.

- [ ] **Step 1: Find every construction site**

Run: `grep -rn "PlayerMoreMenu(\|UnifiedTopHeader(\|UnifiedBottomDock(\|BottomToolbarView(" EchoCore/ --include="*.swift"`
Record each call site; all must compile after the signature changes. (`UnifiedBottomDock` is root-owned — expect one dock site in `RootTabView` plus pass-throughs.)

- [ ] **Step 2: Rewrite `PlayerMoreMenu` body**

Replace the menu content (keep the sheet-ownership pattern — closures only, no `.sheet` here):

```swift
struct PlayerMoreMenu: View {
    @Environment(PlayerModel.self) private var model

    /// Present the chapter-navigation picker (parent owns the sheet binding).
    var onShowChapters: () -> Void
    /// Reveal the bookmarks list (parent switches tab).
    var onShowBookmarks: () -> Void
    // App-level actions relocated from the deleted UnifiedTopHeader ellipsis
    // menu (2026-07-05 chrome consolidation): one overflow menu for the app.
    var onStats: () -> Void
    var onFidget: () -> Void
    var onSettings: () -> Void
    var onHelp: () -> Void
    /// `nil` when no book is loaded or narration is rendering (item hidden).
    var onAddDocument: (() -> Void)?
    var onExport: (() -> Void)?
    var onStudyNotesExport: (() -> Void)?

    var body: some View {
        Menu {
            // Playback context
            Button(action: onShowChapters) {
                Label("Chapters", systemImage: "list.bullet.indent")
            }
            .disabled(model.chapters.count < 2)
            Button(action: onShowBookmarks) {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .disabled(model.tracks.isEmpty)

            Divider()

            // Current book
            if let onAddDocument {
                Button(action: onAddDocument) {
                    Label(
                        model.hasEPUB || model.hasPDF
                            ? "Replace Document…" : "Add Document…",
                        systemImage: "book.pages"
                    )
                }
            }
            if let onExport {
                Button(action: onExport) {
                    Label("Export Audiobook (.m4b)…", systemImage: "square.and.arrow.up")
                }
            }
            if let onStudyNotesExport {
                Button(action: onStudyNotesExport) {
                    Label("Export Study Notes…", systemImage: "doc.text")
                }
            }

            Divider()

            // App level
            Button(action: onStats) {
                Label("Stats", systemImage: "chart.bar.fill")
            }
            Button(action: onFidget) {
                Label("Fidget", systemImage: "circle.hexagongrid.fill")
            }
            .disabled(model.tracks.isEmpty)
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            Button(action: onHelp) {
                Label("Help", systemImage: "questionmark.circle")
            }
        } label: {
            chip
        }
        .accessibilityLabel(Text("More options"))
    }

    private var chip: some View {
        Image(systemName: "ellipsis.circle.fill")
            .font(.title2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .foregroundStyle(model.resolvedThemeTint ?? .accentColor)
    }
}
```

Notes: the Sleep Timer submenu is **deleted** (Task A2 rationale — the pill is the single timer home), so `isActive` and the active chip fill go too. Update the file's doc comment: it now hosts playback **and** app-level actions.

- [ ] **Step 3: Slim `UnifiedTopHeader`**

Delete every closure except `onFolderTap`, and the whole trailing `Menu`. New body `HStack`: folder button, `Spacer()`, `SleepTimerPill()` (trailing position — Track B gating lands in Task B1; after this step the pill simply sits trailing on all tabs):

```swift
let onFolderTap: () -> Void

var body: some View {
    VStack(spacing: 0) {
        HStack {
            Button(action: onFolderTap) {
                Image(systemName: "folder")
                    .font(.title3.bold())
                    .frame(width: Self.chipDiameter, height: Self.chipDiameter)
                    .background {
                        Circle()
                            .fill(chipFill)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    }
            }
            .foregroundStyle(model.resolvedThemeTint ?? Color.accentColor)
            .accessibilityLabel(Text("Open book or folder"))

            Spacer()

            SleepTimerPill()
        }
        .padding(.horizontal, 16)
        .padding(.top, Self.rowOneVerticalPadding)
        .padding(.bottom, Self.rowOneVerticalPadding)
    }
    .background(headerBackground)
}
```

Keep `chipDiameter` / `rowOneVerticalPadding` / `rowOneHeight` untouched — every tab reserves `rowOneHeight` of clearance and the file's own comment documents the 2026-06-20 clipping regression from letting that drift.

Check `onBookSettingsTap`: it is passed in today but if nothing in the body references it, delete the parameter and its `RootTabView` argument (the sheet state stays; other entry points may use it — `grep -rn showingBookSettings EchoCore/`).

- [ ] **Step 4: Rewire `RootTabView`**

Header call shrinks to `UnifiedTopHeader(onFolderTap: { showingFolderPicker = true })`. Move the seven other closures onto the dock call, keeping the exact same guard expressions:

```swift
UnifiedBottomDock(
    onCreateBookmark: { draft in newBookmarkDraft = draft },
    onShowPlaybackOptions: { showingPlaybackOptions = true },
    onShowChapters: { showingChapterPicker = true },
    onShowBookmarks: { model.selectedTab = .read },
    onStats: { showingStats = true },
    onFidget: { showingFidget = true },
    onSettings: { showingSettings = true },
    onHelp: { model.showingHelp = true },
    onAddDocument: (model.folderURL != nil && !model.narrationPlaybackState.isRunning)
        ? { model.showingDocumentImporter = true } : nil,
    onExport: (model.folderURL != nil && !model.narrationPlaybackState.isRunning)
        ? { showingExport = true } : nil,
    onStudyNotesExport: (model.folderURL != nil && !model.narrationPlaybackState.isRunning)
        ? { showingStudyNotesExport = true } : nil
)
```

Thread the new parameters through `UnifiedBottomDock` → `BottomToolbarView` → `PlayerMoreMenu` following how `onShowChapters`/`onShowBookmarks` flow today. All sheet bindings stay on `RootTabView`.

- [ ] **Step 5: Build + run smoke check**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`
Expected: build succeeds. Then `make test` (full suite) — no regressions beyond the known-flaky Keychain suites.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(chrome): consolidate app actions into single bottom overflow menu"
```

### Task A2: Guard test for the consolidated menu decision

**Files:**
- Test: `EchoTests/ChromeConsolidationTests.swift` (new)

The menus are SwiftUI `Menu` bodies (UI tests are excluded from the scheme), so lock the *decision* with a source-shape guard the way `TabSelectionTests` locked the de-tabbing:

- [ ] **Step 1: Write the test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ChromeConsolidationTests {
    // The 2026-07-05 chrome consolidation: UnifiedTopHeader carries only the
    // folder chip + SleepTimerPill; the sole overflow menu lives in
    // PlayerMoreMenu. If UnifiedTopHeader ever grows a Menu again, or
    // PlayerMoreMenu loses the app-level closures, these fail at compile time.
    @Test @MainActor func topHeaderHasOnlyFolderClosure() {
        _ = UnifiedTopHeader(onFolderTap: {})  // compiles ⇢ single-closure signature holds
    }

    @Test @MainActor func playerMoreMenuCarriesAppLevelActions() {
        _ = PlayerMoreMenu(
            onShowChapters: {}, onShowBookmarks: {},
            onStats: {}, onFidget: {}, onSettings: {}, onHelp: {},
            onAddDocument: nil, onExport: nil, onStudyNotesExport: nil)
    }
}
```

- [ ] **Step 2: Run it**

Run: `make test-only FILTER=EchoTests/ChromeConsolidationTests`
Expected: PASS (it compiles against the Task A1 signatures; if A1 regressed, this fails to build).

- [ ] **Step 3: Commit**

```bash
git add EchoTests/ChromeConsolidationTests.swift
git commit -m "test(chrome): lock single-overflow-menu signatures"
```

---

## Track B — Top-Bar Slimming & Reader Vertical Space

**Why (HIG):** the folder chip is an *import* affordance — it belongs where content is managed (Library), not floating over reading or playback (Deference: chrome must not compete with content). The sleep pill is status+control; trailing placement matches the "actions trailing" convention. On the reader, the search/filter rows already collapse on scroll — extending the collapse to the whole top row gives near-full-bleed reading.

### Task B1: Folder chip on Library tab only

**Files:**
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift` (body from Task A1)

- [ ] **Step 1: Gate the folder button on the library tab**

The header already reads `model.selectedTab` (chip fill). Wrap the button:

```swift
HStack {
    if model.selectedTab == .library {
        Button(action: onFolderTap) { /* unchanged folder chip */ }
            .foregroundStyle(model.resolvedThemeTint ?? Color.accentColor)
            .accessibilityLabel(Text("Open book or folder"))
            .transition(.opacity)
    }

    Spacer()

    SleepTimerPill()
}
.animation(.easeInOut(duration: 0.2), value: model.selectedTab)
```

`TabSelection` cases are `.nowPlaying / .read / .library` (`Shared/TabSelection.swift`). Layout stays stable because the pill is trailing and the leading side collapses to the `Spacer()`.

- [ ] **Step 2: Build, run in sim, verify**

Folder chip: Library ✓, Listen ✗, Read ✗. Sleep pill trailing on all three.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/Components/UnifiedTopHeader.swift
git commit -m "feat(chrome): folder chip only on Library; sleep pill trailing"
```

### Task B2: Auto-hide the top header while reading

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (add one UI-state var — place near `selectedTab`)
- Modify: `EchoCore/Views/ReaderTab.swift:18, ~267, ~386` (publish the existing collapse state)
- Modify: `EchoCore/Views/RootTabView.swift:265` (react to it)

**Interfaces:**
- Produces: `PlayerModel.readerChromeHidden: Bool` (default `false`).

- [ ] **Step 1: Add the state**

```swift
// PlayerModel.swift — UI chrome state, near selectedTab
/// Reader-driven: true while the Read tab has scrolled its collapsible
/// header away, so the root can hide the top chrome with it.
var readerChromeHidden = false
```

- [ ] **Step 2: Publish from `ReaderTab`**

`ReaderTab` already owns `@State private var isHeaderVisible` (line 18) gating the search/filter rows (line 267). Mirror it outward wherever the reader's root view is declared:

```swift
.onChange(of: isHeaderVisible) { _, visible in
    model.readerChromeHidden = !visible
}
.onDisappear { model.readerChromeHidden = false }
```

- [ ] **Step 3: React in `RootTabView`**

```swift
UnifiedTopHeader(onFolderTap: { showingFolderPicker = true })
    .opacity(topChromeHidden ? 0 : 1)
    .offset(y: topChromeHidden ? -UnifiedTopHeader.rowOneHeight : 0)
    .allowsHitTesting(!topChromeHidden)
    .animation(.easeInOut(duration: 0.25), value: topChromeHidden)
```

```swift
private var topChromeHidden: Bool {
    model.selectedTab == .read && model.readerChromeHidden
}
```

Do **not** change the reader's `rowOneHeight` clearance reservation — content flows under the hidden header while scrolled, and the reservation still protects the resting position (see the 2026-06-20 regression note in `UnifiedTopHeader`).

- [ ] **Step 4: Verify in sim**

Read tab: scroll down → search row, filter row, *and* the pill row slide away (chapter bar stays); scroll up → all return. Switching to Listen/Library always shows the header.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(reader): hide top chrome with the collapsing reader header"
```

### Task B3: Drop the "None" alignment labels

**Files:**
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift:173`

- [ ] **Step 1: Pass nil instead of "None"**

```swift
let timeString = audioStartTimeByBlockID[blockID].map {
    Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
}
```

(`?? "None"` deleted.) `ParagraphCardCell.setManuallyAligned(_:timeString:)` already hides the label for `nil` (`hasAnchorText = (timeString != nil)`). Follow `timeString` through the rest of the closure — any other consumer expecting non-nil gets the same optional.

- [ ] **Step 2: Build + verify**

Reader: unaligned blocks show no time label; aligned blocks unchanged (red anchored / grey interpolated).

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/ReaderFeedCollectionView.swift
git commit -m "fix(reader): hide time label on unaligned blocks instead of 'None'"
```

### Task B4: De-noise mini-player chapter titles ("06 - Chapter 6" → "Chapter 6")

**Files:**
- Create: `Shared/String+TrackPrefix.swift`
- Modify: `EchoCore/Views/Components/PlayerControlBar.swift:152-160`
- Test: `EchoTests/StringTrackPrefixTests.swift`

**Interfaces:**
- Produces: `String.strippingTrackNumberPrefix() -> String`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct StringTrackPrefixTests {
    @Test func stripsNumberDashPrefix() {
        #expect("06 - Chapter 6".strippingTrackNumberPrefix() == "Chapter 6")
        #expect("6. Chapter 6".strippingTrackNumberPrefix() == "Chapter 6")
        #expect("012 – Intro".strippingTrackNumberPrefix() == "Intro")
    }

    @Test func leavesNonTrackTitlesAlone() {
        #expect("1984".strippingTrackNumberPrefix() == "1984")           // 4 digits: not a track no.
        #expect("Chapter 6".strippingTrackNumberPrefix() == "Chapter 6")
        #expect("07".strippingTrackNumberPrefix() == "07")               // nothing after prefix
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests` → expect compile failure (method undefined). That is the failing state.

- [ ] **Step 3: Implement**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension String {
    /// Strips a leading track-number prefix like "06 - " / "6. " from
    /// per-track chapter titles, where the number is redundant next to the
    /// chapter name. 1–3 digits only, so year-titled works ("1984") survive;
    /// no-op when nothing follows the prefix.
    func strippingTrackNumberPrefix() -> String {
        let stripped = replacing(/^\d{1,3}\s*[-–—.]\s+/, with: "", maxReplacements: 1)
        return stripped.isEmpty ? self : stripped
    }
}
```

Note `\s+` after the separator — `"6.5 Special"` keeps its title.

- [ ] **Step 4: Apply in the mini player**

`PlayerControlBar.titleText`:

```swift
private var titleText: String {
    if model.chapters.count >= 2 {
        let subtitle = model.currentSubtitle.strippingTrackNumberPrefix()
        return subtitle.isEmpty
            ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)")
            : subtitle
    } else {
        return model.currentTitle
    }
}
```

Mini player only — the full player keeps the verbatim chapter title.

- [ ] **Step 5: Run tests, commit**

Run: `make build-tests && make test-only FILTER=EchoTests/StringTrackPrefixTests` → PASS.

```bash
git add Shared/String+TrackPrefix.swift EchoTests/StringTrackPrefixTests.swift EchoCore/Views/Components/PlayerControlBar.swift
git commit -m "feat(player): strip redundant track-number prefix in mini-player title"
```

---

## Track C — Watch Settings Editor

**Why:** the "Available Actions" palette duplicates the five slot pickers, displays raw enum values ("markPassage"), and its drag source sits in a `ScrollView` that swallows the gesture — a visible affordance that doesn't work is worse than none. Owner decision: remove it; pickers are the single editing path.

### Task C1: `WatchAction.displayName` (shared, localized)

**Files:**
- Modify: `Shared/WatchAction.swift` (append extension)
- Modify: `EchoCore/Views/WatchAppSettingsView.swift:232, 369-386` (delete `actionName`, use `displayName`)
- Test: `EchoTests/WatchActionDisplayNameTests.swift`

**Interfaces:**
- Produces: `WatchAction.displayName: String` (localized; covers `.empty` → "Empty").

- [ ] **Step 1: Failing test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct WatchActionDisplayNameTests {
    @Test func everyActionHasAHumanName() {
        for action in WatchAction.allCases {
            let name = action.displayName
            #expect(!name.isEmpty)
            // No raw camelCase leaking through (the old palette bug).
            #expect(name != action.rawValue || name.first!.isUppercase)
        }
    }

    @Test func knownNames() {
        #expect(WatchAction.markPassage.displayName == "Mark Passage")
        #expect(WatchAction.playPause.displayName == "Play / Pause")
        #expect(WatchAction.empty.displayName == "Empty")
    }
}
```

Run: `make build-tests` → compile failure (property undefined) = failing state.

- [ ] **Step 2: Implement**

Move the `switch` from `WatchAppSettingsView.actionName(_:)` (lines 369–386) verbatim into `Shared/WatchAction.swift`:

```swift
extension WatchAction {
    /// Localized human-readable name, shared by the iOS editor and any
    /// future watch surfaces. (Was WatchAppSettingsView.actionName.)
    var displayName: String {
        switch self {
        case .playPause: String(localized: "Play / Pause")
        case .skipForward: String(localized: "Skip Forward")
        case .skipBackward: String(localized: "Skip Back")
        case .nextTrack: String(localized: "Next Chapter")
        case .previousTrack: String(localized: "Previous Chapter")
        case .nextSection: String(localized: "Next Section")
        case .previousSection: String(localized: "Previous Section")
        case .loopMode: String(localized: "Loop Mode")
        case .speed: String(localized: "Speed")
        case .sleepTimer: String(localized: "Sleep Timer")
        case .bookmark: String(localized: "Bookmark")
        case .markPassage: String(localized: "Mark Passage")
        case .pomodoro: String(localized: "Pomodoro")
        case .empty: String(localized: "Empty")
        }
    }
}
```

Then in `WatchAppSettingsView`: delete `actionName(_:)`, replace its call sites with `.displayName`, and fix the preset caption (line ~232):

```swift
Text("P1: \(preset.page1.map(\.displayName).joined(separator: ", "))")
```

`Shared/WatchAction.swift` is in the watch target — the extension is Foundation-only, safe.

- [ ] **Step 3: Run tests, commit**

Run: `make build-tests && make test-only FILTER=EchoTests/WatchActionDisplayNameTests` → PASS.

```bash
git add Shared/WatchAction.swift EchoCore/Views/WatchAppSettingsView.swift EchoTests/WatchActionDisplayNameTests.swift
git commit -m "feat(watch): shared localized WatchAction.displayName"
```

### Task C2: Remove the "Available Actions" palette and drag machinery

**Files:**
- Modify: `EchoCore/Views/WatchAppSettingsView.swift` — delete `Section("Available Actions")` (~205-214), `PaletteItem` (~390-416), the `palette` property, the `.onDrop`/`isTargeted` block in `DropSlot` (~525-538) and any `.onDrag`, and update the caption (~195).

- [ ] **Step 1: Delete the section, struct, and drag plumbing**

- Remove the whole `Section("Available Actions") { ScrollView(.horizontal) { … PaletteItem … } }`.
- Remove `struct PaletteItem` and the `palette` array it iterated.
- In `DropSlot`: remove `.onDrop(of:isTargeted:)`, the `isTargeted` state, and any targeting visuals; keep the slot's tap/menu behavior and `.contentShape(Rectangle())`. If the struct ends up drop-free, rename `DropSlot` → `PreviewSlot` (single-purpose name) and update references.
- Caption: `"Choose actions for this page below, or drag actions into the watch preview."` → `"Choose actions for this page using the menus below."`
- Remove `import UniformTypeIdentifiers` if it was only for the drag payload (grep the file first).

- [ ] **Step 2: Build + verify in sim**

Watch App Settings shows: preview, caption, Slot 1–5 pickers, Presets. No palette. Pickers still save (`saveSlots()` path untouched) and presets still load.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/WatchAppSettingsView.swift
git commit -m "fix(watch): remove redundant non-functional Available Actions palette"
```

---

## Track D — One Library Card per Book

**Why:** the grid shows one row per scanned folder; the m4b/mp3 edition and the separately imported EPUB edition of the same book each get a card, one titled from the first *track's* title tag, the text one with a grey placeholder. Fix in three layers: better titles (album tag), covers for text editions (OPF lookup), and presentation-level grouping (V35).

### Task D1: Prefer the album tag for book titles

**Files:**
- Modify: `EchoCore/Services/Library/LibraryScanner.swift:70-91`
- Test: `EchoTests/LibraryTitleResolutionTests.swift`

**Interfaces:**
- Produces: `LibraryScanner.resolveBookTitle(album:track:fallback:) -> String` (pure, static).

- [ ] **Step 1: Failing test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct LibraryTitleResolutionTests {
    @Test func albumTagWinsOverTrackTitle() {
        #expect(LibraryScanner.resolveBookTitle(
            album: "The High-Conflict Couple",
            track: "01 - The High-Conflict Couple: Chapter 1",
            fallback: "Folder") == "The High-Conflict Couple")
    }

    @Test func fallsBackTrackThenFolder() {
        #expect(LibraryScanner.resolveBookTitle(album: nil, track: "Some Book", fallback: "F") == "Some Book")
        #expect(LibraryScanner.resolveBookTitle(album: "", track: "", fallback: "Folder Name") == "Folder Name")
    }
}
```

Run: `make build-tests` → compile failure = failing state.

- [ ] **Step 2: Implement**

```swift
// LibraryScanner.swift
/// Audiobook rips almost always carry the BOOK title in the album tag and
/// the per-file track name ("01 - … Chapter 1") in the title tag — prefer
/// album so multi-file folders don't get labeled by their first track.
static func resolveBookTitle(album: String?, track: String?, fallback: String) -> String {
    if let album, !album.isEmpty { return album }
    if let track, !track.isEmpty { return track }
    return fallback
}
```

In `readMetadata(for:)`:

```swift
let trackTitle = await stringValue(in: metadata, key: .commonKeyTitle)
let albumTitle = await stringValue(in: metadata, key: .commonKeyAlbumName)
// …
return ScannedMetadata(
    title: resolveBookTitle(
        album: albumTitle, track: trackTitle, fallback: fallbackTitle(for: book)),
    author: author, narrator: nil, duration: duration, coverImageData: cover)
```

Existing rows self-heal on the next rescan (`LibraryService.rescan()` re-coalesces `record.title`).

- [ ] **Step 3: Run tests, commit**

Run: `make test-only FILTER=EchoTests/LibraryTitleResolutionTests` → PASS.

```bash
git add EchoCore/Services/Library/LibraryScanner.swift EchoTests/LibraryTitleResolutionTests.swift
git commit -m "fix(library): title cards from album tag, not first track title"
```

### Task D2: Cover backfill for text-only/EPUB editions

**Files:**
- Investigate first; likely Modify: `EchoCore/Services/Library/LibraryService.swift` (rescan loop, ~lines 195-273) and the text-import finalizer (`DocumentImportFinalizer` / `TimelineIngestionService.persistAudiobook`).

- [ ] **Step 1: Locate the existing OPF cover extractor**

Run: `grep -rn "opf\|coverImage\|cover.*OPF\|extractCover" --include="*.swift" -il Shared/ EchoCore/Services/ | head`
The OPF-declared-cover lookup built for the narration m4b fix (PR #336, `HeadlessNarrationRunner` path) is the reference implementation — reuse that utility, do **not** write a second OPF parser. If it is embedded in the narration runner, extract the lookup into a shared helper (e.g. `Shared/EPUBCoverLocator.swift`) with the narration runner delegating to it.

- [ ] **Step 2: Wire two seams**

1. **Scanner path:** in `LibraryService.rescan()`, where `meta.coverImageData` is nil but the discovered book has `companionEPUB`, extract the OPF cover from that EPUB and feed it through the existing `writeCover(_:id:coversDir:)`.
2. **Text-import path:** where text-only imports create their `audiobook` row (follow `TimelineIngestionService.persistAudiobook` / `DocumentImportFinalizer`), populate `coverArtPath` the same way when the source EPUB declares a cover.

Both seams call one shared helper; PDFs and md/txt imports keep the placeholder.

- [ ] **Step 3: Test**

Unit-test the locator against a fixture EPUB if one exists in `EchoTests` fixtures (`grep -rn "\.epub" EchoTests/ | head`); otherwise test the seam logic (nil-cover + companion EPUB → helper invoked) with the locator injected as a closure. Manual check: import an EPUB with an OPF cover → card shows the cover after rescan.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(library): backfill card covers from EPUB OPF for text editions"
```

### Task D3: V35 migration + `EditionMatcher`

**Files:**
- Create: `Shared/Database/Migrations/Schema_V35.swift`
- Modify: `Shared/Database/DatabaseService.swift` (register after `v34_study_auto_export`, ~line 152)
- Modify: `Shared/Database/DAOs/AudiobookDAO.swift:49-88` (two new fields)
- Create: `EchoCore/Services/Library/EditionMatcher.swift`
- Test: `EchoTests/SchemaV35Tests.swift`, `EchoTests/EditionMatcherTests.swift`

**Interfaces:**
- Produces: `AudiobookRecord.editionGroupID: String?`, `AudiobookRecord.editionGroupOptOut: Bool`
- Produces: `EditionMatcher.normalizedKey(title:) -> String`, `EditionMatcher.groups(for: [EditionMatcher.Identity]) -> [String: String]` with `struct Identity { let id: String; let title: String; let author: String? }`

- [ ] **Step 1: Failing schema test**

Model `EchoTests/SchemaV35Tests.swift` on the newest `SchemaV3xTests` file (same in-memory `DatabaseService(inMemory:)` setup):

```swift
@Test func v35AddsEditionGroupColumns() throws {
    let db = try DatabaseService(inMemory: true)
    try db.read { db in
        let columns = try db.columns(in: "audiobook").map(\.name)
        #expect(columns.contains("edition_group_id"))
        #expect(columns.contains("edition_group_optout"))
    }
}
```

Run: `make test-only FILTER=EchoTests/SchemaV35Tests` → FAIL (no such columns).

- [ ] **Step 2: Migration (mirror `Schema_V34.swift` file shape)**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V35 — edition grouping for the library shelf. Groups the audio and text
/// editions of the same book onto one card. Nullable: ungrouped books have
/// their own card. `edition_group_optout` records a manual "Separate This
/// Edition" so rescans don't re-group it.
enum Schema_V35 {
    static func migrate(_ db: Database) throws {
        try db.alter(table: "audiobook") { t in
            t.add(column: "edition_group_id", .text)
            t.add(column: "edition_group_optout", .boolean).notNull().defaults(to: false)
        }
    }
}
```

Register in `DatabaseService` directly after `v34_study_auto_export`:

```swift
migrator.registerMigration("v35_edition_group") { db in
    try Schema_V35.migrate(db)
}
```

Add `editionGroupID: String?` / `editionGroupOptOut: Bool` to `AudiobookRecord` following exactly how `textOrigin` (V29) threads through Codable/column mapping. Run the schema test → PASS. **Never edit shipped V1–V34.**

- [ ] **Step 3: Failing matcher tests**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct EditionMatcherTests {
    private func identity(_ id: String, _ title: String, author: String? = nil) -> EditionMatcher.Identity {
        .init(id: id, title: title, author: author)
    }

    @Test func normalizedKeyStripsTrackAndChapterNoise() {
        #expect(EditionMatcher.normalizedKey(title: "01 - The High-Conflict Couple: Chapter 1")
            == EditionMatcher.normalizedKey(title: "The High-Conflict Couple"))
        #expect(EditionMatcher.normalizedKey(title: "The High-Conflict Couple (Unabridged)")
            == EditionMatcher.normalizedKey(title: "The High-Conflict Couple"))
    }

    @Test func groupsAudioAndTextEditions() {
        let groups = EditionMatcher.groups(for: [
            identity("a", "01 - The High-Conflict Couple: Chapter 1", author: "Alan E. Fruzzetti PhD"),
            identity("b", "The High-Conflict Couple"),
            identity("c", "The Long Route", author: "Dan Fakkeldy"),
        ])
        #expect(groups["a"] != nil)
        #expect(groups["a"] == groups["b"])   // same book, two editions
        #expect(groups["c"] == nil)            // singleton: no group id
    }

    @Test func differentAuthorsNeverGroup() {
        let groups = EditionMatcher.groups(for: [
            identity("a", "Collected Poems", author: "Frost"),
            identity("b", "Collected Poems", author: "Yeats"),
        ])
        #expect(groups["a"] == nil && groups["b"] == nil)
    }

    @Test func deterministicGroupID() {
        let books = [identity("z", "Book"), identity("a", "Book")]
        #expect(EditionMatcher.groups(for: books)["z"] == "a")  // min id wins
    }
}
```

Run → compile failure = failing state.

- [ ] **Step 4: Implement `EditionMatcher`**

New file `EchoCore/Services/Library/EditionMatcher.swift` (target membership mirrors `LibraryService.swift`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure edition-grouping logic for the library shelf: decides which
/// audiobook rows are editions of the same book (audio rip vs imported
/// EPUB). Presentation-level only — rows are never merged.
enum EditionMatcher {
    struct Identity {
        let id: String
        let title: String
        let author: String?
    }

    /// Canonical comparison key: lowercased, diacritic-folded, leading
    /// track numbers ("01 - ") and trailing chapter/part suffixes
    /// (": chapter 1", "- part 2") and edition qualifiers ("(unabridged)")
    /// stripped, punctuation removed, whitespace collapsed.
    static func normalizedKey(title: String) -> String {
        var key = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        key = key.replacing(/^\d{1,3}\s*[-–—.]\s+/, with: "", maxReplacements: 1)
        key = key.replacing(/[:\-–—,]?\s*(chapter|ch\.?|part|track|book)\s+\d+\s*$/, with: "")
        key = key.replacing(/\s*[(\[](unabridged|abridged|audiobook|ebook|epub)[)\]]\s*$/, with: "")
        key = key.replacing(/[^\p{L}\p{N}\s]/, with: "")
        key = key.replacing(/\s+/, with: " ")
        return key.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizedAuthor(_ author: String?) -> String? {
        guard let author, !author.isEmpty else { return nil }
        let key = author
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacing(/[^\p{L}\p{N}\s]/, with: "")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// Returns bookID → groupID for books that share an edition group.
    /// Singletons are absent from the result (their card is their own).
    /// Group ID = the lexicographically smallest member ID (deterministic
    /// across rescans). Authors must be equal or one side unknown.
    static func groups(for books: [Identity]) -> [String: String] {
        var byKey: [String: [Identity]] = [:]
        for book in books {
            let key = normalizedKey(title: book.title)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(book)
        }

        var result: [String: String] = [:]
        for members in byKey.values where members.count >= 2 {
            // Split by incompatible authors (known and different ⇒ apart).
            var buckets: [[Identity]] = []
            for member in members {
                let author = normalizedAuthor(member.author)
                if let index = buckets.firstIndex(where: { bucket in
                    bucket.allSatisfy { existing in
                        let other = normalizedAuthor(existing.author)
                        return author == nil || other == nil || author == other
                    }
                }) {
                    buckets[index].append(member)
                } else {
                    buckets.append([member])
                }
            }
            for bucket in buckets where bucket.count >= 2 {
                let groupID = bucket.map(\.id).min()!
                for member in bucket { result[member.id] = groupID }
            }
        }
        return result
    }
}
```

Run: `make test-only FILTER=EchoTests/EditionMatcherTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/Migrations/Schema_V35.swift Shared/Database/DatabaseService.swift Shared/Database/DAOs/AudiobookDAO.swift EchoCore/Services/Library/EditionMatcher.swift EchoTests/SchemaV35Tests.swift EchoTests/EditionMatcherTests.swift
git commit -m "feat(library): V35 edition grouping schema + pure EditionMatcher"
```

### Task D4: Apply grouping in `LibraryService` and the grid

**Files:**
- Modify: `EchoCore/Services/Library/LibraryService.swift` (rescan ~195-273; `sections(by:includeUnavailable:)` ~350-354; `books(includeUnavailable:)` ~338-346)
- Modify: `EchoCore/ViewModels/LibraryViewModel.swift`
- Modify: `EchoCore/Views/Library/LibraryCoverCell.swift`
- Test: `EchoTests/LibraryEditionGroupingTests.swift`

**Interfaces:**
- Produces: `LibraryService.regroupEditions()` (called at the end of `rescan()`); `LibraryService` section building collapses grouped rows to a representative.
- Produces: `LibraryViewModel.siblingEditions(of: AudiobookRecord) -> [AudiobookRecord]`, `LibraryViewModel.separateEdition(_ record: AudiobookRecord)`.

- [ ] **Step 1: Failing service test** (in-memory `DatabaseService`, insert two rows titled `"01 - X: Chapter 1"`/`"X"`, run `regroupEditions()`, assert both rows share `editionGroupID` and `sections(by: .recentlyAdded)` yields **one** card whose representative has the cover):

```swift
@Test func rescanGroupsEditionsAndSectionsCollapse() throws {
    // Arrange: two audiobook rows for the same book, one with a cover.
    // (Follow the insert pattern used by existing LibraryService tests.)
    // Act: service.regroupEditions()
    // Assert:
    //   - both records share editionGroupID
    //   - sections(by: .recentlyAdded).first!.books contains ONE entry for the pair
    //   - that entry is the one with coverArtPath != nil
}
```

Write it fully against the existing LibraryService test helpers (see `EchoTests` for the V27 library suites) — the comment lines above are the assertions to express, not placeholders to leave.

- [ ] **Step 2: Implement `regroupEditions()`**

At the end of `rescan()` (and callable on demand):

```swift
/// Recompute edition groups over all non-opted-out rows. Presentation-level:
/// only edition_group_id changes; opted-out rows keep NULL.
func regroupEditions() throws {
    try database.write { db in
        let records = try AudiobookRecord.fetchAll(db)
        let eligible = records.filter { !$0.editionGroupOptOut }
        let groups = EditionMatcher.groups(for: eligible.map {
            EditionMatcher.Identity(id: $0.id, title: $0.title, author: $0.author)
        })
        for var record in records {
            let newGroup = record.editionGroupOptOut ? nil : groups[record.id]
            if record.editionGroupID != newGroup {
                record.editionGroupID = newGroup
                try record.update(db)
            }
        }
    }
}
```

(Adjust fetch/update calls to the DAO conventions used in the file — `AudiobookDAO` may wrap raw GRDB.)

- [ ] **Step 3: Collapse groups when building sections**

In the section pipeline (before axis grouping), reduce each edition group to a representative:

```swift
/// One card per edition group. Representative preference: has cover art,
/// then has audio (longest duration), then stable by id.
private func collapsingEditionGroups(_ books: [AudiobookRecord]) -> [AudiobookRecord] {
    var seenGroups: Set<String> = []
    var representatives: [AudiobookRecord] = []
    let byGroup = Dictionary(grouping: books.filter { $0.editionGroupID != nil },
                             by: { $0.editionGroupID! })
    for book in books {
        guard let group = book.editionGroupID else {
            representatives.append(book)
            continue
        }
        guard !seenGroups.contains(group) else { continue }
        seenGroups.insert(group)
        let members = byGroup[group] ?? [book]
        let best = members.max { lhs, rhs in
            let lhsScore = (lhs.coverArtPath != nil ? 2 : 0) + (lhs.duration > 0 ? 1 : 0)
            let rhsScore = (rhs.coverArtPath != nil ? 2 : 0) + (rhs.duration > 0 ? 1 : 0)
            return lhsScore == rhsScore ? lhs.id > rhs.id : lhsScore < rhsScore
        }!
        representatives.append(best)
    }
    return representatives
}
```

Apply in `sections(by:includeUnavailable:)` for every axis (collapse **after** the availability filter, preserving `added_at` order). Field names (`duration`, `coverArtPath`, `author`) must match `AudiobookRecord` — verify against `AudiobookDAO.swift:49-88`.

- [ ] **Step 4: Context menu on the card**

`LibraryCoverCell` gains a context menu when siblings exist (thread `siblingEditions`/`separateEdition`/the existing open-book closure from `LibraryViewModel` through `LibraryShelfGrid`):

```swift
.contextMenu {
    ForEach(viewModel.siblingEditions(of: book), id: \.id) { sibling in
        Button {
            onSelect(sibling)
        } label: {
            Label("Open \(sibling.title)",
                  systemImage: sibling.duration > 0 ? "headphones" : "book.pages")
        }
    }
    if book.editionGroupID != nil {
        Divider()
        Button("Separate This Edition", systemImage: "rectangle.split.2x1") {
            viewModel.separateEdition(book)
        }
    }
}
```

`separateEdition` sets `editionGroupOptOut = true`, `editionGroupID = nil` on the record, persists, re-runs `regroupEditions()` (the remaining member may become a singleton), and reloads sections. `siblingEditions` returns the group's other members sorted by title.

- [ ] **Step 5: Run the suite + manual verify**

Run: `make test-only FILTER=EchoTests/LibraryEditionGroupingTests` → PASS, then full `make test`.
Manual: library shows ONE High-Conflict-Couple card (cover, clean title); long-press → other edition + Separate.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(library): one card per book — edition grouping with manual separate"
```

---

## Track E — Front Matter Is One Group, Not Five Chapters

**Why:** `EPUBBlockParser` already classifies front matter (OPF `linear="no"`, EPUB 3 `bodymatter` landmark, plus a heading heuristic) and the reader feed/TOC already group it. But (1) front-matter spines **with headings** (title page with an `<h1>`, copyright with a heading) escape the heuristic when the EPUB has no landmarks, and (2) chapter `< >` navigation and counts walk sections without consulting `isFrontMatter` — so five front-matter files read as five chapters.

### Task E1: Strengthen front-matter classification (tests first)

**Files:**
- Modify: `Shared/EPUBBlockParser.swift:173-219` (classification), `Shared/EPUBStructureChaptering.swift`
- Test: extend the existing EPUB parser test suite (locate with `grep -rln "EPUBBlockParser" EchoTests/`)

- [ ] **Step 1: Reproduce with failing tests**

Add cases to the existing parser suite: a landmark-free EPUB whose first spines are `titlepage.xhtml` ("The High-Conflict Couple" as `<h1>`), `copyright.xhtml` (heading + legal text), `dedication.xhtml`, followed by `chapter1.xhtml`. Assert all three pre-chapter spines yield `isFrontMatter == true`. Follow the suite's existing fixture-building pattern (in-memory XHTML strings or fixture files — match whichever the suite already uses).
Expected: FAIL today for the spines that carry headings.

- [ ] **Step 2: Add a title-keyword tier to the classification**

In `EPUBBlockParser` where `isFrontMatterSpine` is computed (lines ~177-182), add a third signal — a conservative keyword list applied only *before the first real content chapter*:

```swift
/// Spine/heading titles that are front matter even when the file carries a
/// heading (title pages and copyright pages usually do). Matched
/// case-insensitively against the spine's title before any content chapter.
/// Deliberately EXCLUDES foreword/preface/introduction — those are
/// listenable content and keep their own chapters.
private static let frontMatterTitleKeywords: Set<String> = [
    "title page", "titlepage", "copyright", "colophon", "dedication",
    "epigraph", "table of contents", "contents", "half title",
    "halftitle", "frontispiece", "about the author", "also by",
]
```

Fold into the decision: `titleMatchesFrontMatterKeyword && !hasSeenContentHeading` counts like `titleIsNonContent`. Also match the spine *filename stem* (`titlepage.xhtml`, `copyright.xhtml`) since many EPUBs have empty titles. Keep the existing structural signals first — landmarks always win in both directions (a `bodymatter`-marked spine is never keyword-demoted).

- [ ] **Step 3: Run tests**

Run: `make test-only FILTER=EchoTests/<parser suite>` → new cases PASS, all existing classification cases still PASS (the keyword tier must not flip any existing expectation — if one flips, the keyword list is too aggressive; shrink it).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "fix(epub): classify heading-bearing title/copyright pages as front matter"
```

### Task E2: Chapter navigation and counts treat front matter as one stop

**Files:**
- Investigate: `EchoCore/Services/PlaybackController.swift:530-578` (`nextSection`/`previousSectionOrRestart`), `EchoCore/Models/ReaderFeedDisplayBuilder.swift:81-82`, `EchoCore/ViewModels/ReaderFeedViewModel.swift:291-297`, `EchoCore/Services/EPUBImportService.swift:122-172` (chapter-index assignment)
- Test: same suites as the code touched

- [ ] **Step 1: Trace where the "5 chapters" surface**

For a **text/standalone** book, chapter indices come from `EPUBStructureChaptering.chapterIndices()`; blocks with `chapterIndex == nil` land in the `key < 0` "Front Matter" feed group. Verify after E1 that front-matter spines now get `nil` (not their own chapter index) in `EPUBImportService`'s no-audio path (lines 158-172). If `chapterIndices()` assigns them indices regardless of `isFrontMatter`, exclude flagged spines there — that alone removes them from the chapter count and the feed's per-chapter groups.

- [ ] **Step 2: Make `< >` section navigation cross front matter as one unit**

In `PlaybackController.nextSection()`/`previousSectionOrRestart()`, when the current or target section is front matter (`isFrontMatter` on its blocks / `chapterIndex < 0`), jump to the boundary of the whole front-matter run instead of stepping per-spine: from Chapter 1, one `<` lands on the top of Front Matter; one `>` from anywhere inside Front Matter lands on Chapter 1. Add a unit test at whatever seam the section list is computed (if the walk is over a section array, test the array construction: leading front-matter sections collapse to a single entry titled `"Front Matter"`).

- [ ] **Step 3: Acceptance criteria (manual, on the manual EPUB or High-Conflict Couple)**

- Chapter bar `< >`: from Chapter 1, exactly one back-step into "Front Matter", not five.
- Chapters sheet: one "Front Matter" group (already true via `TOCTreeBuilder`) — count labels anywhere ("N chapters") exclude front-matter spines.
- Reader feed: unchanged (already grouped).
- Audio-chaptered m4b books: navigation unchanged (audio chapters remain the source of truth there).

- [ ] **Step 4: Run affected suites + commit**

```bash
git add -A
git commit -m "fix(reader): front matter navigates and counts as one group"
```

---

## Track F — Docs & Changelog

### Task F1: Sync living docs

**Files:**
- Modify: `ARCHITECTURE.md` (schema table: add V35 `edition_group_id`/`edition_group_optout`; chrome section if it describes the dual-menu layout)
- Modify: `CHANGELOG.md` (user-facing: single More menu, reader full-bleed scroll, watch editor cleanup, one-card-per-book, front-matter grouping)

- [ ] **Step 1: Update both files** — match the existing entry style; check `docs/` for any screenshot-annotated guide that shows the old top ellipsis (`grep -rn "ellipsis\|More menu" docs/*.md | head`).
- [ ] **Step 2: Commit**

```bash
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs: sync architecture + changelog for chrome/library/front-matter cleanup"
```

---

## Final Verification (whole PR)

- [ ] `make test` green (modulo known-flaky Keychain suites — list any skips explicitly in the PR body).
- [ ] macOS + echo-cli targets build (CI runs them *after* tests; build locally if touching `Shared/`: the V35 migration and `WatchAction`/`String` extensions are the `Shared/` deltas).
- [ ] SwiftLint clean; SPDX still line 1 on every touched file.
- [ ] Manual sim pass: Listen / Read / Library tabs — one ellipsis total (bottom), folder only on Library, pill trailing, reader chrome hides on scroll, no "None" labels, watch editor has no palette, library shows one card per book with context-menu editions.
- [ ] PR to `nightly` with screenshots (before/after of the four screens), then `gh pr checks` until green.
