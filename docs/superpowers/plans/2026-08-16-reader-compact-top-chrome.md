# Compact Reader Top Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the 64-point global folder/sleep row from the standalone EPUB Reader, preserve both actions in the existing bottom More menu, and visibly indicate an armed sleep timer without adding vertical chrome.

**Architecture:** `RootTabView` remains the single owner of the global header and its safe-area reservation. A pure `ReaderTopChromeLayout` resolver identifies only the standalone EPUB Reader root; that state simultaneously suppresses the header and reservation and enables Reader-only actions threaded through `UnifiedBottomDock` to `PlayerMoreMenu`. Sleep-timer choices and presentation strings are shared by the existing top pill and the new overflow submenu so timer behavior has one implementation.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, Xcode 26 toolchain, iOS 18+.

## Global Constraints

- Preserve deployment floors: iOS 18, macOS 15, and watchOS 11.
- Preserve the repository's Swift 6 strict-concurrency settings and default Main Actor isolation for app targets.
- Do not add third-party dependencies.
- Limit compact chrome to the standalone EPUB Reader root; PDF page/reflow, transcript, Library, Now Playing, pushed destinations, modal sheets, macOS, and watchOS remain unchanged.
- Preserve localization, VoiceOver semantics, Dynamic Type, Reduce Motion, and 44-point minimum hit targets.
- Keep sleep-timer state and behavior in the existing `PlayerModel`/`SleepTimerManager`; do not duplicate business state.
- Run every Apple build or test as one complete command through `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- <command>`.
- Keep the unrelated untracked `docs/superpowers/plans/2026-08-02-macos-performance-remediation.md` and `file.txt` untouched.

---

## File Structure

- Modify `EchoCore/ViewModels/ReaderChromeClearance.swift`: add the pure standalone-Reader chrome resolver beside the existing pure clearance calculation.
- Modify `EchoCore/Views/RootTabView.swift`: derive compact Reader state, conditionally suppress the global header and reservation together, and supply Reader-only overflow actions.
- Modify `EchoCore/Views/Components/SleepTimerPill.swift`: centralize timer labels, accessibility values, active-status text, and menu choices for reuse.
- Modify `EchoCore/Views/PlayerMoreMenu.swift`: add optional Reader actions, timer badge presentation, and a pure accessibility-state helper.
- Modify `EchoCore/Views/BottomToolbarView.swift`: forward the optional Reader actions to `PlayerMoreMenu`.
- Modify `EchoCore/Views/Components/UnifiedBottomDock.swift`: forward the optional Reader actions from root to the toolbar.
- Modify `EchoCore/Localizable.xcstrings`: add the Reader overflow's **Open Book or Folder…** localization.
- Modify `EchoTests/ReaderChromeClearanceTests.swift`: test the standalone-Reader surface-selection rules.
- Modify `EchoTests/SleepTimerPillStateTests.swift`: test shared timer presentation and menu status values.
- Modify `EchoTests/PlayerMoreMenuTests.swift`: test the Reader timer-indicator behavior and remove the obsolete single-home assertion.
- Modify `CHANGELOG.md`: record the user-visible Reader collision fix and relocated actions.

### Task 1: Resolve and apply standalone Reader chrome state

**Files:**
- Modify: `EchoCore/ViewModels/ReaderChromeClearance.swift:4-10`
- Modify: `EchoCore/Views/RootTabView.swift:161-167,173-321`
- Test: `EchoTests/ReaderChromeClearanceTests.swift:7-41`

**Interfaces:**
- Consumes: booleans already available in `RootTabView` (`model.selectedTab == .read`, `readPath.isEmpty`, `model.hasEPUB`, `model.hasPDF`, and `model.hasStandaloneTranscript`).
- Produces: `ReaderTopChromeLayout.usesCompactHeader(selectedTabIsRead:readPathIsEmpty:hasEPUB:hasPDF:hasStandaloneTranscript:) -> Bool` and `RootTabView.usesCompactReaderTopChrome: Bool`.

- [ ] **Step 1: Add failing pure resolver tests**

Append these tests inside `ReaderChromeClearanceTests` before its source helper:

```swift
@Test func standaloneEPUBReaderRootUsesCompactTopChrome() {
    #expect(
        ReaderTopChromeLayout.usesCompactHeader(
            selectedTabIsRead: true,
            readPathIsEmpty: true,
            hasEPUB: true,
            hasPDF: false,
            hasStandaloneTranscript: false
        )
    )
}

@Test func otherReadSurfacesAndDestinationsKeepGlobalTopChrome() {
    #expect(
        !ReaderTopChromeLayout.usesCompactHeader(
            selectedTabIsRead: false,
            readPathIsEmpty: true,
            hasEPUB: true,
            hasPDF: false,
            hasStandaloneTranscript: false
        )
    )
    #expect(
        !ReaderTopChromeLayout.usesCompactHeader(
            selectedTabIsRead: true,
            readPathIsEmpty: false,
            hasEPUB: true,
            hasPDF: false,
            hasStandaloneTranscript: false
        )
    )
    #expect(
        !ReaderTopChromeLayout.usesCompactHeader(
            selectedTabIsRead: true,
            readPathIsEmpty: true,
            hasEPUB: true,
            hasPDF: true,
            hasStandaloneTranscript: false
        )
    )
    #expect(
        !ReaderTopChromeLayout.usesCompactHeader(
            selectedTabIsRead: true,
            readPathIsEmpty: true,
            hasEPUB: false,
            hasPDF: false,
            hasStandaloneTranscript: true
        )
    )
    #expect(
        !ReaderTopChromeLayout.usesCompactHeader(
            selectedTabIsRead: true,
            readPathIsEmpty: true,
            hasEPUB: false,
            hasPDF: false,
            hasStandaloneTranscript: false
        )
    )
}

```

- [ ] **Step 2: Build the tests to verify the new resolver test fails**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: FAIL with `cannot find 'ReaderTopChromeLayout' in scope`. A schedule or memory-pressure hold from the wrapper is infrastructure status, not the expected test failure; wait for admission rather than bypassing the wrapper.

- [ ] **Step 3: Add the minimal pure resolver**

Add this beside `ReaderChromeClearance` in `EchoCore/ViewModels/ReaderChromeClearance.swift`:

```swift
/// Selects the one iOS surface that replaces the root-owned top row with the
/// Reader's local search and utility chrome.
nonisolated enum ReaderTopChromeLayout {
    static func usesCompactHeader(
        selectedTabIsRead: Bool,
        readPathIsEmpty: Bool,
        hasEPUB: Bool,
        hasPDF: Bool,
        hasStandaloneTranscript: Bool
    ) -> Bool {
        selectedTabIsRead
            && readPathIsEmpty
            && hasEPUB
            && !hasPDF
            && !hasStandaloneTranscript
    }
}
```

- [ ] **Step 4: Wire the resolver into `RootTabView`**

Add this computed property after the three navigation-path states:

```swift
private var usesCompactReaderTopChrome: Bool {
    ReaderTopChromeLayout.usesCompactHeader(
        selectedTabIsRead: model.selectedTab == .read,
        readPathIsEmpty: readPath.isEmpty,
        hasEPUB: model.hasEPUB,
        hasPDF: model.hasPDF,
        hasStandaloneTranscript: model.hasStandaloneTranscript
    )
}
```

Gate the outer global reservation:

```swift
.safeAreaInset(edge: .top, spacing: 0) {
    if !usesCompactReaderTopChrome {
        Color.clear.frame(height: UnifiedTopHeader.rowOneHeight)
    }
}
```

Gate the overlaid global header with the identical state:

```swift
if !usesCompactReaderTopChrome {
    UnifiedTopHeader(onFolderTap: { showingFolderPicker = true })
        .transition(
            reduceMotion
                ? .identity
                : .move(edge: .top).combined(with: .opacity)
        )
}
```

Apply the existing short chrome animation to the root `ZStack`, keyed only to this layout state:

```swift
.animation(
    reduceMotion ? nil : .easeInOut(duration: 0.2),
    value: usesCompactReaderTopChrome
)
```

Do not change the Library's inner safe-area reservation: its existing comment documents why the outer reservation does not reach its UIKit-backed stack.

- [ ] **Step 5: Build and run the focused layout tests**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderChromeClearanceTests
```

Expected: build succeeds and `ReaderChromeClearanceTests` passes. The pure tests must show that PDF, transcript, non-Read tabs, pushed Read destinations, and empty Reader state all retain global chrome. Task 4 verifies the rendered Root wiring in Simulator.

- [ ] **Step 6: Commit the surface-selection change**

```bash
git add EchoCore/ViewModels/ReaderChromeClearance.swift EchoCore/Views/RootTabView.swift EchoTests/ReaderChromeClearanceTests.swift
git commit -m "fix(reader): reclaim global top chrome"
```

### Task 2: Share sleep-timer menu and presentation state

**Files:**
- Modify: `EchoCore/Views/Components/SleepTimerPill.swift:4-110`
- Test: `EchoTests/SleepTimerPillStateTests.swift:6-34`

**Interfaces:**
- Consumes: `SleepTimerMode`, `PlayerModel.sleepTimerMode`, `PlayerModel.sleepTimerRemainingSeconds`, `PlayerModel.setSleepTimer(_:)`, and `PlayerModel.cancelSleepTimer()`.
- Produces: `SleepTimerPillState.accessibilityValue(mode:remainingSeconds:) -> String`, `SleepTimerPillState.activeStatusText(mode:remainingSeconds:) -> String?`, and reusable `SleepTimerMenuContent(showsActiveStatus:)`.

- [ ] **Step 1: Add failing shared-presentation tests**

Append these tests to `SleepTimerPillStateTests`:

```swift
@Test func timerAccessibilityValuesDescribeAllModes() {
    #expect(
        SleepTimerPillState.accessibilityValue(mode: .off, remainingSeconds: 0) == "Off"
    )
    #expect(
        SleepTimerPillState.accessibilityValue(
            mode: .minutes(30), remainingSeconds: 1335
        ) == "30 minutes, 1335 seconds remaining"
    )
    #expect(
        SleepTimerPillState.accessibilityValue(
            mode: .endOfChapter, remainingSeconds: 0
        ) == "End of Chapter"
    )
}

@Test func activeMenuStatusIsAbsentWhenOffAndConciseWhenArmed() {
    #expect(SleepTimerPillState.activeStatusText(mode: .off, remainingSeconds: 0) == nil)
    #expect(
        SleepTimerPillState.activeStatusText(
            mode: .minutes(30), remainingSeconds: 1335
        ) == "Remaining: 22:15"
    )
    #expect(
        SleepTimerPillState.activeStatusText(
            mode: .endOfChapter, remainingSeconds: 0
        ) == "End of Chapter"
    )
}

```

- [ ] **Step 2: Build to verify the shared-presentation tests fail**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: FAIL because `accessibilityValue` and `activeStatusText` do not yet exist.

- [ ] **Step 3: Extend the pure timer presentation state**

Replace the existing enum declaration with:

```swift
enum SleepTimerPillState {
    static func labelText(mode: SleepTimerMode, remainingSeconds: Int) -> String? {
        switch mode {
        case .off: return nil
        case .minutes: return sleepTimerCountdownText(remainingSeconds)
        case .endOfChapter: return "EOC"
        }
    }

    static func accessibilityValue(mode: SleepTimerMode, remainingSeconds: Int) -> String {
        switch mode {
        case .off:
            return String(localized: "Off")
        case .minutes(let minutes):
            return String(
                localized: "\(minutes) minutes, \(remainingSeconds) seconds remaining"
            )
        case .endOfChapter:
            return String(localized: "End of Chapter")
        }
    }

    static func activeStatusText(mode: SleepTimerMode, remainingSeconds: Int) -> String? {
        switch mode {
        case .off:
            return nil
        case .minutes:
            let countdown = sleepTimerCountdownText(remainingSeconds)
            return String(
                localized: "Remaining: \(countdown)",
                comment: "Sleep timer remaining countdown"
            )
        case .endOfChapter:
            return String(localized: "End of Chapter")
        }
    }
}
```

This reuses the existing `%lld minutes, %lld seconds remaining`, `Remaining: %@`, and `End of Chapter` catalog entries.

- [ ] **Step 4: Extract the shared menu content**

Add this focused component below `SleepTimerPillState`:

```swift
struct SleepTimerMenuContent: View {
    @Environment(PlayerModel.self) private var model
    var showsActiveStatus = false

    @ViewBuilder
    var body: some View {
        if showsActiveStatus,
            let status = SleepTimerPillState.activeStatusText(
                mode: model.sleepTimerMode,
                remainingSeconds: model.sleepTimerRemainingSeconds
            )
        {
            Button(action: {}) {
                Label(status, systemImage: "moon.zzz.fill")
            }
            .disabled(true)
            Divider()
        }

        Button {
            model.setSleepTimer(.minutes(15))
            Haptic.play(.light)
        } label: {
            Label("15 Minutes", systemImage: "15.circle")
        }
        Button {
            model.setSleepTimer(.minutes(30))
            Haptic.play(.light)
        } label: {
            Label("30 Minutes", systemImage: "30.circle")
        }
        Button {
            model.setSleepTimer(.minutes(45))
            Haptic.play(.light)
        } label: {
            Label("45 Minutes", systemImage: "45.circle")
        }
        Button {
            model.setSleepTimer(.minutes(60))
            Haptic.play(.light)
        } label: {
            Label("1 Hour", systemImage: "1.circle")
        }
        Divider()
        Button {
            model.setSleepTimer(.endOfChapter)
            Haptic.play(.light)
        } label: {
            Label("End of Chapter", systemImage: "book.closed")
        }
        if model.sleepTimerMode.isActive {
            Divider()
            Button(role: .destructive) {
                model.cancelSleepTimer()
                Haptic.play(.light)
            } label: {
                Label("Off", systemImage: "xmark.circle")
            }
        }
    }
}
```

Replace `SleepTimerPill`'s inline `menuItems` with `SleepTimerMenuContent()` and replace its private accessibility switch with:

```swift
.accessibilityValue(
    Text(
        SleepTimerPillState.accessibilityValue(
            mode: model.sleepTimerMode,
            remainingSeconds: model.sleepTimerRemainingSeconds
        )
    )
)
```

Delete the old `menuItems` and private `accessibilityValue` implementations after the shared component is wired.

- [ ] **Step 5: Build and run the timer-state suite**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/SleepTimerPillStateTests
```

Expected: build succeeds and `SleepTimerPillStateTests` passes, including the unchanged boundary formatting tests.

- [ ] **Step 6: Commit the shared timer content**

```bash
git add EchoCore/Views/Components/SleepTimerPill.swift EchoTests/SleepTimerPillStateTests.swift
git commit -m "refactor(player): share sleep timer menu content"
```

### Task 3: Relocate Reader actions into More and add the timer badge

**Files:**
- Modify: `EchoCore/Views/PlayerMoreMenu.swift:12-106`
- Modify: `EchoCore/Views/BottomToolbarView.swift:11-55`
- Modify: `EchoCore/Views/Components/UnifiedBottomDock.swift:8-95`
- Modify: `EchoCore/Views/RootTabView.swift:324-350`
- Modify: `EchoCore/Localizable.xcstrings:4684-4720`
- Modify: `CHANGELOG.md:107-112`
- Test: `EchoTests/PlayerMoreMenuTests.swift:7-126`

**Interfaces:**
- Consumes: `RootTabView.usesCompactReaderTopChrome`, root-owned `showingFolderPicker`, `SleepTimerMenuContent(showsActiveStatus:)`, and `SleepTimerPillState.accessibilityValue(mode:remainingSeconds:)`.
- Produces: optional `onOpenBookOrFolder: (() -> Void)?` and `showsReaderSleepTimer: Bool` inputs on `UnifiedBottomDock`, `BottomToolbarView`, and `PlayerMoreMenu`; `PlayerMoreMenuState.timerAccessibilityValue(showsReaderSleepTimer:mode:remainingSeconds:) -> String?`.

- [ ] **Step 1: Replace the obsolete single-home assertion and add failing timer-indicator tests**

In `PlayerMoreMenuTests.playerMoreMenuExposesConsolidatedActions()`, delete lines 40-43: the obsolete source-text assertion that the sleep timer belongs only to `SleepTimerPill`.

Do not replace it with another source-text assertion. Add these pure state tests, whose literal expected values independently exercise the real presentation decision:

```swift
@Test func timerIndicatorIsAbsentOutsideReaderAndWhenOff() {
    #expect(
        PlayerMoreMenuState.timerAccessibilityValue(
            showsReaderSleepTimer: false,
            mode: .minutes(30),
            remainingSeconds: 1335
        ) == nil
    )
    #expect(
        PlayerMoreMenuState.timerAccessibilityValue(
            showsReaderSleepTimer: true,
            mode: .off,
            remainingSeconds: 0
        ) == nil
    )
}

@Test func timerIndicatorDescribesTimedAndEndOfChapterModes() {
    #expect(
        PlayerMoreMenuState.timerAccessibilityValue(
            showsReaderSleepTimer: true,
            mode: .minutes(30),
            remainingSeconds: 1335
        ) == "30 minutes, 1335 seconds remaining"
    )
    #expect(
        PlayerMoreMenuState.timerAccessibilityValue(
            showsReaderSleepTimer: true,
            mode: .endOfChapter,
            remainingSeconds: 0
        ) == "End of Chapter"
    )
}

```

- [ ] **Step 2: Build to verify the new menu-state tests fail**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: FAIL because `PlayerMoreMenuState` does not exist.

- [ ] **Step 3: Add the pure More-menu timer state**

Add this above `PlayerMoreMenu`:

```swift
enum PlayerMoreMenuState {
    static func timerAccessibilityValue(
        showsReaderSleepTimer: Bool,
        mode: SleepTimerMode,
        remainingSeconds: Int
    ) -> String? {
        guard showsReaderSleepTimer, mode.isActive else { return nil }
        return SleepTimerPillState.accessibilityValue(
            mode: mode,
            remainingSeconds: remainingSeconds
        )
    }
}
```

- [ ] **Step 4: Add Reader-only items and the badged More label**

Add these defaulted inputs after the existing optional current-book actions and before `onEditLayout`:

```swift
var onOpenBookOrFolder: (() -> Void)? = nil
var showsReaderSleepTimer = false
```

Inside the current-book portion of the menu, before export actions, add:

```swift
if let onOpenBookOrFolder {
    Button(action: onOpenBookOrFolder) {
        Label("Open Book or Folder…", systemImage: "folder")
    }
}
if showsReaderSleepTimer {
    Menu {
        SleepTimerMenuContent(showsActiveStatus: true)
    } label: {
        Label(
            "Sleep Timer",
            systemImage: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz"
        )
    }
}
```

Replace the existing `chip` with separate content and conditional accessibility values:

```swift
@ViewBuilder
private var chip: some View {
    if let timerValue = timerAccessibilityValue {
        chipContent
            .accessibilityLabel(Text("More options"))
            .accessibilityValue(Text(timerValue))
    } else {
        chipContent
            .accessibilityLabel(Text("More options"))
    }
}

private var chipContent: some View {
    ZStack(alignment: .topTrailing) {
        Image(systemName: "ellipsis.circle.fill")
            .font(.title2)
        if timerAccessibilityValue != nil {
            Image(systemName: "moon.fill")
                .font(.system(size: 8, weight: .bold))
                .padding(3)
                .background(model.coverTheme.chip, in: Circle())
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
        }
    }
    .frame(width: 44, height: 44)
    .contentShape(Rectangle())
    .foregroundStyle(model.resolvedThemeTint ?? .accentColor)
}

private var timerAccessibilityValue: String? {
    PlayerMoreMenuState.timerAccessibilityValue(
        showsReaderSleepTimer: showsReaderSleepTimer,
        mode: model.sleepTimerMode,
        remainingSeconds: model.sleepTimerRemainingSeconds
    )
}
```

Remove the outer Menu's old `.accessibilityLabel(Text("More options"))`; the label branches now carry both the label and optional timer value.

- [ ] **Step 5: Thread the optional inputs through the dock**

Add these defaulted stored properties at the end of both `BottomToolbarView` and `UnifiedBottomDock` input lists:

```swift
var onOpenBookOrFolder: (() -> Void)? = nil
var showsReaderSleepTimer = false
```

Forward both values in `UnifiedBottomDock`'s `BottomToolbarView(...)` call and in `BottomToolbarView`'s `PlayerMoreMenu(...)` call:

```swift
onOpenBookOrFolder: onOpenBookOrFolder,
showsReaderSleepTimer: showsReaderSleepTimer
```

In `RootTabView`'s `UnifiedBottomDock(...)` call, add:

```swift
onOpenBookOrFolder: usesCompactReaderTopChrome
    ? { showingFolderPicker = true }
    : nil,
showsReaderSleepTimer: usesCompactReaderTopChrome
```

These values must be conditional rather than globally supplied, so Now Playing, Library, PDF, transcript, and pushed screens do not gain duplicate menu actions or a timer badge.

- [ ] **Step 6: Add the localized menu title**

Insert this alphabetically after `Open Audiobook…` in `EchoCore/Localizable.xcstrings`:

```json
"Open Book or Folder…" : {
  "comment" : "Reader overflow action that opens the shared book or folder picker",
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Open Book or Folder…"
      }
    },
    "nl" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Open boek of map…"
      }
    }
  }
},
```

Validate the catalog remains valid JSON:

```bash
plutil -lint EchoCore/Localizable.xcstrings
```

Expected: `EchoCore/Localizable.xcstrings: OK`.

- [ ] **Step 7: Record the user-visible fix**

Add this under `CHANGELOG.md` → `[Unreleased]` → `Fixed`:

```markdown
- **Reader top controls no longer collide or waste a full row.** The standalone EPUB Reader now uses the top safe area for its search and reading tools instead of overlaying the global folder and sleep-timer controls. Both actions remain available in the bottom More menu, and an armed timer badges that control without adding vertical chrome. PDF, transcript, Library, and Now Playing headers are unchanged.
```

- [ ] **Step 8: Build and run the focused chrome/menu suites**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerMoreMenuTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ChromeConsolidationTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/SleepTimerPillStateTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ReaderChromeClearanceTests
```

Expected: build succeeds and all four suites pass. The existing experimental-player `PlayerMoreMenu` call must continue compiling through the new defaulted inputs.

- [ ] **Step 9: Commit the Reader overflow implementation**

```bash
git add EchoCore/Views/PlayerMoreMenu.swift EchoCore/Views/BottomToolbarView.swift EchoCore/Views/Components/UnifiedBottomDock.swift EchoCore/Views/RootTabView.swift EchoCore/Localizable.xcstrings EchoTests/PlayerMoreMenuTests.swift CHANGELOG.md
git commit -m "feat(reader): relocate top actions into more menu"
```

### Task 4: Full verification and compact-width acceptance

**Files:**
- Verify only; no source changes are expected.
- Fixture: `EchoTests/Fixtures/minimal-book.epub` or the DEBUG screenshot fixture selected by `--echo-screenshot-fixture-gatsby`.

**Interfaces:**
- Consumes: the complete implementation from Tasks 1-3.
- Produces: automated test evidence, compact-width visual evidence, and a clean task branch ready for review/publication.

- [ ] **Step 1: Run repository hygiene checks**

```bash
git diff --check
plutil -lint EchoCore/Localizable.xcstrings
git status --short --branch
```

Expected: no whitespace errors; the string catalog is valid; only the two pre-existing unrelated untracked files remain outside committed work.

- [ ] **Step 2: Run the primary iOS unit-test gate**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
```

Expected: `TEST SUCCEEDED`. Record any failures exactly; do not weaken or delete unrelated tests to make the gate pass.

- [ ] **Step 3: Launch the DEBUG app on an iPhone simulator with stable Reader content**

Use the `build-ios-apps:ios-debugger-agent` skill for simulator launch and inspection. Launch with:

```text
--echo-screenshot-fixture-gatsby
--echo-screenshot-appearance-dark
```

Use an available compact-width iPhone simulator from `xcrun simctl list devices available`; prefer the Makefile's `iPhone 17` destination. Wait for the fixture to load, then navigate to **Read & Study**.

- [ ] **Step 4: Verify the standalone Reader layout and relocated actions**

On the Reader root, confirm all of the following:

1. The global folder chip and top sleep-timer pill are absent.
2. The Reader search/tools row begins directly below the status-bar safe area.
3. No blank 64-point band remains above the Reader controls.
4. Search, Table of Contents, Reader settings, and Listening sessions remain visible and hittable.
5. The bottom More menu contains **Open Book or Folder…** and **Sleep Timer**.
6. **Open Book or Folder…** presents the existing picker; cancel it without importing private content.
7. Arm a 15-minute timer. Reopen More and confirm the moon badge is visible, VoiceOver exposes the remaining-time value, the submenu shows `Remaining: m:ss`, and **Off** cancels it.
8. Arm **End of Chapter** and confirm the badge remains, VoiceOver reports `End of Chapter`, and the submenu shows the active status.

Capture one screenshot with the Reader root and active timer badge:

```bash
mkdir -p .build/reader-compact-chrome-evidence
xcrun simctl io booted screenshot .build/reader-compact-chrome-evidence/reader-active-timer.png
```

The `.build/` evidence is disposable and must not be committed.

- [ ] **Step 5: Verify excluded surfaces and transitions**

Switch Reader → Library → Now Playing → Reader and confirm:

1. Library and Now Playing retain the global folder/sleep row.
2. Returning to Reader removes the row and its reservation together without overlap, doubled clearance, or a vertical jump after the transition settles.
3. With Reduce Motion enabled, the same transitions occur without the move/fade animation.
4. If a PDF or standalone transcript fixture is already available locally, open it and confirm its existing header remains. Do not add or commit private book material solely for this optional check; the pure resolver tests are the required PDF/transcript gate.

- [ ] **Step 6: Confirm final branch state**

```bash
git status --short --branch
git log --oneline --decorate origin/nightly..HEAD
```

Expected: the design commit, this plan commit, and three coherent implementation commits are ahead of `origin/nightly`; only the two pre-existing unrelated untracked files remain; `.build/reader-compact-chrome-evidence/` is ignored and uncommitted.

Do not publish until explicitly proceeding with the repository's normal feature-branch publication workflow (`feature/*` PR to `nightly`).
