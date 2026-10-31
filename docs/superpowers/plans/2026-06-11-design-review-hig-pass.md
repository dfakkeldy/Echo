# Design Review HIG Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the "Echo v1.0 Design Review" audit fixes for existing surfaces: Now Playing redesign (timer pill, eyebrow title, transport re-weight, book-progress hairline), chapter-list interaction inversion + part grouping, reader timestamp/header polish, settings fixes, and a 3-slot configurable mini-player.

**Architecture:** All changes live in `EchoCore` (iOS). Pure logic (pill labels, part grouping, tick fractions, smart-rewind policy) is extracted into small testable units with Swift Testing tests; SwiftUI views consume them. The cover-theme system (`CoverTheme` roles) is reused as-is — no new color plumbing. Section-3 pages of the design (Insights/Card Inbox/Brain Dump/Context Memory/celebration) are **out of scope** (WS3–6 data layers don't exist); the full tab-bar restructure is deferred (design says "decide before WS3") — we apply its stated minimum fix only.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (`@Test`/`#expect`), XCTest legacy untouched, xcodebuild CLI.

**Design source:** claude.ai/design handoff bundle "Echo v1.0 Design Review" (print + non-print `.dc.html`, chats 1–2). Where the two revisions differ, the **non-print file wins** (it has the chat-1 correction: the play button keeps its progress ring — "two book-progress scales, one story").

**Documented deviations from the mock (intentional):**
1. Timer pill "hidden when off" → when off we render a **bare moon glyph menu** (no chip, no number) so arming stays one tap; armed = filled chip + countdown. This follows the design's own "inactive = bare glyph / active = filled chip" grammar.
2. Segmented control "Chapters / Bookmarks" → three segments **All / Chapters / Bookmarks**, because the current model intentionally supports interleaving bookmarks under chapters (All).
3. `.searchable` → inline search field in the filter row, because the app hides the system navigation bar (`.toolbarVisibility(.hidden)`), so `.searchable` would not render.
4. Audit E5 (custom back chevrons) is a **no-op**: the codebase already uses standard NavigationStack back buttons.
5. Audit C4 (bottom inset) is **verify-only**: `PlaylistView` already reserves `model.bottomInset`.

---

### Task 1: Branch setup

- [ ] **Step 1: Create feature branch off main**

```bash
cd ~/Developer/Echo
git checkout main && git pull --ff-only
git checkout -b feat/design-review-hig-pass
```

Expected: clean branch `feat/design-review-hig-pass` at current main.

---

### Task 2: Sleep-timer pill (audit B1 + chat-2) — pill at top, sleep button leaves the bottom row

**Files:**
- Create: `EchoCore/Views/Components/SleepTimerPill.swift`
- Create: `EchoTests/SleepTimerPillStateTests.swift`
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift` (replace `remainingTimeView`)
- Modify: `EchoCore/Views/BottomToolbarView.swift` (remove `sleepTimerMenu` from the HStack)

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/SleepTimerPillStateTests.swift
import Testing
@testable import EchoCore

struct SleepTimerPillStateTests {
    @Test func offModeHasNoLabel() {
        #expect(SleepTimerPillState.labelText(mode: .off, remainingSeconds: 0) == nil)
    }

    @Test func minutesModeShowsCountdown() {
        #expect(SleepTimerPillState.labelText(mode: .minutes(30), remainingSeconds: 1335) == "22:15")
    }

    @Test func minutesModeOverAnHourUsesHoursMinutes() {
        // 1h 02m = 3725s → "1:02" (matches sleepTimerCountdownText's h:mm fallback)
        #expect(SleepTimerPillState.labelText(mode: .minutes(90), remainingSeconds: 3725) == "1:02")
    }

    @Test func endOfChapterShowsEOC() {
        #expect(SleepTimerPillState.labelText(mode: .endOfChapter, remainingSeconds: 0) == "EOC")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/SleepTimerPillStateTests 2>&1 | tail -5
```

Expected: FAIL — `SleepTimerPillState` not found.

- [ ] **Step 3: Implement SleepTimerPill (state + view)**

```swift
// EchoCore/Views/Components/SleepTimerPill.swift
import SwiftUI

/// Pure label logic for the top-of-player timer pill, kept separate from the
/// view so the mode → text mapping is unit-testable. Designed to grow a
/// pomodoro mode later ("2/4 · 18:42") without changing the pill's shape.
enum SleepTimerPillState {
    static func labelText(mode: SleepTimerMode, remainingSeconds: Int) -> String? {
        switch mode {
        case .off: return nil
        case .minutes: return sleepTimerCountdownText(remainingSeconds)
        case .endOfChapter: return "EOC"
        }
    }
}

/// The single timer home (audit B1): a bare moon glyph when no timer is armed
/// (inactive = bare glyph), a tinted chip with moon + countdown when armed
/// (active = filled chip). Tapping opens the arming/cancel menu either way.
struct SleepTimerPill: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Menu {
            menuItems
        } label: {
            if let label = SleepTimerPillState.labelText(mode: model.sleepTimerMode, remainingSeconds: model.sleepTimerRemainingSeconds) {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.subheadline.bold())
                    Text(label)
                        .font(.subheadline.monospacedDigit().bold())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(model.coverTheme.chip, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .foregroundStyle(model.artworkAccentColor ?? Color.accentColor)
            } else {
                Image(systemName: "moon.zzz")
                    .font(.body.bold())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text("Sleep Timer"))
        .accessibilityValue(Text(accessibilityValue))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            model.setSleepTimer(.minutes(15))
            Haptic.play(.light)
        } label: { Label("15 Minutes", systemImage: "15.circle") }
        Button {
            model.setSleepTimer(.minutes(30))
            Haptic.play(.light)
        } label: { Label("30 Minutes", systemImage: "30.circle") }
        Button {
            model.setSleepTimer(.minutes(45))
            Haptic.play(.light)
        } label: { Label("45 Minutes", systemImage: "45.circle") }
        Button {
            model.setSleepTimer(.minutes(60))
            Haptic.play(.light)
        } label: { Label("1 Hour", systemImage: "1.circle") }
        Divider()
        Button {
            model.setSleepTimer(.endOfChapter)
            Haptic.play(.light)
        } label: { Label("End of Chapter", systemImage: "book.closed") }
        if model.sleepTimerMode.isActive {
            Divider()
            Button(role: .destructive) {
                model.cancelSleepTimer()
                Haptic.play(.light)
            } label: { Label("Off", systemImage: "xmark.circle") }
        }
    }

    private var accessibilityValue: String {
        switch model.sleepTimerMode {
        case .off: return String(localized: "Off")
        case .minutes(let m):
            return String(localized: "\(m) minutes, \(model.sleepTimerRemainingSeconds) seconds remaining")
        case .endOfChapter: return String(localized: "End of Chapter")
        }
    }
}
```

- [ ] **Step 4: Swap it into UnifiedTopHeader**

In `EchoCore/Views/Components/UnifiedTopHeader.swift`:
- Replace the center `remainingTimeView` call (line 29) with `SleepTimerPill()`.
- Delete the now-unused `remainingTimeView` (lines 87–107) and `formattedRemainingTime` (lines 109–132).

```swift
                Spacer()

                // Center: the single timer home (audit B1). Book-remaining time
                // moved to the scrubber caption on Now Playing.
                SleepTimerPill()

                Spacer()
```

- [ ] **Step 5: Remove the sleep button from the bottom utility row**

In `EchoCore/Views/BottomToolbarView.swift`: delete `sleepTimerMenu` + `Spacer()` from the body HStack (lines 13–15), delete the `sleepTimerMenu` computed property (lines 100–157) and the `SleepTimerCountdownView` struct (lines 250–261). Body becomes:

```swift
        HStack {
            loopModeButton
            Spacer()
            speedButton
            Spacer()
            timelineButton
            Spacer()
            addBookmarkButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
```

(Keep the `.sleepTimer` case in `TransportControlsView` — that row is user-configurable and a user may still slot it there.)

- [ ] **Step 6: Run tests + build**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/SleepTimerPillStateTests 2>&1 | tail -5
```

Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Views/Components/SleepTimerPill.swift EchoTests/SleepTimerPillStateTests.swift \
  EchoCore/Views/Components/UnifiedTopHeader.swift EchoCore/Views/BottomToolbarView.swift
git commit -m "feat(player): single timer home pill at top, sleep leaves bottom row (audit B1)"
```

---

### Task 3: Utility row + dock — state by shape, not color (audit B2, A-minimum)

**Files:**
- Modify: `EchoCore/Views/BottomToolbarView.swift`

- [ ] **Step 1: Add a shared chip treatment and apply to the four buttons**

Active = filled `coverTheme.chip` circle behind an accent glyph; inactive = bare `.secondary` glyph. Add to `BottomToolbarView`:

```swift
    /// Audit B2: active state is carried by a filled chip (shape), not color
    /// alone. 44pt target either way.
    private func utilityChip<Content: View>(isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 44, height: 44)
            .background(isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Rectangle())
            .foregroundStyle(isActive ? AnyShapeStyle(model.artworkAccentColor ?? .accentColor) : AnyShapeStyle(.secondary))
    }
```

Then in each button label:
- `loopModeButton`: wrap the existing `ZStack` in `utilityChip(isActive: model.loopMode != .off) { ... }`, and delete the `.foregroundStyle(model.loopMode != .off ? ... : .secondary)` modifier on the Button.
- `speedButton`: label becomes `utilityChip(isActive: model.speed != 1.0) { Text(speedLabel).customFont(.headline) }` with the chip as a `Capsule` for the text variant — use `.background(..., in: Capsule())` via a `isCapsule: true` parameter OR simply keep `Circle` with `minWidth` — implement as a second helper:

```swift
    private func utilityTextChip(isActive: Bool, _ text: String) -> some View {
        Text(text)
            .customFont(.headline)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear), in: Capsule())
            .contentShape(Rectangle())
            .foregroundStyle(isActive ? AnyShapeStyle(model.artworkAccentColor ?? .accentColor) : AnyShapeStyle(.secondary))
    }
```

- `timelineButton`: `utilityChip(isActive: model.selectedTab == .timeline || model.selectedTab == .read) { Image(systemName: "list.bullet").font(.title2) }`, delete its `.foregroundStyle(...)` line, and add persistent-selection accessibility (design A minimum fix):

```swift
        .accessibilityLabel(Text("Toggle chapters list"))
        .accessibilityValue(Text(model.selectedTab == .nowPlaying ? String(localized: "Player") : model.selectedTab == .timeline ? String(localized: "Timeline") : String(localized: "Reader")))
        .accessibilityAddTraits((model.selectedTab == .timeline || model.selectedTab == .read) ? .isSelected : [])
```

- `addBookmarkButton`: momentary action — always `utilityChip(isActive: false) { ... }`.

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/BottomToolbarView.swift
git commit -m "feat(player): utility row active state by filled chip, dock selection a11y (audit B2/A)"
```

---

### Task 4: Eyebrow title block (audit B4)

**Files:**
- Modify: `EchoCore/Views/NowPlayingTab.swift:108-127` (`metadataArea`)

- [ ] **Step 1: Reorder + restyle the metadata area**

Book + author become a small-caps eyebrow **above**; chapter keeps the hero marquee line. Eyebrow taps through to book info (the existing `showBookSettings` closure). Replace `metadataArea`:

```swift
    private var metadataArea: some View {
        VStack(spacing: 5) {
            // Eyebrow: book + author in small caps, tappable → book info (audit B4)
            Button(action: showBookSettings) {
                Text(secondaryLineText)
                    .customFont(.caption, weight: .semibold, appFont: model.resolvedAppFont)
                    .textCase(.uppercase)
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .disabled(model.folderURL == nil)
            .accessibilityLabel(Text("Book info"))
            .accessibilityValue(Text(secondaryLineText))

            // Hero line: chapter title marquee — almost never truncates now
            MarqueeText(
                text: titleText,
                fontStyle: .title3,
                fontWeight: .bold,
                appFont: model.resolvedAppFont,
                foregroundStyle: .primary
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
```

(Check `customFont(_:weight:appFont:)` exists with that signature — `BottomToolbarView` uses `customFont(.caption2, weight: .semibold)`, so adjust to match the available overloads.)

- [ ] **Step 2: Build, commit**

```bash
xcodebuild build -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -3
git add EchoCore/Views/NowPlayingTab.swift
git commit -m "feat(player): eyebrow title block — book/author small caps above chapter hero (audit B4)"
```

---

### Task 5: Transport re-weight (audit B3) — ±30s get the metal, ring stays

**Files:**
- Modify: `EchoCore/Views/TransportControlsView.swift`
- Modify: `EchoCore/Views/Components/CircularProgressPlayButton.swift`

- [ ] **Step 1: Swap the visual weight of skip vs chapter-nav actions**

In `TransportControlsView.buttonForAction`:

`.skipBackward` label (currently 44pt bare) becomes the big chip (62pt, chip fill, accent glyph):

```swift
                Image(systemName: WatchAction.skipBackward.dynamicIconName(forDuration: settings.seekBackwardDuration))
                    .font(.system(size: isCompact ? 22 : 26, weight: .semibold))
                    .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                    .frame(width: isCompact ? 52 : 62, height: isCompact ? 52 : 62)
                    .background(Circle().fill(model.coverTheme.chip))
                    .contentShape(Rectangle())
```

`.skipForward`: same treatment, mirrored icon name (already dynamic).

`.previousTrack` label (currently 72pt chip) becomes the quiet outboard glyph:

```swift
                Image(systemName: "backward.end.fill")
                    .font(.system(size: isCompact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: isCompact ? 40 : 44, height: isCompact ? 40 : 44)
                    .contentShape(Rectangle())
```

`.nextTrack`, `.previousSection`, `.nextSection`: same quiet treatment (`forward.end.fill` / `backward.fill` / `forward.fill`).

- [ ] **Step 2: Resize the play button to the non-print mock (ring kept — chat-1 correction)**

In `CircularProgressPlayButton`: ring `86 → 92`, stroke `3.5 → 3`, center button `74 → 78`, glyph `34 → 36`. Four frame edits + two stroke-width edits (lines 37–47, 59, 63).

- [ ] **Step 3: Build, run NowPlayingLayoutTests**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/NowPlayingLayoutTests 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Views/TransportControlsView.swift EchoCore/Views/Components/CircularProgressPlayButton.swift
git commit -m "feat(player): re-weight transport — ±30s big chips, chapter nav outboard quiet (audit B3)"
```

---

### Task 6: Book-progress hairline + caption + elapsed/remaining toggle (audit B5)

**Files:**
- Create: `EchoCore/Views/Components/BookProgressTrack.swift`
- Create: `EchoTests/BookProgressTrackModelTests.swift`
- Modify: `EchoCore/State/PlaybackState.swift` (add `durationText`)
- Modify: `EchoCore/Services/PlaybackProgressPresenter.swift` (set `durationText` at the 3 sites that set `progressText`)
- Modify: `EchoCore/ViewModels/PlayerModel.swift:183-184` (expose `durationText`)
- Modify: `EchoCore/Views/PlayerScrubberView.swift`

- [ ] **Step 1: Write the failing tests (pure model)**

```swift
// EchoTests/BookProgressTrackModelTests.swift
import Testing
@testable import EchoCore

struct BookProgressTrackModelTests {
    private func chapter(_ index: Int, start: Double, end: Double) -> Chapter {
        Chapter(index: index, title: "Ch \(index + 1)", startSeconds: start, endSeconds: end, isEnabled: true)
    }

    @Test func tickFractionsAreInteriorChapterStarts() {
        let chapters = [chapter(0, start: 0, end: 100), chapter(1, start: 100, end: 300), chapter(2, start: 300, end: 400)]
        let fractions = BookProgressTrackModel.tickFractions(chapters: chapters, totalDuration: 400)
        #expect(fractions == [0.25, 0.75])  // chapter 0's start (0.0) is skipped
    }

    @Test func tickFractionsEmptyWhenNoDuration() {
        #expect(BookProgressTrackModel.tickFractions(chapters: [], totalDuration: 0).isEmpty)
    }

    @Test func captionMatchesMockFormat() {
        let caption = BookProgressTrackModel.caption(
            bookFraction: 0.04, chapterTitle: "Prologue", chapterCount: 8
        )
        #expect(caption == "4% of book · Prologue of 8 chapters")
    }

    @Test func captionOmitsChapterPartWhenSingleChapter() {
        let caption = BookProgressTrackModel.caption(bookFraction: 0.5, chapterTitle: nil, chapterCount: 1)
        #expect(caption == "50% of book")
    }
}
```

(Check `Chapter`'s memberwise init parameter order in `EchoCore/Models/Chapter.swift` before writing — adjust to the real signature.)

- [ ] **Step 2: Run to verify FAIL, then implement**

```swift
// EchoCore/Views/Components/BookProgressTrack.swift
import SwiftUI

/// Pure math for the book-progress hairline (audit B5): chapter-boundary tick
/// fractions and the caption string, separated from the Canvas for testing.
enum BookProgressTrackModel {
    /// Fractions (0,1) of total book duration where interior chapter
    /// boundaries fall. Chapter 0's start (= 0) is skipped.
    static func tickFractions(chapters: [Chapter], totalDuration: Double) -> [Double] {
        guard totalDuration > 0 else { return [] }
        return chapters.dropFirst().compactMap { chapter in
            let f = chapter.startSeconds / totalDuration
            return (f > 0 && f < 1) ? f : nil
        }
    }

    static func caption(bookFraction: Double, chapterTitle: String?, chapterCount: Int) -> String {
        let pct = Int((bookFraction * 100).rounded())
        guard chapterCount > 1, let title = chapterTitle, !title.isEmpty else {
            return String(localized: "\(pct)% of book")
        }
        return String(localized: "\(pct)% of book · \(title) of \(chapterCount) chapters")
    }
}

/// The 3pt hairline book track under the chapter scrubber: filled to the book
/// fraction in translucent accent, with 1pt ticks at chapter boundaries.
struct BookProgressTrack: View {
    let bookFraction: Double
    let tickFractions: [Double]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(accent.opacity(0.55))
                    .frame(width: max(0, geo.size.width * min(max(bookFraction, 0), 1)))
                Canvas { context, size in
                    for fraction in tickFractions {
                        let x = size.width * fraction
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: -1))
                        path.addLine(to: CGPoint(x: x, y: size.height + 1))
                        context.stroke(path, with: .color(.primary.opacity(0.25)), lineWidth: 1)
                    }
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)  // caption below carries the same info
    }
}
```

Run the test again. Expected: PASS.

- [ ] **Step 3: Add `durationText` to the state pipeline**

`PlaybackState.swift` (next to line 34):

```swift
    var durationText: String = "--:--"
```

`PlaybackProgressPresenter.swift`: at each site that sets `progressText` (lines ~102, ~129, ~151), also set the un-negated total for the same scope, e.g. where chapter remaining is computed:

```swift
            state.progressText = "-\(NowPlayingController.formatTime(remaining))"
            state.durationText = NowPlayingController.formatTime(scopeDuration / speed)
```

(`scopeDuration` = the same duration variable each branch already computes its `remaining` from — reuse the local variable in each branch; in the reset branches set `durationText = "--:--"`.)

`PlayerModel.swift` (next to line 183):

```swift
    var durationText: String { state.durationText }
```

- [ ] **Step 4: Wire into PlayerScrubberView**

In `PlayerScrubberView`:
- Add `@AppStorage("scrubberShowsRemaining") private var showsRemaining = true`.
- Trailing label becomes tappable and switches text (audit B5: "tap the time labels to toggle elapsed/remaining"):

```swift
                HStack {
                    timeLabel(model.elapsedText, alignment: .leading)
                    Spacer()
                    Button {
                        showsRemaining.toggle()
                        Haptic.play(.light)
                    } label: {
                        timeLabel(showsRemaining ? model.progressText : model.durationText, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(showsRemaining ? "Time remaining" : "Chapter duration"))
                    .accessibilityHint(Text("Double tap to toggle"))
                }
                .padding(.horizontal, 4)
```

(Apply the same swap to the compact-layout HStack.)
- Below that HStack (default layout only — compact stays one-line), add the hairline + caption, only when a real book is loaded:

```swift
                if model.chapters.count >= 2 {
                    let totalDuration = model.isMultiM4B ? model.totalBookDuration : (model.durationSeconds ?? 0)
                    BookProgressTrack(
                        bookFraction: bookFraction,
                        tickFractions: BookProgressTrackModel.tickFractions(chapters: model.chapters, totalDuration: totalDuration),
                        accent: model.artworkAccentColor ?? .accentColor
                    )
                    .padding(.top, 9)
                    .padding(.horizontal, 4)

                    Text(BookProgressTrackModel.caption(
                        bookFraction: bookFraction,
                        chapterTitle: currentLogicalChapter?.title,
                        chapterCount: model.chapters.count
                    ))
                    .customFont(.caption2, appFont: model.resolvedAppFont)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
```

with a `bookFraction` helper mirroring the computation in `TransportControlsView.buttonForAction` `.playPause` (book elapsed incl. multi-M4B offset ÷ total).

- [ ] **Step 5: Build + run both new test suites, commit**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/BookProgressTrackModelTests 2>&1 | tail -5
git add EchoCore/Views/Components/BookProgressTrack.swift EchoTests/BookProgressTrackModelTests.swift \
  EchoCore/State/PlaybackState.swift EchoCore/Services/PlaybackProgressPresenter.swift \
  EchoCore/ViewModels/PlayerModel.swift EchoCore/Views/PlayerScrubberView.swift
git commit -m "feat(player): book-progress hairline with chapter ticks + elapsed/remaining toggle (audit B5)"
```

---

### Task 7: ChapterPartGrouper — part section headers (audit C2)

**Files:**
- Create: `EchoCore/Services/ChapterPartGrouper.swift`
- Create: `EchoTests/ChapterPartGrouperTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// EchoTests/ChapterPartGrouperTests.swift
import Testing
@testable import EchoCore

struct ChapterPartGrouperTests {
    @Test func groupsConsecutiveSharedPartPrefixes() {
        let titles = [
            "Part One – The Meaning of Things: 1. Attractive Things Work Better",
            "Part One – The Meaning of Things: 2. The Multiple Faces of Emotion",
            "Part Two – Design in Practice: 3. Three Levels of Design",
            "Part Two – Design in Practice: 4. Fun and Games",
        ]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 2)
        #expect(groups[0].header == "Part One – The Meaning of Things")
        #expect(groups[0].rowTitles == ["1. Attractive Things Work Better", "2. The Multiple Faces of Emotion"])
        #expect(groups[1].header == "Part Two – Design in Practice")
        #expect(groups[1].rowTitles == ["3. Three Levels of Design", "4. Fun and Games"])
    }

    @Test func ungroupedTitlesYieldSingleHeaderlessGroup() {
        let titles = ["Prologue", "Chapter 1", "Chapter 2"]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 1)
        #expect(groups[0].header == nil)
        #expect(groups[0].rowTitles == titles)
    }

    @Test func singleChapterUnderAPartIsNotGrouped() {
        // A "prefix" shared by only one chapter is not a part.
        let titles = ["Part One: Only Child", "Epilogue"]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 1)
        #expect(groups[0].header == nil)
    }

    @Test func mixedPrefixedAndBareTitlesSplitCorrectly() {
        let titles = ["Prologue", "Part One: 1. A", "Part One: 2. B", "Epilogue"]
        let groups = ChapterPartGrouper.group(displayTitles: titles)
        #expect(groups.count == 3)
        #expect(groups[0].header == nil)
        #expect(groups[1].header == "Part One")
        #expect(groups[1].rowTitles == ["1. A", "2. B"])
        #expect(groups[2].header == nil)
    }
}
```

- [ ] **Step 2: Run to verify FAIL, then implement**

```swift
// EchoCore/Services/ChapterPartGrouper.swift
import Foundation

/// Audit C2: "Part Two – Design in Practice:" repeated on every row is
/// structure pretending to be content. This groups consecutive display titles
/// that share a part prefix ("Part …: " / "Part … – ", or any "<prefix>: "
/// shared by ≥2 consecutive rows) into sections, stripping the prefix from
/// row titles. Pure string → string; the view maps groups back to chapters
/// by running index.
enum ChapterPartGrouper {
    struct Group: Equatable {
        let header: String?
        let rowTitles: [String]
    }

    /// Splits "Part One – Foo: 1. Bar" into (part: "Part One – Foo", rest: "1. Bar").
    /// Returns nil when the title has no ": " separator.
    private static func splitPart(_ title: String) -> (part: String, rest: String)? {
        guard let sepRange = title.range(of: ": ") else { return nil }
        let part = String(title[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(title[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !part.isEmpty, !rest.isEmpty else { return nil }
        return (part, rest)
    }

    static func group(displayTitles: [String]) -> [Group] {
        var groups: [Group] = []
        var current: (header: String?, titles: [String], raw: [String]) = (nil, [], [])

        func flush() {
            guard !current.titles.isEmpty else { return }
            // A part with a single row isn't structure — restore raw titles.
            if current.header != nil && current.titles.count < 2 {
                groups.append(Group(header: nil, rowTitles: current.raw))
            } else {
                groups.append(Group(header: current.header, rowTitles: current.titles))
            }
            current = (nil, [], [])
        }

        for title in displayTitles {
            let split = splitPart(title)
            if let split, split.part == current.header {
                current.titles.append(split.rest)
                current.raw.append(title)
            } else if let split {
                flush()
                current = (split.part, [split.rest], [title])
            } else {
                if current.header != nil { flush() }
                current.header = nil
                current.titles.append(title)
                current.raw.append(title)
            }
        }
        flush()

        // Merge adjacent headerless groups produced by the single-row restore.
        var merged: [Group] = []
        for group in groups {
            if group.header == nil, let last = merged.last, last.header == nil {
                merged[merged.count - 1] = Group(header: nil, rowTitles: last.rowTitles + group.rowTitles)
            } else {
                merged.append(group)
            }
        }
        return merged
    }
}
```

Run tests. Expected: PASS (4 tests). Iterate on the implementation (not the tests) if edge cases fail.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Services/ChapterPartGrouper.swift EchoTests/ChapterPartGrouperTests.swift
git commit -m "feat(playlist): ChapterPartGrouper — part prefixes become section headers (audit C2)"
```

---

### Task 8: Chapter list — interaction inversion, part headers, segmented filter, search (audit C1–C4)

**Files:**
- Modify: `EchoCore/Views/PlaylistView.swift`

- [ ] **Step 1: Add `.partHeader` to `PlaylistRow` and emit it in `recomputePlaylistRows()`**

```swift
enum PlaylistRow: Identifiable {
    case partHeader(title: String, key: Int)
    case chapter(index: Int, chapter: Chapter, displayTitle: String)
    case track(index: Int, track: Track)
    case bookmark(Bookmark)

    var id: String {
        switch self {
        case .partHeader(let t, let key): return "part-\(key)-\(t)"
        case .chapter(_, let c, _): return "chapter-\(c.id)"
        case .track(_, let t):   return "track-\(t.id)"
        case .bookmark(let b):   return "bookmark-\(b.id.uuidString)"
        }
    }
    // sortKey unchanged; add `case .partHeader: return -.infinity` (unused — rows are emitted in order)
}
```

In `recomputePlaylistRows()` chapter mode: after `hierarchicalTitles` is computed, run `ChapterPartGrouper.group(displayTitles: hierarchicalTitles)` and walk groups with a running chapter index, emitting `.partHeader(title:key:)` before each group with a non-nil header, then the `.chapter` rows using the group's stripped `rowTitles[...]` as `displayTitle`. Bookmark interleaving stays keyed to each chapter as today.

In the `List` `ForEach` switch, render:

```swift
                        case .partHeader(let title, _):
                            Text(title)
                                .customFont(.caption, weight: .semibold, appFont: model.resolvedAppFont)
                                .textCase(.uppercase)
                                .kerning(0.8)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                                .padding(.top, 12)
                                .accessibilityAddTraits(.isHeader)
```

- [ ] **Step 2: Invert the row interaction (audit C1)**

Replace `chapterRowContent` body: row tap = toggle (+ `.rigid` haptic — unmissable state change per the design), trailing 44pt play button = seek. Leading circle is removed; the enabled state is communicated by the existing grey-out (opacity 0.35) plus a small leading `checkmark.circle.fill`/`circle` *indicator* (non-interactive, since the whole row is now the toggle):

```swift
    @ViewBuilder
    private func chapterRowContent(index: Int, chapter: Chapter, displayTitle: String) -> some View {
        HStack {
            // Whole-row tap toggles the chapter (audit C1): an accidental toggle
            // is harmless and visible; an accidental play loses your place.
            Button {
                model.toggleChapterEnabled(at: index)
                Haptic.play(.rigid)
            } label: {
                HStack {
                    Image(systemName: chapter.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chapter.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .foregroundStyle(.primary)
                        Text(formatDuration(chapter.endSeconds - chapter.startSeconds))
                            .customFont(.caption, appFont: model.resolvedAppFont)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.currentChapterIndex == index {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                            .accessibilityLabel(Text("Now playing"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(displayTitle))
            .accessibilityValue(Text(chapter.isEnabled ? String(localized: "Enabled") : String(localized: "Disabled")))
            .accessibilityHint(Text("Double tap to toggle this chapter"))

            // Trailing 44pt play button owns playback.
            Button {
                model.seek(toSeconds: chapter.startSeconds + 0.05)
                onRowTapped?(chapter.startSeconds)
                Haptic.play(.light)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Play \(displayTitle)"))
        }
        .foregroundStyle(chapter.isEnabled ? .primary : .tertiary)
        .opacity(chapter.isEnabled ? 1.0 : 0.35)
        // swipeActions + contextMenu unchanged from the current implementation
    }
```

Apply the same inversion to `trackRow` (toggle on row, trailing play button calling `model.skipToTrack(index)`).

- [ ] **Step 3: Segmented filter + inline search (audit C3, deviations 2–3)**

In `filterChipsRow`, replace the two `Toggle.buttonStyle(.button)` chips with:

```swift
            Picker("Show", selection: filterSelection) {
                Text("All").tag(PlaylistFilter.all)
                Text(model.chapters.count >= 2 ? "Chapters" : "Tracks").tag(PlaylistFilter.chapters)
                Text("Bookmarks").tag(PlaylistFilter.bookmarks)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
```

backed by:

```swift
    private enum PlaylistFilter: Hashable { case all, chapters, bookmarks }

    private var filterSelection: Binding<PlaylistFilter> {
        Binding(
            get: {
                switch (model.showChapters, model.showBookmarks) {
                case (true, false): return .chapters
                case (false, true): return .bookmarks
                default: return .all
                }
            },
            set: { newValue in
                switch newValue {
                case .all: model.showChapters = true; model.showBookmarks = true
                case .chapters: model.showChapters = true; model.showBookmarks = false
                case .bookmarks: model.showChapters = false; model.showBookmarks = true
                }
            }
        )
    }
```

Below the filter row, add an inline search field (state `@State private var searchText = ""`):

```swift
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search chapters & bookmarks", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
```

Filter in `recomputePlaylistRows()` output: when `searchText` is non-empty, keep `.chapter`/`.track`/`.bookmark` rows whose title contains the query (case/diacritic-insensitive via `localizedStandardContains`), drop `.partHeader` rows with no surviving children. Add `.onChange(of: searchText)` → recompute.

- [ ] **Step 4: Verify bottom inset (audit C4 — verify only)**

The list already ends with `Color.clear.frame(height: model.bottomInset)` (170pt). Confirm visually in the simulator later; no change expected.

- [ ] **Step 5: Build + full test pass for the playlist area, commit**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/ChapterPartGrouperTests 2>&1 | tail -5
git add EchoCore/Views/PlaylistView.swift
git commit -m "feat(playlist): row tap toggles, trailing play button, part headers, segmented filter + search (audit C1-C4)"
```

---

### Task 9: Reader — timestamp on active card only, themed sticky header (audit D1–D2)

**Files:**
- Modify: `EchoCore/Views/Cells/ParagraphCardCell.swift`
- Modify: `EchoCore/Views/Cells/HeadingCardCell.swift`
- Modify: `EchoCore/Views/ReaderTab+Alignment.swift` (context-menu title carries the timestamp)
- Modify: `EchoCore/Views/ReaderTab.swift:75-80` (header tint)

- [ ] **Step 1: Cells — anchor label visible only on the active card**

In both cells, `setManuallyAligned` stores but no longer always shows; `isActiveBlock` drives visibility:

```swift
    private var hasAnchorText = false

    var isActiveBlock: Bool = false {
        didSet {
            activeBar.isHidden = !isActiveBlock
            contentView.alpha = isActiveBlock ? 1.0 : 0.95
            // Audit D1: the timestamp doubles as the "you are here" marker —
            // visible on the active card only; others reveal via long-press.
            anchorLabel.isHidden = !(isActiveBlock && hasAnchorText)
        }
    }

    func setManuallyAligned(_ isAnchored: Bool, timeString: String?) {
        hasAnchorText = (timeString != nil)
        anchorLabel.text = timeString
        anchorLabel.textColor = isAnchored ? .systemRed : .secondaryLabel
        anchorLabel.isHidden = !(isActiveBlock && hasAnchorText)
    }
```

(`isActiveBlock` is assigned in `Coordinator.cell()` *before* `setManuallyAligned` in the current code — re-check order; the implementation above is order-independent because both paths recompute visibility.)

- [ ] **Step 2: Long-press reveal — context menu shows the timestamp**

In `ReaderTab+Alignment.swift` `buildContextMenu(block:)`, where the `UIMenu` is constructed, set its title to the block's timestamp so the long-press is the reveal:

```swift
        let timeString = viewModel?.audioStartTimeByBlockID[block.id]
            .map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
        let menuTitle = timeString.map { String(localized: "Audio position \($0)") } ?? ""
```

and pass `menuTitle` as the `UIMenu(title:...)` / `UIContextMenuConfiguration` menu title (adapt to the exact construction at lines 164–294).

- [ ] **Step 3: Sticky header tint (audit D2)**

In `ReaderTab.topChapterHeaderView`, the fallback when no chapter theme color is set becomes a cover-theme tint instead of nothing (flat gray band):

```swift
        .background(
            Rectangle()
                .fill(topChapterThemeColor.map { Color(hex: $0) } ?? model.coverTheme.accent)
                .opacity(topChapterThemeColor != nil ? 0.3 : 0.12)
        )
        .background(.ultraThinMaterial)
```

- [ ] **Step 4: Build, commit**

```bash
xcodebuild build -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -3
git add EchoCore/Views/Cells/ParagraphCardCell.swift EchoCore/Views/Cells/HeadingCardCell.swift \
  EchoCore/Views/ReaderTab+Alignment.swift EchoCore/Views/ReaderTab.swift
git commit -m "feat(reader): timestamp on active card only + cover-tinted sticky header (audit D1-D2)"
```

---

### Task 10: Settings fixes (audit E1–E6)

**Files:**
- Create: `EchoCore/Services/SmartRewindPolicy.swift`
- Create: `EchoTests/SmartRewindPolicyTests.swift`
- Modify: `EchoCore/ViewModels/PlayerModel.swift:913-942` (delegate to policy)
- Modify: `EchoCore/Views/SmartRewindSettingsView.swift` (live example footer)
- Modify: `EchoCore/Views/SettingsView.swift` (debug gating, labels, tint, book-overrides section)
- Modify: `EchoCore/Views/WatchAppSettingsView.swift:414` ("Sync Now")
- Modify: `EchoCore/Views/Components/UnifiedTopHeader.swift` (drop "Book Settings" menu item)
- Modify: `EchoCore/Views/BookSettingsView.swift` (extract reusable section)

- [ ] **Step 1: Extract SmartRewindPolicy with failing tests first**

```swift
// EchoTests/SmartRewindPolicyTests.swift
import Testing
@testable import EchoCore

struct SmartRewindPolicyTests {
    private let policy = SmartRewindPolicy(
        secondsThreshold: 30, secondsAmount: 10,
        minutesThreshold: 10, minutesAmount: 30,
        hoursThreshold: 2, hoursAmount: 120
    )

    @Test func shortPauseRewindsShortAmount() {
        #expect(policy.rewindAmount(forPausedDuration: 45) == 10)
    }

    @Test func mediumPauseOverridesShortRule() {
        #expect(policy.rewindAmount(forPausedDuration: 12 * 60) == 30)
    }

    @Test func longPauseOverridesAll() {
        #expect(policy.rewindAmount(forPausedDuration: 3 * 3600) == 120)
    }

    @Test func belowThresholdRewindsNothing() {
        #expect(policy.rewindAmount(forPausedDuration: 5) == 0)
    }

    @Test func exampleTextDescribesTheMediumRule() {
        #expect(policy.exampleText(forPausedMinutes: 12) == "Paused 12 min → rewinds 30 s")
    }
}
```

Implementation:

```swift
// EchoCore/Services/SmartRewindPolicy.swift
import Foundation

/// The three-tier smart-rewind rules as a pure value, shared by playback
/// (PlayerModel) and the settings screen's live example footer (audit E6:
/// teach by example, not by table).
struct SmartRewindPolicy {
    let secondsThreshold: Int   // seconds
    let secondsAmount: Int      // seconds
    let minutesThreshold: Int   // minutes
    let minutesAmount: Int      // seconds
    let hoursThreshold: Int     // hours
    let hoursAmount: Int        // seconds

    /// Longer-pause rules override shorter ones (same semantics as the
    /// previous PlayerModel.smartRewindAmount).
    func rewindAmount(forPausedDuration pausedDuration: TimeInterval) -> Int {
        var amount = 0
        if pausedDuration >= Double(secondsThreshold) { amount = secondsAmount }
        if pausedDuration >= Double(minutesThreshold * 60) { amount = minutesAmount }
        if pausedDuration >= Double(hoursThreshold * 3600) { amount = hoursAmount }
        return amount
    }

    func exampleText(forPausedMinutes minutes: Int) -> String {
        let amount = rewindAmount(forPausedDuration: Double(minutes * 60))
        return String(localized: "Paused \(minutes) min → rewinds \(amount) s")
    }
}
```

Refactor `PlayerModel.smartRewindAmount(for:)` to build a `SmartRewindPolicy` from settings (keeping the legacy-key fallback that follows it) and delegate. Run tests → PASS, plus `-only-testing:EchoTests/PlayerModelTests` to catch regressions.

- [ ] **Step 2: Live example footer in SmartRewindSettingsView**

Add to the "Medium Pauses" section a footer recomputed from current values:

```swift
                Section {
                    InlineStepperRow(/* unchanged Trigger after: */)
                    InlineStepperRow(/* unchanged Rewind by: */)
                } header: {
                    Text("Medium Pauses")
                } footer: {
                    Text(currentPolicy.exampleText(forPausedMinutes: max(settings.rewindPauseMinutesThreshold, 1) + 2))
                }
```

with:

```swift
    private var currentPolicy: SmartRewindPolicy {
        SmartRewindPolicy(
            secondsThreshold: settings.rewindPauseSecondsThreshold,
            secondsAmount: settings.rewindAmountAfterSeconds,
            minutesThreshold: settings.rewindPauseMinutesThreshold,
            minutesAmount: settings.rewindAmountAfterMinutes,
            hoursThreshold: settings.rewindPauseHoursThreshold,
            hoursAmount: settings.rewindAmountAfterHours
        )
    }
```

- [ ] **Step 3: Debug gating + label fixes (E3, E4, watch E)**

- `SettingsView.swift` line 91: wrap `SettingsSilenceDetectionSection()` call in `#if DEBUG` / `#endif` (audit: "for testing" slider visible in release).
- `SettingsAppearanceView` line 194: `Picker("Color Scheme", selection: $settings.appAppearance)` (was duplicate "Appearance").
- `SettingsAppearanceView` "Display Options" section: add footer

```swift
            Section {
                Toggle("Truncate Chapter to Ch.", isOn: /* unchanged binding */)
            } header: {
                Text("Display Options")
            } footer: {
                Text("Shortens \u{201C}Chapter 12\u{201D} to \u{201C}Ch. 12\u{201D} in tight spaces, like the watch and mini-player.")
            }
```

- `WatchAppSettingsView.swift` line 414: `Text("Sync Now")`.

- [ ] **Step 4: Resolved tint (E2)**

Add to `PlayerModel` (near `artworkAccentColor`):

```swift
    /// The accent the whole app should be tinted with (audit E2): the
    /// artwork-derived accent when the theme is "Artwork", else the static
    /// theme color, else nil (system default).
    var resolvedThemeTint: Color? {
        if settingsManager?.themeColor == ThemeColor.artwork.rawValue {
            return artworkAccentColor
        }
        return ThemeColor(rawValue: settingsManager?.themeColor ?? "")?.color
    }
```

- `EchoCoreApp.resolvedAccentColor`: replace body with `model.resolvedThemeTint`.
- `SettingsView.swift` line 147: `.tint(model.resolvedThemeTint)` (was static-only, which nil'd out the artwork accent inside the settings sheet — the audit's green-toggles bug).
- `SettingsAppearanceView` lines 199/255/256: delete the local `.tint`/`.accentColor` re-applications (inherit from sheet root).

- [ ] **Step 5: One settings surface (E1)**

- `BookSettingsView.swift`: extract its Form sections into `struct BookOverridesSections: View` (same file) taking `model`, so both the standalone sheet (kept — it's the eyebrow's "book info") and SettingsView render identical content.
- `SettingsView.swift`: insert at the top of the Form:

```swift
                if model.folderURL != nil {
                    Section {
                        BookOverridesSections(model: model)
                    } header: {
                        Text("This Book — overrides global")
                    } footer: {
                        Text("\u{201C}Inherit\u{201D} follows the global setting below.")
                    }
                }
```

(If `BookOverridesSections` contains its own `Section`s, hoist them to top-level rows in SettingsView instead — match whatever keeps Form grouping valid; verify in the simulator/preview.)
- `UnifiedTopHeader.swift`: remove the "Book Settings" menu item (lines 38–42) — one settings destination in the ellipsis (audit E1); book info remains one tap away via the eyebrow.

- [ ] **Step 6: Tests + build + commit**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/SmartRewindPolicyTests \
  -only-testing:EchoTests/BookSettingsOverrideStoreTests 2>&1 | tail -5
git add EchoCore/Services/SmartRewindPolicy.swift EchoTests/SmartRewindPolicyTests.swift \
  EchoCore/ViewModels/PlayerModel.swift EchoCore/Views/SmartRewindSettingsView.swift \
  EchoCore/Views/SettingsView.swift EchoCore/Views/WatchAppSettingsView.swift \
  EchoCore/Views/BookSettingsView.swift EchoCore/Views/Components/UnifiedTopHeader.swift \
  EchoCore/EchoCoreApp.swift
git commit -m "feat(settings): one settings surface, resolved tint, debug gating, label fixes, live rewind example (audit E1-E6)"
```

---

### Task 11: Mini-player — three user-configurable slots (chat-2)

**Files:**
- Modify: `EchoCore/Services/SettingsManager.swift` (new `miniPlayerPage` property + key + default + decode + registerDefaults)
- Create: `EchoTests/SettingsManagerMiniPlayerTests.swift`
- Modify: `EchoCore/Views/Components/PlayerControlBar.swift` (3 slots)
- Modify: `EchoCore/Views/PhonePlayerSettingsView.swift` (config pickers)

- [ ] **Step 1: Failing persistence test**

```swift
// EchoTests/SettingsManagerMiniPlayerTests.swift
import Testing
import Foundation
@testable import EchoCore

@MainActor
struct SettingsManagerMiniPlayerTests {
    @Test func defaultsToSkipPlaySkip() {
        #expect(SettingsManager.Defaults.miniPlayerPage == [.skipBackward, .playPause, .skipForward])
    }

    @Test func roundTripsThroughDefaults() throws {
        let suiteName = "miniplayer-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let encoded = try JSONEncoder().encode([WatchAction.bookmark, .playPause, .nextTrack])
        defaults.set(encoded, forKey: "miniPlayerPage")
        let decoded = try JSONDecoder().decode([WatchAction].self, from: try #require(defaults.data(forKey: "miniPlayerPage")))
        #expect(decoded == [.bookmark, .playPause, .nextTrack])
    }
}
```

(Follow the exact persistence pattern of `phonePage`; if `SettingsManager` has an injectable-defaults initializer, test through it instead of raw UserDefaults — check `SettingsManager.init` first and mirror `decodeWatchPage` usage.)

- [ ] **Step 2: SettingsManager additions**

```swift
// in Defaults:
        static let miniPlayerPage: [WatchAction] = [.skipBackward, .playPause, .skipForward]
// in Keys:
        static let miniPlayerPage = "miniPlayerPage"
// property (next to phonePage):
    var miniPlayerPage: [WatchAction] { didSet { defaults.set(try? JSONEncoder().encode(miniPlayerPage), forKey: Keys.miniPlayerPage) } }
// in init (next to phonePage decode):
        miniPlayerPage = Self.decodeWatchPage(key: Keys.miniPlayerPage, from: defaults, fallback: Defaults.miniPlayerPage)
// in registerDefaults dictionary (next to phonePage entry):
            Keys.miniPlayerPage: (try? JSONEncoder().encode(Defaults.miniPlayerPage)) ?? Data(),
```

- [ ] **Step 3: PlayerControlBar renders the 3 slots**

Replace the single trailing play/pause button with a slot row. The bar's full-surface tap still opens the player; the slots are separate buttons:

```swift
                Spacer()

                HStack(spacing: 2) {
                    ForEach(Array(settings.miniPlayerPage.prefix(3).enumerated()), id: \.offset) { _, action in
                        miniSlotButton(action)
                    }
                }
```

```swift
    /// Chat-2: "the mini player should have 3 buttons. User configurable."
    @ViewBuilder
    private func miniSlotButton(_ action: WatchAction) -> some View {
        Button {
            perform(action)
        } label: {
            Image(systemName: iconName(for: action))
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityName(for: action)))
    }

    private func iconName(for action: WatchAction) -> String {
        switch action {
        case .playPause: return model.isPlaying ? "pause.fill" : "play.fill"
        case .skipBackward: return WatchAction.skipBackward.dynamicIconName(forDuration: settings.seekBackwardDuration)
        case .skipForward: return WatchAction.skipForward.dynamicIconName(forDuration: settings.seekForwardDuration)
        default: return action.iconName
        }
    }

    private func perform(_ action: WatchAction) {
        switch action {
        case .playPause: model.togglePlayPause(); Haptic.play(.light)
        case .skipBackward: _ = model.skipBackward30(); Haptic.play(.light)
        case .skipForward: _ = model.skipForward30(); Haptic.play(.light)
        case .previousTrack: _ = model.skipBackwardNavigation(); Haptic.play(.light)
        case .nextTrack: _ = model.skipForwardNavigation(); Haptic.play(.light)
        case .previousSection: model.previousSectionOrRestart(); Haptic.play(.light)
        case .nextSection: model.nextSection(); Haptic.play(.light)
        case .loopMode: model.cycleLoopMode(); Haptic.play(.medium)
        case .bookmark:
            if let draft = model.bookmarkDraftAtCurrentTime() {
                model.activeBookmarkDraft = draft
                Haptic.play(.medium)
            }
        case .speed:
            let speeds = SettingsManager.Defaults.speedPresets
            if let index = speeds.firstIndex(of: model.speed) {
                model.setSpeed(speeds[(index + 1) % speeds.count])
            } else {
                model.setSpeed(1.0)
            }
        case .sleepTimer, .pomodoro, .empty: break
        }
    }

    private func accessibilityName(for action: WatchAction) -> String {
        switch action {
        case .playPause: return model.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        case .skipBackward: return String(localized: "Skip back \(settings.seekBackwardDuration) seconds")
        case .skipForward: return String(localized: "Skip forward \(settings.seekForwardDuration) seconds")
        case .previousTrack: return String(localized: "Previous chapter")
        case .nextTrack: return String(localized: "Next chapter")
        case .previousSection: return String(localized: "Previous section")
        case .nextSection: return String(localized: "Next section")
        case .loopMode: return String(localized: "Loop mode")
        case .bookmark: return String(localized: "Add bookmark")
        case .speed: return String(localized: "Playback speed")
        case .sleepTimer, .pomodoro, .empty: return ""
        }
    }
```

To make room, drop the marquee's secondary line when width is tight — keep it simple: keep title marquee, remove the second `Text(model.currentTitle)` line (the eyebrow pattern from Task 4 carries book identity in the full player; the mini-player gets chapter title + controls).

- [ ] **Step 4: Config UI in PhonePlayerSettingsView**

Add a section with three pickers (no drag-drop needed — pickers are simpler and accessible):

```swift
            Section("Mini-Player Buttons") {
                ForEach(0..<3, id: \.self) { slot in
                    Picker(String(localized: "Slot \(slot + 1)"), selection: Binding(
                        get: { settings.miniPlayerPage.indices.contains(slot) ? settings.miniPlayerPage[slot] : .empty },
                        set: { newAction in
                            var page = settings.miniPlayerPage
                            while page.count < 3 { page.append(.empty) }
                            page[slot] = newAction
                            settings.miniPlayerPage = page
                        }
                    )) {
                        ForEach(miniPlayerChoices) { action in
                            Label(miniPlayerChoiceName(action), systemImage: action.iconName).tag(action)
                        }
                    }
                }
            }
```

with `miniPlayerChoices: [WatchAction] = [.playPause, .skipBackward, .skipForward, .previousTrack, .nextTrack, .previousSection, .nextSection, .loopMode, .speed, .bookmark, .empty]` and a small name helper. (Place this section wherever PhonePlayerSettingsView's existing Form/Scroll content allows; match its container style.)

- [ ] **Step 5: Test, build, commit**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EchoTests/SettingsManagerMiniPlayerTests 2>&1 | tail -5
git add EchoCore/Services/SettingsManager.swift EchoTests/SettingsManagerMiniPlayerTests.swift \
  EchoCore/Views/Components/PlayerControlBar.swift EchoCore/Views/PhonePlayerSettingsView.swift
git commit -m "feat(mini-player): three user-configurable slots, default -30/play/+30 (design chat-2)"
```

---

### Task 12: Full verification + docs

- [ ] **Step 1: Full iOS test suite**

```bash
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -20
```

Expected: all suites pass (compare against any pre-existing failures recorded on main before branching — run the suite on main first if unsure).

- [ ] **Step 2: macOS + watch targets still build**

```bash
xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' 2>&1 | tail -3
xcodebuild build -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' 2>&1 | tail -3
```

Expected: BUILD SUCCEEDED ×2 (scheme names per project — verify with `xcodebuild -list`).

- [ ] **Step 3: Update docs**

- `CHANGELOG.md`: add entries under Unreleased for each audit fix.
- `README.md`: update the player feature bullets if they mention the old layout (sleep timer location, mini player).
- `make architecture` to regenerate `ARCHITECTURE.md` (new files: SleepTimerPill, BookProgressTrack, ChapterPartGrouper, SmartRewindPolicy).

- [ ] **Step 4: Commit docs**

```bash
git add CHANGELOG.md README.md ARCHITECTURE.md
git commit -m "docs: changelog + architecture for design-review HIG pass"
```
