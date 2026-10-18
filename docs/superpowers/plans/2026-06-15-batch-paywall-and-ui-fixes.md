# Batch: Echo Pro Paywall + UI Quick-Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Knock out, in one sitting (while the `audit-phase7-api` PR is in flight), the Echo Pro paywall plus three queued UI fixes — Stats made escapable *and* given its own entry in the More menu, and the Fidget button moved into the More menu.

**Architecture:** This is an **umbrella batch** over two independent tracks. **Track A** (the Echo Pro paywall) is an existing, self-contained plan — executed as-is, referenced here, not duplicated (DRY). **Track B** (UI quick-fixes) is fully specified below: two small SwiftUI change-sets in `EchoCore` (iOS). The Stats change moves `StatsView` out of the cycling tab flow and presents it as a dismissable `.sheet` from the global ellipsis menu (`UnifiedTopHeader`), which fixes the "no way out" trap *by construction* (a sheet's own `NavigationStack` renders a Done button; the root view's `.toolbarVisibility(.hidden)` does not reach into a sheet). The Fidget change relocates its trigger from the bottom dock into the same menu.

**Tech Stack:** SwiftUI, `@Observable` `PlayerModel`, Swift Testing. UI tests are excluded from the Echo scheme (CLAUDE.md), so Track B's view-only edits are verified by **build + manual run**, anchored on one real guard test for the `TabSelection` enum shape.

---

## Scope & Tracks

| Track | What | Where | Independent? |
|-------|------|-------|--------------|
| **A** | Echo Pro paywall (freemium gating, StoreKit, `PaywallView`) | Echo Pro paywall plan (kept in the private strategy docs) | Yes — do in any order |
| **B** | UI quick-fixes: Stats escapable + in More menu; Fidget in More menu | this doc, `EchoCore/Views/*` | Yes — ~2 commits |

Do them in any order. Track B is the smaller, faster set — a reasonable warm-up before the meatier Track A. They touch disjoint files, so there are **no cross-track conflicts**.

> **Three requests → two tasks.** Your asks were: (1) "no way out of the stats screen," (2) "stats its own button in the More menu," (3) "fidget in the More menu." (1) and (2) are the *same* change — de-tabbing Stats into a dismissable menu-launched sheet fixes the trap and gives it a button at once — so they collapse into **Task B1**. (3) is **Task B2**.

---

## Track A — Echo Pro Paywall

**Execute the Echo Pro paywall plan (kept in the private strategy docs) in full, unchanged.** It is a complete, self-contained TDD plan. For orientation, its shape:

| Phase | Tasks |
|-------|-------|
| **0 — StoreKit config** | T1: create `Echo.storekit`, attach to scheme |
| **1 — Entitlement model** | T2: `ProductIDs` + request all four products · T3: broaden to `isPro` (pure rule + `ProEntitlementProviding`) · T4: generic purchase + intro-offer eligibility |
| **2 — Free-tier meters** | T5: `FreeTierGate` + `FlashcardDAO.count()` · T6: flashcard cap at the two creation sites · T7: narration cap in `NarrationService.renderChapter` |
| **3 — Enforce Pro features** | T8: fold "Pro Transcripts" into Echo Pro (`isPro`) |
| **4 — Paywall UI** | T9: reusable `PaywallView` · T10: replace Settings entry, retire `ProTranscriptsSettingsView` |
| **5 — Release (non-code)** | T11: ASC product setup (one-time non-consumables only — Pro unlock + Founders) · T12: **reaffirm** the "no subscription" promise — clarify Echo Pro is a one-time unlock (README/ROADMAP Trust + App Store copy aligned) |

Nothing in this umbrella modifies Track A. When complete, tick it in the Self-Review below.

> **Cross-track note:** Track A Task 10 edits `SettingsView.swift`; Track B does **not** touch `SettingsView`. Track A does not touch `RootTabView`/`UnifiedTopHeader`/`BottomToolbarView`/`TabSelection`. Disjoint — order-independent.

---

## Track B — UI Quick-Fixes

### File Structure (Track B)

**New:**
- `EchoTests/TabSelectionTests.swift` — guard test locking the de-tabbed enum shape.

**Modified:**
- `Shared/TabSelection.swift` — remove the `.stats` case (+ its `icon`/`label` arms).
- `EchoCore/Views/RootTabView.swift` — drop the `.stats` content case; add `showingStats` state + the Stats sheet; thread `onStatsTap`/`onFidgetTap` into the header; drop `onShowFidget` from the two bottom-dock call sites.
- `EchoCore/Views/Components/UnifiedTopHeader.swift` — add `onStatsTap` + `onFidgetTap` callbacks and the two menu items.
- `EchoCore/Views/BottomToolbarView.swift` — remove the `fidgetButton` (from the body + the computed property) and the now-unused `onShowFidget` param.
- `EchoCore/Views/Components/UnifiedBottomDock.swift` — remove the `onShowFidget` param + its pass-through.
- `EchoCore/Views/NowPlayingTab.swift` — remove the `onShowFidget` param + its pass-through.

**Platform note:** all of these live in `EchoCore` (the iOS surface). `Echo macOS` / Widget / Watch do **not** reference `.stats` or the fidget/bottom-dock chain (grep-verified), so there is no cross-platform parity break. Mac stats is a separate, not-yet-built WS9 surface.

---

### Task B1: De-tab Stats → dismissable sheet launched from the More menu

Fixes **"no way out"** *and* **"Stats its own button in the More menu"** in one change. After this, Stats is no longer a cycling tab; it opens from the ellipsis menu as a sheet with a Done button.

**Files:**
- Modify: `Shared/TabSelection.swift:3-26`
- Modify: `EchoCore/Views/BottomToolbarView.swift:142-151`
- Modify: `EchoCore/Views/RootTabView.swift:18, 43-81, 86-91, 145-150`
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift:7-11, 38-46`
- Test: `EchoTests/TabSelectionTests.swift`

- [ ] **Step 1: Write the failing guard test**

Create `EchoTests/TabSelectionTests.swift`:

```swift
import Testing

@testable import Echo

@Suite struct TabSelectionTests {
    @Test func statsIsNoLongerATab() {
        // Stats moved to the More menu (presented as a sheet), so it must NOT be a
        // bottom tab. This guard also proves a persisted "stats" rawValue decodes
        // to nil, so tab-restore falls back safely.
        #expect(TabSelection.allCases.map(\.rawValue) == ["nowPlaying", "read", "timeline"])
        #expect(TabSelection(rawValue: "stats") == nil)
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/TabSelectionTests`
Expected: FAIL — `allCases` still contains `stats` (and `TabSelection(rawValue: "stats")` is non-nil).

- [ ] **Step 3: Remove the `.stats` case from the enum**

In `Shared/TabSelection.swift`, delete the `case stats` and both of its `switch` arms:

```swift
import Foundation

enum TabSelection: String, CaseIterable {
    case nowPlaying
    case read
    case timeline
    // .stats removed — Stats now opens as a sheet from the More menu (UnifiedTopHeader).

    var icon: String {
        switch self {
        case .nowPlaying: return "headphones"
        case .read: return "book.pages"
        case .timeline: return "list.bullet.rectangle"
        }
    }

    var label: String {
        switch self {
        case .nowPlaying: return "Listen"
        case .read: return "Read"
        case .timeline: return "Study"
        }
    }
}
```

- [ ] **Step 4: Run the guard test to confirm it passes**

Run: `make test-only FILTER=EchoTests/TabSelectionTests`
Expected: PASS. (The app target won't build yet — the `.stats` switch arms in Steps 5–6 are now non-exhaustive/dead. That's expected; fix them next.)

- [ ] **Step 5: Fix the bottom-toolbar view-cycle**

In `EchoCore/Views/BottomToolbarView.swift`, the `timelineButton` cycle (lines 142-151) currently hops through `.stats`. Remove that hop so `.read` cycles back to `.timeline`, and drop the now-invalid `case .stats`:

```swift
                switch model.selectedTab {
                case .nowPlaying:
                    model.selectedTab = .timeline
                case .timeline:
                    model.selectedTab = .read
                case .read:
                    model.selectedTab = .timeline
                }
```

- [ ] **Step 6: Remove the `.stats` content case from RootTabView**

In `EchoCore/Views/RootTabView.swift`, delete the `case .stats:` arm (lines 76-80) from the `switch model.selectedTab` content block. The switch is now exhaustive over `.nowPlaying` / `.read` / `.timeline`.

- [ ] **Step 7: Add the Stats sheet + its presentation state**

In `RootTabView.swift`, add the state near `showingFidget` (line 18):

```swift
    @State private var showingStats = false
```

Then add the sheet alongside the others (e.g., right after the `showingFidget` sheet at lines 145-150). This mirrors the existing Help sheet (RootTabView:120-130): its **own** `NavigationStack` (so `StatsView`'s child `NavigationLink`s to `BookStatsView`/`DeckDetailView` still push) plus a Done button. Because a sheet is a separate presentation context, the root's `.toolbarVisibility(.hidden, for: .navigationBar)` does **not** suppress this toolbar — which is exactly what fixes the trap:

```swift
            .sheet(isPresented: $showingStats) {
                NavigationStack {
                    StatsView()
                        .navigationTitle("Stats")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showingStats = false }
                            }
                        }
                }
            }
```

- [ ] **Step 8: Add the "Stats" item to the More menu**

In `EchoCore/Views/Components/UnifiedTopHeader.swift`, add an `onStatsTap` callback property next to the existing ones (lines 7-10):

```swift
    let onFolderTap: () -> Void
    let onSettingsTap: () -> Void
    let onBookSettingsTap: () -> Void
    let onHelpTap: () -> Void
    let onStatsTap: () -> Void
```

And add the menu button at the top of the `Menu` (before Settings, lines 38-46):

```swift
                Menu {
                    Button(action: onStatsTap) {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    Button(action: onSettingsTap) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button(action: onHelpTap) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                } label: {
```

- [ ] **Step 9: Wire the callback at the header call site**

In `RootTabView.swift`, the only `UnifiedTopHeader(...)` call site (lines 86-91), add:

```swift
                UnifiedTopHeader(
                    onFolderTap: { showingFolderPicker = true },
                    onSettingsTap: { showingSettings = true },
                    onBookSettingsTap: { showingBookSettings = true },
                    onHelpTap: { model.showingHelp = true },
                    onStatsTap: { showingStats = true }
                )
```

- [ ] **Step 10: Build + manual verification**

Run: `make build-tests` (compiles the app target + tests).
Then run the app and verify:
1. The bottom view-cycle button no longer reaches a Stats screen (cycles Listen → Study → Read → Study…).
2. Tap the top-right ellipsis (⋯) → **Stats** → the stats screen appears as a sheet with a **Done** button and a "Stats" title.
3. Drill into a book's stats / a deck (child `NavigationLink`) — back navigation works inside the sheet.
4. Tap **Done** → the sheet dismisses, no trap. ✅ "no way out" fixed.

- [ ] **Step 11: Commit**

```bash
git add Shared/TabSelection.swift EchoCore/Views/BottomToolbarView.swift EchoCore/Views/RootTabView.swift EchoCore/Views/Components/UnifiedTopHeader.swift EchoTests/TabSelectionTests.swift
git commit -m "fix(stats): present Stats as a dismissable sheet from the More menu

Stats was a cycling bottom tab with no exit (root NavigationStack hides the
nav bar). De-tab it and present StatsView as a sheet (own NavigationStack +
Done) launched from the ellipsis menu — fixes the trap and gives Stats its
own entry."
```

---

### Task B2: Move the Fidget button into the More menu

Relocates the fidget trigger from the bottom dock into the ellipsis menu, and removes the now-unused `onShowFidget` plumbing. The `showingFidget` state + the existing `.sheet(isPresented: $showingFidget)` in `RootTabView` stay — only the trigger moves.

**Files:**
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift:7-11, 38-47`
- Modify: `EchoCore/Views/RootTabView.swift:52, 86-92, 98-100`
- Modify: `EchoCore/Views/BottomToolbarView.swift:7, 19-20, 168-182`
- Modify: `EchoCore/Views/Components/UnifiedBottomDock.swift:6, 43`
- Modify: `EchoCore/Views/NowPlayingTab.swift:10, 60-61`
- Test: build + manual (view-only; no unit-testable logic).

- [ ] **Step 1: Add the "Fidget" item to the More menu**

In `UnifiedTopHeader.swift`, add the callback property (after `onStatsTap` from B1):

```swift
    let onStatsTap: () -> Void
    let onFidgetTap: () -> Void
```

And add the menu button after Stats (it needs a loaded book, so disable it when there are no tracks — preserving the old `fidgetButton`'s `.disabled(model.tracks.isEmpty)`):

```swift
                Menu {
                    Button(action: onStatsTap) {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    Button(action: onFidgetTap) {
                        Label("Fidget", systemImage: "circle.hexagongrid.fill")
                    }
                    .disabled(model.tracks.isEmpty)
                    Button(action: onSettingsTap) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button(action: onHelpTap) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                } label: {
```

> `UnifiedTopHeader` already has `@Environment(PlayerModel.self) private var model` (line 4), so `model.tracks.isEmpty` resolves.

- [ ] **Step 2: Wire the callback at the header call site**

In `RootTabView.swift`, the `UnifiedTopHeader(...)` call (now also passing `onStatsTap` from B1) gains:

```swift
                UnifiedTopHeader(
                    onFolderTap: { showingFolderPicker = true },
                    onSettingsTap: { showingSettings = true },
                    onBookSettingsTap: { showingBookSettings = true },
                    onHelpTap: { model.showingHelp = true },
                    onStatsTap: { showingStats = true },
                    onFidgetTap: { showingFidget = true }
                )
```

- [ ] **Step 3: Remove the fidget button from the bottom toolbar**

In `EchoCore/Views/BottomToolbarView.swift`:

Remove the `onShowFidget` property (line 7):

```swift
    var onCreateBookmark: ((BookmarkDraft) -> Void)?
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).
```

Remove `fidgetButton` (and its trailing `Spacer()`) from the body HStack (lines 19-20), leaving:

```swift
        HStack {
            loopModeButton
            Spacer()
            speedButton
            Spacer()
            markPassageButton
            Spacer()
            timelineButton
            Spacer()
            addBookmarkButton
        }
```

Delete the `fidgetButton` computed property entirely (lines 168-182, including its `// MARK: - Fidget` comment).

- [ ] **Step 4: Remove the now-unused `onShowFidget` pass-through**

In `EchoCore/Views/Components/UnifiedBottomDock.swift`, remove the property (line 6) and stop passing it to `BottomToolbarView` (line 43):

```swift
    var onCreateBookmark: (BookmarkDraft) -> Void
    // onShowFidget removed (B2)
```
```swift
            BottomToolbarView(onCreateBookmark: onCreateBookmark)
```

In `EchoCore/Views/NowPlayingTab.swift`, remove the property (line 10) and stop passing it (lines 60-61):

```swift
    // onShowFidget removed (B2)
```
```swift
                if !model.isPlayingVoiceMemo {
                    UnifiedBottomDock(onCreateBookmark: onCreateBookmark)
                }
```

In `RootTabView.swift`, remove `onShowFidget:` from the `NowPlayingTab(...)` call (line 52) and the `UnifiedBottomDock(...)` call (lines 98-100):

```swift
                        NowPlayingTab(
                            showsBookSettings: model.folderURL != nil,
                            openFolder: { showingFolderPicker = true },
                            showHelp: { model.showingHelp = true },
                            showBookSettings: { showingBookSettings = true },
                            showSettings: { showingSettings = true },
                            onCreateBookmark: { draft in newBookmarkDraft = draft }
                        )
```
```swift
                        UnifiedBottomDock(
                            onCreateBookmark: { draft in newBookmarkDraft = draft })
```

> Leave `@State private var showingFidget` (RootTabView:18) and the `.sheet(isPresented: $showingFidget) { FidgetOverlayView(...) }` (RootTabView:145-150) **unchanged** — the header callback now drives them.

- [ ] **Step 5: Build + manual verification**

Run: `make build-tests`.
Then run the app and verify:
1. The bottom dock no longer shows the fidget (hex-grid) chip.
2. With a book loaded: ellipsis (⋯) → **Fidget** → the `FidgetOverlayView` sheet opens.
3. With no book loaded (empty library): the **Fidget** menu item is disabled (greyed).

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/Components/UnifiedTopHeader.swift EchoCore/Views/RootTabView.swift EchoCore/Views/BottomToolbarView.swift EchoCore/Views/Components/UnifiedBottomDock.swift EchoCore/Views/NowPlayingTab.swift
git commit -m "feat(fidget): move the Fidget trigger into the More menu

Relocate Fidget from the bottom dock into the ellipsis menu (disabled when
no book is loaded); remove the now-unused onShowFidget plumbing. The
showingFidget state + FidgetOverlayView sheet are unchanged."
```

---

## Self-Review

**Request coverage:**
- "no way out of the stats screen" → **B1** (Stats is now a sheet with a Done button). ✅
- "stats its own button … in the more menu" → **B1** (ellipsis menu → Stats). ✅
- "fidget button in the more menu" → **B2** (ellipsis menu → Fidget; removed from the dock). ✅
- "include the paywall plan … all in one go" → **Track A** (referenced + execute-as-is). ✅
- 4th (blank) bullet → confirmed none.

**Type/name consistency:** `onStatsTap` and `onFidgetTap` are added to `UnifiedTopHeader` (B1/B2) and supplied at the single `RootTabView` call site; `showingStats` (new) mirrors `showingFidget` (existing); the `.stats` enum case is removed everywhere it was switched on (`TabSelection`, `RootTabView`, `BottomToolbarView`) — grep-verified those are the only three sites.

**Placeholder scan:** every code step shows exact before/after; the only "test-light" steps are the view-only menu/sheet edits, which are honestly marked build-+-manual (UI tests excluded per CLAUDE.md) and anchored by the real `TabSelectionTests` guard.

**Risk notes:** removing the `.stats` enum case is contained to `EchoCore` (Mac/Widget/Watch don't reference it); tab-restore is resilient because `TabSelection(rawValue: "stats")` now returns `nil` (falls back to `.nowPlaying`); no deep link targets `.stats` (grep-verified).

---

## Docs & Parity Note

- Track B is a UI/navigation change (a feature surface moves) — per CLAUDE.md, after it lands run the **doc-sync** skill and update `CHANGELOG.md` (and `README.md`/`ARCHITECTURE.md` if either documents the tab layout). Track A's own plan carries its doc/marketing follow-ups (Phase 5).
- Run the **cross-platform-parity-reviewer** on Track B before PR to confirm the macOS surface intentionally diverges (it has no Stats tab / fidget dock today).

---

## Execution Handoff

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks. Natural fit: Track B is 2 self-contained tasks; Track A is 12.
2. **Inline Execution** — batch with checkpoints in-session.

Suggested order: **Track B first** (fast, low-risk, immediately fixes the trap), then **Track A**. Which approach?
