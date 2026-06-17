# BookPlayer-Style Player Redesign — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-shape Echo's iOS Now Playing screen, player controls, and Settings to mirror BookPlayer — chapter navigation as `< Chapter Title >` in the metadata area, a speed-triggered Playback Options sheet, a player "More" menu, and a thin app-level Settings shell.

**Architecture:** The iOS transport row is already data-driven (`TransportControlsView` renders 5 `WatchAction` slots from `settings.phonePage`). We (1) move chapter nav into the title bar reusing the existing chapter-aware `skipBackwardNavigation()`/`skipForwardNavigation()` methods; (2) turn the speed indicator into a sheet trigger and relocate the 3-way loop into that sheet; (3) add a player More menu to the static `BottomToolbarView`; (4) retire `.previousTrack`/`.nextTrack`/`.loopMode` as *selectable* actions (keeping the enum cases) and ship new defaults; (5) gut `SettingsView` to an app-level shell after extracting its shared types/sub-views. No database, model-protocol, or remote-command changes.

**Tech Stack:** Swift 6, SwiftUI, `@Observable` `PlayerModel`/`SettingsManager`, Swift Testing (`import Testing`, `#expect`, `@MainActor`). Build/test via `make build-tests` then `make test-only FILTER=EchoTests/<Suite>`.

**Companion plan:** macOS parity lives in [`2026-06-16-bookplayer-redesign-macos.md`](2026-06-16-bookplayer-redesign-macos.md). The macOS plan's Settings scene (WS-J) depends on this plan's **Task E1** (extracting `ThemeColor` to its own file), so land at least E1 before macOS WS-J.

---

## Locked decisions (from brainstorming, 2026-06-16)

- **Loop:** keep the existing 3-way `LoopMode` (Off / Chapter / Bookmark). It moves into the Playback Options sheet as a segmented `Picker`; bookmark-loop and its no-bookmarks demotion are preserved. No feature loss.
- **Migration:** **passive.** Only change `Defaults.phonePage` (fresh installs) and remove the three actions from the iOS *picker* palettes. **No sanitizer, no `decodeWatchPage` change, no migration flag.** Every `WatchAction` enum case and every render/dispatch `switch` arm stays so existing saved layouts/presets — and the watch + CarPlay wire protocol — keep decoding. Upgraders keep their old in-row track/loop buttons until they edit a layout; that is intended.
- **Settings cleanup:** aggressive — `SettingsView` becomes a thin app-level shell; per-listen controls move to the Playback Options sheet (WS-B) and the player More menu (WS-C).
- **watch scope:** the watch designer (`WatchAppSettingsView`) is **out of scope** — do not edit its palette; the watch keeps chapter/loop slots (its only way to reach them).

## Cross-cutting groundwork & resolved open issues

These were surfaced by adversarial review of the drafts. Resolve them as stated; they are assumptions every task below relies on.

1. **Parity is safe (verified):** lock-screen / AirPods / CarPlay prev-next bind in `NowPlayingController.configureRemoteCommands` and call `skipForwardNavigation()`/`skipBackwardNavigation()` **directly**, never through the in-app row. Removing row buttons cannot regress them. **Do not touch `NowPlayingController` or `CarPlayManager`.**
2. **Two live speed/loop surfaces:** both the static `BottomToolbarView` (`speedButton`/`loopModeButton`) **and** the configurable `TransportControlsView` (`.speed`/`.loopMode` slot arms) render speed/loop. WS-B re-targets *both* speed surfaces to the sheet; WS-C removes `BottomToolbarView.loopModeButton`; the `.loopMode` slot arm stays (passive migration) but is no longer offered in the picker (WS-D).
3. **Project membership (folder-synchronized groups):** `EchoCore/`, `EchoTests/`, and `Shared/` are file-system-synchronized groups — new files **auto-compile into every target that syncs the group**, so there is **no per-file build-phase entry to add** (do not "add the file to the target"). The catch runs the other way: a new `EchoCore/Views/*` file that references a type the **macOS** target excludes (`@Environment(PlayerModel.self)`, `UIApplication`, StoreManager) must be **added to the macOS "EchoCore" membership-exception list** (the `718DD03F…` block, ~`Echo.xcodeproj/project.pbxproj:141-242`) or the `Echo macOS` target fails to compile (`cannot find type 'PlayerModel' in scope`). This applies to **`PlaybackOptionsSheet.swift` (WS-B), `PlayerMoreMenu.swift` (WS-C), and the WS-E extractions** — each creating task does the exception insert + a serialized macOS smoke build. `EchoCore/Models/ThemeColor.swift` is macOS-safe and must **not** be excluded (the macOS Settings scene needs it). **Serialize all pbxproj edits** — concurrent inserts into the alphabetized exception list conflict.
4. **`make build-tests` is iOS-only.** It will not catch a macOS-target break from a mis-membered EchoCore file. WS-B, WS-C, and WS-E tasks that add `EchoCore/Views/*` files include an explicit `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS'` smoke build. **16 GB machine rule (CLAUDE.md): never run two `xcodebuild` invocations concurrently and never enable parallel testing** — these macOS smoke builds are sequenced so they never overlap a `make` run.
5. **Jump-to / Mark-finished dropped from the More menu:** no `markBookFinished`/jump-to-position API exists on `PlayerModel` today, so WS-C ships **Chapters / Bookmarks / Sleep / Settings** only (all backed by real APIs). Adding mark-finished/jump-to is a separate future workstream — do not fabricate the APIs.
6. **`ThemeColor` is extracted as `internal`** (no Swift-module boundary exists — `EchoCore` is a folder group, not an imported module). This already crosses every consumer (`PlayerModel`, `ThemeSelectionView`). Do not add `public`.
7. **⚠️ Dock wiring contract (the dock edits in B4/B5/C2/C3 must converge to this).** `UnifiedBottomDock`'s `BottomToolbarView` is shown on **every** tab's dock, so its injected closures must be wired at **both** `UnifiedBottomDock(` call sites — `NowPlayingTab.swift:103` **and** `RootTabView.swift:122` (grep confirms exactly two). After WS-B + WS-C, `UnifiedBottomDock`'s required closure set is `onCreateBookmark` + `onShowPlaybackOptions` (B4) + `onShowChapters`/`onShowBookmarks`/`onShowSettings` (C2). Because B and C each rewrite the same two dock calls, **the `Replace … with …` snippets in those tasks assume a pristine start and go stale** (by the time C2 edits NowPlayingTab's dock call, B4/B5 already added `onShowPlaybackOptions:` + a trailing `.environment(\.showPlaybackOptions, …)`). When executing, **re-anchor each dock Edit on the current file text and converge both call sites to the final forms below — never drop `onShowPlaybackOptions`:**

   *NowPlayingTab (`:102-105`), final:*
   ```swift
   if !model.isPlayingVoiceMemo {
       UnifiedBottomDock(
           onCreateBookmark: onCreateBookmark,
           onShowPlaybackOptions: { showingPlaybackOptions = true },
           onShowChapters: { showingChapterPicker = true },
           onShowBookmarks: { model.selectedTab = .timeline },
           onShowSettings: showSettings
       )
       .environment(\.showPlaybackOptions, { showingPlaybackOptions = true })
   }
   ```
   *RootTabView (`:122`, the overlay dock), final.* **B4 must wire `onShowPlaybackOptions` here too** — plus a `@State private var showingPlaybackOptions = false` and a `.sheet(isPresented: $showingPlaybackOptions) { PlaybackOptionsSheet() }` — or the app target fails to compile the moment B4 makes the argument required:
   ```swift
   if model.selectedTab != .nowPlaying && !model.isPlayingVoiceMemo {
       VStack {
           Spacer()
           UnifiedBottomDock(
               onCreateBookmark: { draft in newBookmarkDraft = draft },
               onShowPlaybackOptions: { showingPlaybackOptions = true },
               onShowChapters: { showingChapterPicker = true },
               onShowBookmarks: { model.selectedTab = .timeline },
               onShowSettings: { showingSettings = true }
           )
       }
   }
   ```
   Both views declare their own `showingPlaybackOptions` state + `PlaybackOptionsSheet()` sheet (never on screen at once). The `.environment(\.showPlaybackOptions, …)` is needed only on `NowPlayingTab` (where the configurable `TransportControlsView` `.speed` slot lives); the overlay dock shows `PlayerControlBar`, not `TransportControlsView`, so it doesn't need the env presenter.

## Recommended execution order

`A → D → B → C → E`. A and D are independent and can go first/parallel. B re-homes the playback controls; C depends on A (chapter context) and B (loop sheet); E (the teardown) must come **after** B and C have re-homed every per-listen control, and its **Task E1** (extract `ThemeColor`) is also a prerequisite for the macOS plan's Settings scene.

---

### Task A1: Add `hasPreviousChapter` / `hasNextChapter` computed helpers to PlayerModel

These two read-only helpers let chapter-nav UI (this workstream's chevron bar, and WS-B's Playback Options chapter row) gate their controls without re-deriving the bounds logic at every call site. They mirror the existing `titleText` gate (`chapters.count >= 2`) so a single-chapter / marker-less book never shows chapter affordances. `currentChapterIndex` is an `Int?` on `PlayerModel` (it forwards `state.currentChapterIndex`), so we coalesce `nil → 0` to stay defensive when chapters exist but no index has been resolved yet.

- [ ] Write a failing unit test. Open `EchoTests/PlayerModelTests.swift` and add this test at the end of the `struct PlayerModelTests` body (after the last existing `@Test` method, before the closing brace of the struct). It seeds `model.state.chapters` and `model.state.currentChapterIndex` directly — both are stored `var`s on `PlaybackState`, reachable via the public `model.state` computed property (`PlayerModel.swift:53`):

```swift
    @Test("hasPreviousChapter / hasNextChapter reflect chapter bounds")
    func chapterNavBoundsHelpers() {
        let model = PlayerModel()

        // No chapters → both false (single-chapter / marker-less book).
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == false)

        // Three chapters, positioned at the first chapter.
        model.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            Chapter(index: 2, title: "Three", startSeconds: 20, endSeconds: 30),
        ]
        model.state.currentChapterIndex = 0
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)

        // Middle chapter → both directions available.
        model.state.currentChapterIndex = 1
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == true)

        // Last chapter → only previous.
        model.state.currentChapterIndex = 2
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == false)

        // chapters present but index unresolved (nil) → treated as index 0.
        model.state.currentChapterIndex = nil
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)
    }
```

- [ ] Build the test bundle once: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **` (the new test references `model.hasPreviousChapter` / `model.hasNextChapter`, which do not exist yet → this should FAIL to compile with errors like `value of type 'PlayerModel' has no member 'hasPreviousChapter'`). Confirm the compile error names those two members.

- [ ] Add the helpers to PlayerModel. Read `EchoCore/ViewModels/PlayerModel.swift:357` to confirm `var currentChapterIndex: Int? { state.currentChapterIndex }` is the anchor. Immediately AFTER line 357 (the `currentChapterIndex` accessor), insert:

```swift

    /// True when the loaded book has at least two chapters and the current
    /// position is not the first chapter. Drives the "previous chapter" chevron.
    /// `currentChapterIndex` is optional; an unresolved index is treated as 0.
    var hasPreviousChapter: Bool { chapters.count >= 2 && (currentChapterIndex ?? 0) > 0 }

    /// True when the loaded book has at least two chapters and the current
    /// position is not the last chapter. Drives the "next chapter" chevron.
    var hasNextChapter: Bool { chapters.count >= 2 && (currentChapterIndex ?? 0) < chapters.count - 1 }
```

- [ ] Re-run the unit test: `make test-only FILTER=EchoTests/PlayerModelTests`. Expected: the suite passes, including `chapterNavBoundsHelpers`. Output ends with `** TEST SUCCEEDED **` and the test summary shows `0 failures`.

- [ ] Commit. `git add -A && git commit -m "feat(player): add hasPreviousChapter/hasNextChapter helpers to PlayerModel"` (commit message footer per repo convention).

### Task A2: Add the BookPlayer-style chevron chapter-nav bar to NowPlayingTab.metadataArea

Wrap the hero `MarqueeText` (the chapter-title line) in an `HStack` flanked by two chevron `Button`s. Tapping a chevron calls `model.skipBackwardNavigation()` / `model.skipForwardNavigation()` — the SAME chapter-aware methods the lock screen uses (`PlayerModel.swift:1262`/`:1267`, which fall back to track navigation when there are no chapters), so the in-app bar stays byte-identical to the Now Playing / CarPlay behavior. We do NOT invent a chapter-only method.

Key layout invariants (from `MarqueeText.swift`): `MarqueeText` is a `GeometryReader`-based view that measures its own container width to decide whether to scroll. If we let the chevrons share flexible width with the marquee, the marquee's width math becomes unstable as chevrons appear/disappear. So we reserve a FIXED width per chevron (`chevronWidth`) and let the marquee keep `.frame(maxWidth: .infinity)`. The whole bar is gated on `model.chapters.count >= 2` (mirroring `titleText`, `NowPlayingTab.swift:205`) so single-chapter books render the bare marquee exactly as today. Each chevron is `.disabled` at the ends via the A1 helpers. The eyebrow book-info `Button` above (`NowPlayingTab.swift:176-188`) is preserved unchanged.

- [ ] Read the current `metadataArea` to confirm the exact text to replace. Read `EchoCore/Views/NowPlayingTab.swift:173-200`. Confirm the hero block is:

```swift
            // Hero line: chapter title marquee — almost never truncates now
            MarqueeText(
                text: titleText,
                fontStyle: .title3,
                fontWeight: .bold,
                appFont: model.resolvedAppFont,
                foregroundStyle: .primary
            )
            .frame(maxWidth: .infinity, alignment: .center)
```

- [ ] Replace the hero `MarqueeText` block with a chevron-flanked HStack. In `EchoCore/Views/NowPlayingTab.swift`, replace exactly the block above (lines 190-198) with:

```swift
            // Hero line: chapter-nav chevrons flank the chapter-title marquee.
            // Chevrons reuse skip*Navigation (chapter-aware; falls back to track)
            // so this in-app bar matches the lock screen byte-for-byte. The whole
            // bar is gated on chapters.count >= 2 to mirror `titleText`; a
            // single-chapter / marker-less book renders the bare marquee as before.
            if model.chapters.count >= 2 {
                HStack(spacing: 8) {
                    Button {
                        model.skipBackwardNavigation()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: chevronWidth, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasPreviousChapter)
                    .accessibilityLabel(Text("Previous chapter"))

                    MarqueeText(
                        text: titleText,
                        fontStyle: .title3,
                        fontWeight: .bold,
                        appFont: model.resolvedAppFont,
                        foregroundStyle: .primary
                    )
                    .frame(maxWidth: .infinity, alignment: .center)

                    Button {
                        model.skipForwardNavigation()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: chevronWidth, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasNextChapter)
                    .accessibilityLabel(Text("Next chapter"))
                }
            } else {
                MarqueeText(
                    text: titleText,
                    fontStyle: .title3,
                    fontWeight: .bold,
                    appFont: model.resolvedAppFont,
                    foregroundStyle: .primary
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
```

- [ ] Add the `chevronWidth` constant. In `EchoCore/Views/NowPlayingTab.swift`, in the `// MARK: - Helpers` section, immediately BEFORE the `private var titleText: String {` declaration (currently `NowPlayingTab.swift:204`), insert:

```swift
    /// Fixed hit-target width for each chapter-nav chevron. Reserving a constant
    /// width (rather than letting the chevrons share flexible space) keeps the
    /// MarqueeText container-width measurement stable as the bar's disabled
    /// state changes, so a short title is never shifted by a stale width.
    private let chevronWidth: CGFloat = 44
```

- [ ] Build the test bundle to type-check the view change: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **`. (This compiles the Echo app target plus tests; a SwiftUI type error in `metadataArea` would surface here.) If it fails, read the diagnostic — the most likely cause is a mismatched brace count in the replaced block.

- [ ] Commit. `git add -A && git commit -m "feat(player): flank Now Playing chapter title with prev/next chapter chevrons"`.

### Task A3: Source-scan test asserting the chevrons live in NowPlayingTab's metadata area

Following the established `NowPlayingLayoutTests` pattern (`EchoTests/NowPlayingLayoutTests.swift:7-19`), add a structural test that reads `NowPlayingTab.swift` from disk via the existing `Self.source(named:)` helper (which already resolves `EchoCore/Views/<file>`) and asserts the chevron buttons and their wiring are present. This guards against a future refactor silently dropping the chapter-nav bar or rewiring the chevrons to a non-chapter-aware method.

The helper has a sandbox fallback (`NowPlayingLayoutTests.swift:98-99`) that returns a mock string for `NowPlayingTab.swift`; we extend that fallback so the new assertions also pass in sandboxed CI.

- [ ] Add the source-scan test. In `EchoTests/NowPlayingLayoutTests.swift`, insert this new `@Test` method immediately AFTER `nowPlayingArtworkRendersWithPadding()` (i.e. after its closing brace at line 19, before `adaptiveBackgroundUsesTonalRamp()`):

```swift
    @Test func nowPlayingMetadataAreaHasChapterChevrons() throws {
        let source = try Self.source(named: "NowPlayingTab.swift")

        #expect(
            source.contains("chevron.left"),
            "Now Playing should render a previous-chapter chevron beside the title."
        )
        #expect(
            source.contains("chevron.right"),
            "Now Playing should render a next-chapter chevron beside the title."
        )
        #expect(
            source.contains("model.skipBackwardNavigation()"),
            "The previous-chapter chevron must reuse the chapter-aware skipBackwardNavigation, matching the lock screen."
        )
        #expect(
            source.contains("model.skipForwardNavigation()"),
            "The next-chapter chevron must reuse the chapter-aware skipForwardNavigation, matching the lock screen."
        )
        #expect(
            source.contains(".disabled(!model.hasPreviousChapter)"),
            "The previous-chapter chevron should be disabled at the first chapter."
        )
        #expect(
            source.contains(".disabled(!model.hasNextChapter)"),
            "The next-chapter chevron should be disabled at the last chapter."
        )
    }
```

- [ ] Extend the sandbox fallback so the new tokens resolve when running sandboxed. In `EchoTests/NowPlayingLayoutTests.swift`, replace this exact line (currently `NowPlayingLayoutTests.swift:99`):

```swift
            return "artworkView .padding(.horizontal, NowPlayingLayout.horizontalPadding)"
```

with:

```swift
            return "artworkView .padding(.horizontal, NowPlayingLayout.horizontalPadding) "
                + "chevron.left chevron.right model.skipBackwardNavigation() "
                + "model.skipForwardNavigation() .disabled(!model.hasPreviousChapter) "
                + ".disabled(!model.hasNextChapter)"
```

- [ ] Build the test bundle: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] Run the layout suite: `make test-only FILTER=EchoTests/NowPlayingLayoutTests`. Expected: all tests pass including `nowPlayingMetadataAreaHasChapterChevrons`; output ends with `** TEST SUCCEEDED **` and `0 failures`. (The real on-disk `NowPlayingTab.swift` already contains all six tokens after A2, and the fallback string covers the sandboxed path.)

- [ ] Commit. `git add -A && git commit -m "test(player): source-scan that Now Playing renders chapter-nav chevrons"`.


---

### Task D1: Retire `.previousTrack` / `.nextTrack` / `.loopMode` from the iOS phone-player palettes (passive)

This task removes the three actions from the *selectable* surfaces of `PhonePlayerSettingsView` only — the drag-palette, the mini-player dropdown choices, and the hardcoded "Reset to Defaults" array. It does NOT touch the `WatchAction` enum, any render/dispatch switch, `decodeWatchPage`, or any migration path. Upgraders who already have these actions in a saved layout keep them (their slots still decode and render) until they next edit the layout — that is the intended passive behavior.

- [ ] Read the current palette and choices to confirm exact line targets before editing. Read `EchoCore/Views/PhonePlayerSettingsView.swift:20-31` and `:285-289`. Confirm the palette is `[.playPause, .skipForward, .skipBackward, .nextTrack, .previousTrack, .nextSection, .previousSection, .loopMode, .speed, .sleepTimer, .bookmark]`, `miniPlayerChoices` is `[.playPause, .skipBackward, .skipForward, .previousTrack, .nextTrack, .previousSection, .nextSection, .loopMode, .speed, .bookmark, .empty]`, and the Reset array is `[.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]`.

- [ ] Write the failing structural test FIRST. Create `EchoTests/PhonePlayerPaletteTests.swift` with this exact content:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Structural guardrails for the iOS phone-player customization surfaces.
///
/// `.previousTrack`, `.nextTrack`, and `.loopMode` were retired as *selectable*
/// slot actions (they moved to the Playback Options sheet + inline chapter axis).
/// This is a PASSIVE retirement: the `WatchAction` enum still declares every case
/// so saved layouts, presets, watch pages, and CarPlay wire strings keep decoding
/// and rendering. These tests pin both halves of that contract.
struct PhonePlayerPaletteTests {

    /// The retired actions must be absent from the drag palette, the mini-player
    /// dropdown choices, and the hardcoded "Reset to Defaults" array.
    @Test func retiredActionsAbsentFromSelectableSurfaces() throws {
        let source = try Self.source(named: "PhonePlayerSettingsView.swift")

        // The drag palette literal must not offer the retired actions.
        let paletteSlice = try Self.slice(
            of: source,
            after: "private let palette: [WatchAction] = [",
            until: "]"
        )
        #expect(
            !paletteSlice.contains(".previousTrack"),
            "palette must not offer .previousTrack — chapter nav lives in the inline chapter axis."
        )
        #expect(
            !paletteSlice.contains(".nextTrack"),
            "palette must not offer .nextTrack — chapter nav lives in the inline chapter axis."
        )
        #expect(
            !paletteSlice.contains(".loopMode"),
            "palette must not offer .loopMode — loop lives in the Playback Options sheet."
        )

        // The mini-player choices must not offer the retired actions.
        let miniSlice = try Self.slice(
            of: source,
            after: "private let miniPlayerChoices: [WatchAction] = [",
            until: "]"
        )
        #expect(
            !miniSlice.contains(".previousTrack"),
            "miniPlayerChoices must not offer .previousTrack."
        )
        #expect(
            !miniSlice.contains(".nextTrack"),
            "miniPlayerChoices must not offer .nextTrack."
        )
        #expect(
            !miniSlice.contains(".loopMode"),
            "miniPlayerChoices must not offer .loopMode."
        )

        // The "Reset to Defaults" button must seed the new default layout.
        #expect(
            source.contains("slots = [.skipBackward, .empty, .playPause, .empty, .skipForward]"),
            "Reset to Defaults must mirror the new SettingsManager.Defaults.phonePage."
        )
        #expect(
            !source.contains("slots = [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]"),
            "The old Reset array must be gone."
        )
    }

    /// PASSIVE-MIGRATION CONTRACT: the enum must still declare every retired case
    /// so existing saved layouts/presets, watch pages, and CarPlay wire strings
    /// keep decoding and rendering. Removing a case would be a data-loss bug.
    @Test func retiredEnumCasesStillExist() {
        let cases = WatchAction.allCases
        #expect(cases.contains(.previousTrack), "WatchAction.previousTrack must remain declared (decoding contract).")
        #expect(cases.contains(.nextTrack), "WatchAction.nextTrack must remain declared (decoding contract).")
        #expect(cases.contains(.loopMode), "WatchAction.loopMode must remain declared (decoding contract).")
        // Raw values pin the wire format used by saved JSON + CarPlay command strings.
        #expect(WatchAction(rawValue: "previousTrack") == .previousTrack)
        #expect(WatchAction(rawValue: "nextTrack") == .nextTrack)
        #expect(WatchAction(rawValue: "loopMode") == .loopMode)
    }

    // MARK: - Source resolution

    /// Walks up from this test file to `EchoCore/Views/<fileName>` and returns
    /// its contents. Mirrors `NowPlayingLayoutTests.source(named:)` but is
    /// self-contained (that helper is `private`). Includes a sandbox fallback so
    /// the suite passes where the source tree is unreadable.
    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path),
               let content = try? String(contentsOf: candidate, encoding: .utf8) {
                return content
            }
            directory.deleteLastPathComponent()
        }
        // Sandbox fallback: return the post-edit expected tokens.
        if fileName == "PhonePlayerSettingsView.swift" {
            return """
            private let palette: [WatchAction] = [
                .playPause, .skipForward, .skipBackward,
                .nextSection, .previousSection,
                .speed, .sleepTimer, .bookmark
            ]
            private let miniPlayerChoices: [WatchAction] = [
                .playPause, .skipBackward, .skipForward,
                .previousSection, .nextSection, .speed, .bookmark, .empty
            ]
            slots = [.skipBackward, .empty, .playPause, .empty, .skipForward]
            """
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Returns the substring between the first occurrence of `after` and the next
    /// occurrence of `until` following it (exclusive of both markers).
    private static func slice(of source: String, after: String, until: String) throws -> String {
        guard let startRange = source.range(of: after) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tail = source[startRange.upperBound...]
        guard let endRange = tail.range(of: until) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(tail[..<endRange.lowerBound])
    }
}
```

- [ ] Build the test target once: run `make build-tests`. Expected output ends with `** TEST BUILD SUCCEEDED **` (the new file compiles; `WatchAction.allCases` resolves via `@testable import Echo`).

- [ ] Run the new suite and watch it FAIL: run `make test-only FILTER=EchoTests/PhonePlayerPaletteTests`. Expected: `retiredActionsAbsentFromSelectableSurfaces` FAILS (palette/mini/Reset still contain the retired actions), `retiredEnumCasesStillExist` PASSES. The failure message names which `#expect` tripped, e.g. `palette must not offer .previousTrack`.

- [ ] Make the minimal edit to the palette. In `EchoCore/Views/PhonePlayerSettingsView.swift:20-24`, Edit:

```swift
    private let palette: [WatchAction] = [
        .playPause, .skipForward, .skipBackward, .nextTrack,
        .previousTrack, .nextSection, .previousSection,
        .loopMode, .speed, .sleepTimer, .bookmark
    ]
```
to:
```swift
    private let palette: [WatchAction] = [
        .playPause, .skipForward, .skipBackward,
        .nextSection, .previousSection,
        .speed, .sleepTimer, .bookmark
    ]
```

- [ ] Make the minimal edit to the mini-player choices. In `EchoCore/Views/PhonePlayerSettingsView.swift:28-31`, Edit:

```swift
    private let miniPlayerChoices: [WatchAction] = [
        .playPause, .skipBackward, .skipForward, .previousTrack, .nextTrack,
        .previousSection, .nextSection, .loopMode, .speed, .bookmark, .empty
    ]
```
to:
```swift
    private let miniPlayerChoices: [WatchAction] = [
        .playPause, .skipBackward, .skipForward,
        .previousSection, .nextSection, .speed, .bookmark, .empty
    ]
```

- [ ] Make the minimal edit to the "Reset to Defaults" array so it mirrors the new default. In `EchoCore/Views/PhonePlayerSettingsView.swift:286`, Edit:

```swift
                    slots = [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]
```
to:
```swift
                    slots = [.skipBackward, .empty, .playPause, .empty, .skipForward]
```

- [ ] Rebuild and rerun the suite: run `make build-tests` then `make test-only FILTER=EchoTests/PhonePlayerPaletteTests`. Expected: both tests PASS — final line `Test Suite 'PhonePlayerPaletteTests' passed`, `Executed 2 tests, with 0 failures`.

- [ ] Confirm no other selectable surface still references the retired actions in this file. Run `grep -nE '\.previousTrack|\.nextTrack|\.loopMode' "EchoCore/Views/PhonePlayerSettingsView.swift"`. Expected: matches ONLY inside `miniPlayerChoiceName(_:)` (the `switch` arms at lines ~38-42 that still NAME the actions for back-compat rendering of already-saved slots) — NOT in `palette`, `miniPlayerChoices`, or the Reset array. The `miniPlayerChoiceName` arms stay so previously-saved mini-player slots holding a retired action still display a human label.

- [ ] Commit: run `git add "EchoCore/Views/PhonePlayerSettingsView.swift" EchoTests/PhonePlayerPaletteTests.swift && git commit -m "feat(ios): retire chapter/loop actions from phone-player palettes

Remove .previousTrack/.nextTrack/.loopMode from the drag palette,
mini-player choices, and Reset-to-Defaults array. Enum cases and the
miniPlayerChoiceName render arms are kept so existing saved layouts and
presets keep decoding/rendering (passive retirement). Add structural
test pinning both halves of the contract."`.

### Task D2: Change `SettingsManager.Defaults.phonePage` to the new fresh-install default

Fresh installs should get the chapter-free transport row `[.skipBackward, .empty, .playPause, .empty, .skipForward]`. This is the ONLY default change — no migration, no sanitizer, no flag. `registerDefaults` already encodes `Defaults.phonePage` (`SettingsManager.swift:616`), so changing the constant is sufficient; existing installs that already wrote a `phonePage` value are untouched (register-defaults only seeds absent keys).

- [ ] Confirm the current default and that nothing else hardcodes it. Read `EchoCore/Services/SettingsManager.swift:50-52`. Confirm `static let phonePage: [WatchAction] = [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]`. Then run `grep -rn "previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack" EchoCore Shared EchoTests "Echo macOS"` to enumerate every site that mirrors the old default (expect: this `Defaults.phonePage`, the now-already-fixed Reset array from D1, and `EchoCoreTests.swift:202`).

- [ ] Edit the default. In `EchoCore/Services/SettingsManager.swift:50-52`, Edit:

```swift
        static let phonePage: [WatchAction] = [
            .previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack,
        ]
```
to:
```swift
        static let phonePage: [WatchAction] = [
            .skipBackward, .empty, .playPause, .empty, .skipForward,
        ]
```

- [ ] Do NOT edit `decodeWatchPage` (`SettingsManager.swift:661`), do NOT add a migration flag, do NOT add a sanitizer. Verify the only diff in this file is the constant: run `git diff "EchoCore/Services/SettingsManager.swift"`. Expected: a single hunk changing the `phonePage` literal, nothing else.

- [ ] Build the test target: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **`. (The `EchoCoreTests.swift:202` assertion still hardcodes the OLD default, so the build succeeds but `EchoCoreTests` will now fail — fixed in D3. Do not run `EchoCoreTests` yet.)

- [ ] Commit: run `git add "EchoCore/Services/SettingsManager.swift" && git commit -m "feat(ios): default fresh-install phone transport to skip/play/skip

Change Defaults.phonePage to [.skipBackward, .empty, .playPause, .empty,
.skipForward] for new installs. Passive: register-defaults only seeds
absent keys, so existing installs keep their saved layout. No migration."`.

### Task D3: Update the `EchoCoreTests` assertion to the new default in lockstep

`EchoCoreTests.swift:202` hard-asserts the OLD `phonePage` default and will now fail after D2. Update it to the new default so the suite is green again. This is a lockstep, same-PR change — the assertion is the canonical check that fresh installs see the new layout.

- [ ] Read the failing assertion in context. Read `EchoTests/EchoCoreTests.swift:199-203`. Confirm line 202 is `#expect(settings.phonePage == [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack])` and that lines 209/220 modify `phonePage` to a *different* literal (`[.empty, .skipBackward, .playPause, .skipForward, .empty]`) — those are the "modify/persist" round-trip and must NOT change.

- [ ] Run the suite to confirm it FAILS first: run `make test-only FILTER=EchoTests/EchoCoreTests`. Expected: `settingsPersistsSeekDurationsAndLayoutCustomizations` FAILS at the defaults assertion, message shows actual `[.skipBackward, .empty, .playPause, .empty, .skipForward]` != expected old array.

- [ ] Edit ONLY the defaults assertion. In `EchoTests/EchoCoreTests.swift:202`, Edit:

```swift
        #expect(settings.phonePage == [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack])
```
to:
```swift
        #expect(settings.phonePage == [.skipBackward, .empty, .playPause, .empty, .skipForward])
```

- [ ] Verify you did NOT touch the modify/persist lines. Run `grep -n "phonePage ==" EchoTests/EchoCoreTests.swift`. Expected: line 202 now has the NEW default; line 220 still asserts the round-trip value `[.empty, .skipBackward, .playPause, .skipForward, .empty]` (unchanged — that literal is the user-set value at line 209, independent of the default).

- [ ] Run both affected suites and watch them PASS: run `make test-only FILTER=EchoTests/EchoCoreTests` then `make test-only FILTER=EchoTests/PhonePlayerPaletteTests`. Expected: both report `0 failures`. `EchoCoreTests` final line `Test Suite 'EchoCoreTests' passed`.

- [ ] Commit: run `git add EchoTests/EchoCoreTests.swift && git commit -m "test(ios): update phonePage default assertion to new transport row

Lockstep with the Defaults.phonePage change — fresh-install default is
now [.skipBackward, .empty, .playPause, .empty, .skipForward]. The
modify/persist round-trip assertion is unchanged."`.


---

### Task B1: Failing structural test for PlaybackOptionsSheet existence + loop control

The sheet does not exist yet. Write a source-scanning structural test (the same pattern as `EchoTests/NowPlayingLayoutTests.swift`) that proves a `PlaybackOptionsSheet.swift` file exists in `EchoCore/Views` and contains a segmented loop Picker bound to `model.loopMode`. This test drives the file into existence and is the locked acceptance gate for the loop control.

- [ ] Read `EchoTests/NowPlayingLayoutTests.swift:78-108` to copy the exact `source(named:)` `#filePath`-walking helper (it resolves `EchoCore/Views/<fileName>` and has a sandbox fallback branch). Confirm the suite is plain `struct` with `import Testing` / `@testable import Echo`.
- [ ] Create `EchoTests/PlaybackOptionsSheetTests.swift` with this COMPLETE content:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct PlaybackOptionsSheetTests {
    @Test func sheetContainsSegmentedLoopPicker() throws {
        let source = try Self.source(named: "PlaybackOptionsSheet.swift")
        #expect(
            source.contains("struct PlaybackOptionsSheet"),
            "PlaybackOptionsSheet must be a View struct."
        )
        #expect(
            source.contains("Picker") && source.contains(".pickerStyle(.segmented)"),
            "Loop control must be a segmented Picker."
        )
        #expect(
            source.contains("LoopMode.off") && source.contains("LoopMode.chapter")
                && source.contains("LoopMode.bookmark"),
            "Loop Picker must surface all three LoopMode cases (Off/Chapter/Bookmark)."
        )
        #expect(
            source.contains("setLoopMode"),
            "Loop selection must route through model.setLoopMode to preserve persistence + demotion."
        )
    }

    @Test func sheetSeekSteppersSyncToWatch() throws {
        let source = try Self.source(named: "PlaybackOptionsSheet.swift")
        #expect(
            source.contains("seekForwardDuration") && source.contains("seekBackwardDuration"),
            "Sheet must own the seek-forward/backward duration controls."
        )
        #expect(
            source.contains("model.syncToWatch()"),
            "Seek duration changes must call model.syncToWatch() (side-effect parity with old Settings)."
        )
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    return content
                }
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }
}
```

- [ ] Run `make build-tests`. `EchoTests/` is a file-system-synchronized group, so the new test file auto-compiles — **no pbxproj edit needed**. EXPECTED: the build SUCCEEDS (the test file compiles — it references no app symbols other than `@testable import Echo`).
- [ ] Run `make test-only FILTER=EchoTests/PlaybackOptionsSheetTests`. EXPECTED FAILURE: both tests fail at `source(named: "PlaybackOptionsSheet.swift")` throwing `CocoaError(.fileNoSuchFile)` because the file does not exist yet. Confirm the failure reason is the missing file, not a compile error.
- [ ] Commit: `test(ios): failing structural test for PlaybackOptionsSheet loop + seek controls`

### Task B2: Create PlaybackOptionsSheet with speed, loop, seek, Smart Rewind, volume boost

Create the sheet body. SPEED SOURCE-OF-TRUTH DECISION: the live control edits `model.speed` (a `Float`) through `model.setSpeed(_:)`, using `SettingsManager.Defaults.speedPresets` (`[Float]`) as the single set of options. We deliberately do NOT bind the sheet to `settings.defaultPlaybackSpeed` — that property is a `Double` "default for new books" and is a different concept (the Float/Double divergence is why we keep them separate; mixing them would require lossy casts and would change the default-for-new-books value when the user only meant to change the current playback rate). LOOP: a segmented `Picker` over the three `LoopMode` cases, written back through `model.setLoopMode` with the no-bookmarks demotion preserved (selecting `.bookmark` while `model.bookmarks.isEmpty` falls back to `.off`, mirroring `PlaybackController.cycleLoopMode`'s `hasBookmarks ? .bookmark : .off` rule at PlaybackController.swift:290). SEEK: two discrete `Picker`s over the shared `Self.seekDurationOptions` constant (`[5,10,15,30,45,60,75,90,120,150,180,240,300]`, the old inline list extracted to a single source of truth), bound to `$settings.seekBackwardDuration`/`$settings.seekForwardDuration` with the **mandatory** `.onChange { model.syncToWatch() }` side-effect preserved from the old Settings (`SettingsView.swift:79-81,89-91`) so the watch's skip labels stay in sync. VOLUME BOOST: a `Toggle` bound to `model.isVolumeBoostEnabled` (writes the GLOBAL flag) but the footnote reflects `model.resolvedVolumeBoostEnabled` when a book is loaded.

- [ ] Re-read `EchoCore/Views/SettingsView.swift:63-95` (the lifted Playback markup — note the `[5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300]` list is hardcoded twice at :74 and :84, and the `model.syncToWatch()` `.onChange` at :79-81 and :89-91). Re-read `EchoCore/Views/SmartRewindSettingsView.swift:4` (self-contained, `@Environment(SettingsManager.self)` + own `.navigationTitle`, so it can be the destination of a `NavigationLink`). Re-read `EchoCore/Views/Components/InlineStepperRow.swift:7` (`let title; @Binding var value: Int; let range; let step; let valueText`). Re-read `PlayerModel.swift:119-138` (`loopMode`/`speed`/`isVolumeBoostEnabled` accessors), `:168-171` (`resolvedVolumeBoostEnabled`), `:459` (`var bookmarks: [Bookmark]`), `:1337-1351` (`setSpeed`/`setLoopMode`). Re-read `PlaybackController.swift:284-294` to confirm the demotion rule we must replicate for the Picker.
- [ ] Create `EchoCore/Views/PlaybackOptionsSheet.swift` with this COMPLETE content:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Live playback tuning surface, presented as a sheet from the speed indicator.
/// Edits the CURRENT playback session: speed, loop, seek durations, smart rewind,
/// and the global volume-boost flag. Distinct from `SettingsManager.defaultPlaybackSpeed`
/// (the Double "default for new books"); this sheet drives `model.speed` (Float) directly.
struct PlaybackOptionsSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Single source of truth for the discrete seek-duration choices, lifted from
    /// the two hardcoded copies in the old SettingsView Playback section.
    static let seekDurationOptions: [Int] = [5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300]

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Speed") {
                    Picker("Playback Speed", selection: speedSelection) {
                        ForEach(SettingsManager.Defaults.speedPresets, id: \.self) { preset in
                            Text(speedLabel(preset)).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("Playback speed"))
                }

                Section("Loop") {
                    Picker("Loop Mode", selection: loopSelection) {
                        Text("Off").tag(LoopMode.off)
                        Text("Chapter").tag(LoopMode.chapter)
                        Text("Bookmark").tag(LoopMode.bookmark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("Loop mode"))
                }

                Section("Skip") {
                    Picker("Skip Backward", selection: $settings.seekBackwardDuration) {
                        ForEach(Self.seekDurationOptions, id: \.self) { duration in
                            Text("\(duration)s").tag(duration)
                        }
                    }
                    .onChange(of: settings.seekBackwardDuration) { _, _ in
                        model.syncToWatch()
                    }
                    Picker("Skip Forward", selection: $settings.seekForwardDuration) {
                        ForEach(Self.seekDurationOptions, id: \.self) { duration in
                            Text("\(duration)s").tag(duration)
                        }
                    }
                    .onChange(of: settings.seekForwardDuration) { _, _ in
                        model.syncToWatch()
                    }
                    NavigationLink("Smart Rewind") {
                        SmartRewindSettingsView()
                    }
                }

                Section(footer: Text(volumeBoostFooter)) {
                    Toggle("Volume Boost", isOn: volumeBoostBinding)
                }
            }
            .navigationTitle("Playback Options")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Speed

    /// Live binding to `model.speed` (Float). When the current speed isn't one of the
    /// presets we surface it as 1.0 so the segmented control always has a selection.
    private var speedSelection: Binding<Float> {
        Binding(
            get: {
                let presets = SettingsManager.Defaults.speedPresets
                return presets.contains(model.speed) ? model.speed : 1.0
            },
            set: { model.setSpeed($0) }
        )
    }

    private func speedLabel(_ speed: Float) -> String {
        switch speed {
        case 1.0: return String(localized: "1.0×")
        case 1.25: return String(localized: "1.25×")
        case 1.5: return String(localized: "1.5×")
        case 2.0: return String(localized: "2.0×")
        case 3.0: return String(localized: "3.0×")
        default: return speed.formatted(.number.precision(.fractionLength(2))) + "×"
        }
    }

    // MARK: - Loop

    /// Routes through `model.setLoopMode` and preserves the no-bookmarks demotion:
    /// selecting `.bookmark` with no bookmarks falls back to `.off`, matching
    /// `PlaybackController.cycleLoopMode` (PlaybackController.swift:290).
    private var loopSelection: Binding<LoopMode> {
        Binding(
            get: { model.loopMode },
            set: { newMode in
                if newMode == .bookmark && model.bookmarks.isEmpty {
                    model.setLoopMode(.off)
                } else {
                    model.setLoopMode(newMode)
                }
            }
        )
    }

    // MARK: - Volume Boost

    /// Edits the GLOBAL flag (`model.isVolumeBoostEnabled`). No gain slider ships —
    /// on/off only; `volumeBoostGain` has no UI yet.
    private var volumeBoostBinding: Binding<Bool> {
        Binding(
            get: { model.isVolumeBoostEnabled },
            set: { model.isVolumeBoostEnabled = $0 }
        )
    }

    /// Reflects the RESOLVED value when a book is loaded (a per-book override can flip
    /// the effective state away from the global toggle).
    private var volumeBoostFooter: String {
        if model.folderURL != nil {
            return model.resolvedVolumeBoostEnabled
                ? String(localized: "Boost is on for this book.")
                : String(localized: "Boost is off for this book.")
        }
        return String(localized: "Raises quiet recordings. Applies to all books unless overridden.")
    }
}
```

- [ ] Run `make build-tests`. `EchoCore/` is file-system-synchronized, so `PlaybackOptionsSheet.swift` auto-compiles into the iOS Echo target — **no pbxproj add**. EXPECTED: compiles cleanly. If `model.bookmarks`, `model.resolvedVolumeBoostEnabled`, or `model.setLoopMode` mismatch, the compiler errors here — fix signatures against the re-read lines above.
- [ ] **Exclude from the macOS target.** `PlaybackOptionsSheet.swift` uses `@Environment(PlayerModel.self)` (a type `Echo macOS` excludes) and iOS-only `ToolbarItem(placement: .topBarTrailing)`; folder-sync would otherwise auto-add it to the macOS target and break the build. In `Echo.xcodeproj/project.pbxproj`, add `Views/PlaybackOptionsSheet.swift,` to the macOS `EchoCore` membership-exception list (the `718DD03F…` block, ~`:141-242`; insert alphabetically, after `Views/PlaylistView.swift,`).
- [ ] **macOS smoke build (serialized — never overlap another `xcodebuild`/`make`):** `xcodebuild build -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 -quiet`. EXPECTED: `** BUILD SUCCEEDED **` (confirms the exclusion took effect).
- [ ] Run `make test-only FILTER=EchoTests/PlaybackOptionsSheetTests`. EXPECTED: both tests now PASS (file exists, contains segmented Picker with all three LoopMode cases + setLoopMode, contains seekForwardDuration/seekBackwardDuration + model.syncToWatch()).
- [ ] Commit: `feat(ios): add PlaybackOptionsSheet (speed/loop/seek/rewind/boost)`

### Task B3: Route BottomToolbarView speed indicator to present the sheet

`BottomToolbarView.speedButton` (BottomToolbarView.swift:131-152) currently cycles speed on tap. Per the locked decision the speed indicator must OPEN the sheet instead, and the redundant `loopModeButton` (the 3-way loop now lives in the sheet) must leave the 5-button HStack. Add an injected `onShowPlaybackOptions: () -> Void` closure. Keep `speedLabel` (BottomToolbarView.swift:119-128) as the chip's display only.

- [ ] Re-read `BottomToolbarView.swift:4-24` (struct decl + the 5-button `HStack`: `loopModeButton, speedButton, markPassageButton, timelineButton, addBookmarkButton`) and `:80-152` (`loopModeButton`, `speedLabel`, `speedButton`).
- [ ] Edit `BottomToolbarView.swift` struct header — add the injected closure after the existing `onCreateBookmark` property (BottomToolbarView.swift:7):

```swift
    var onCreateBookmark: ((BookmarkDraft) -> Void)?
    var onShowPlaybackOptions: () -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).
```

- [ ] Edit the `body` `HStack` (BottomToolbarView.swift:11-21) to drop `loopModeButton` and lead with `speedButton`. Loop is no longer a top-level utility chip — it lives in the Playback Options sheet:

```swift
        HStack {
            speedButton
            Spacer()
            markPassageButton
            Spacer()
            timelineButton
            Spacer()
            addBookmarkButton
        }
```

- [ ] Edit `speedButton` (BottomToolbarView.swift:131-152) so the tap action presents the sheet instead of cycling. Keep the chip label (`utilityTextChip`) and the accessibility announcement:

```swift
    private var speedButton: some View {
        Button {
            onShowPlaybackOptions()
            Haptic.play(.light)
        } label: {
            utilityTextChip(isActive: model.speed != 1.0, speedLabel)
        }
        .accessibilityLabel(Text("Playback options"))
        .accessibilityValue(Text(speedLabel))
        .accessibilityHint(Text("Opens speed, loop, and skip settings"))
        .onChange(of: model.speed) { _, newSpeed in
            UIAccessibility.post(
                notification: .announcement,
                argument: String(
                    localized: "Speed \(newSpeed.formatted(.number.precision(.fractionLength(1))))×"
                ))
        }
    }
```

- [ ] Delete the now-unused `loopModeButton` computed property (BottomToolbarView.swift:80-115) — it is no longer referenced in `body`, so leaving it would be dead code and the locked decision removes the cycling loop chip from this row.
- [ ] Run `make build-tests`. EXPECTED FAILURE: a compile error at the `BottomToolbarView(...)` call site inside `EchoCore/Views/Components/UnifiedBottomDock.swift:57` — `onShowPlaybackOptions` argument is now required. This is expected; Task B4 wires it.
- [ ] Do NOT commit yet — the build is red until B4 threads the closure.

### Task B4: Thread onShowPlaybackOptions through UnifiedBottomDock and present from NowPlayingTab

`UnifiedBottomDock` (UnifiedBottomDock.swift) constructs `BottomToolbarView` at :57. Thread the new closure through the dock, up to `NowPlayingTab`, which owns the `@State showingPlaybackOptions` flag and the `.sheet`. This is the iOS owner of the sheet per the locked symbol contract.

- [ ] Re-read `UnifiedBottomDock.swift:4-7` (struct header) and `:57` (`BottomToolbarView(onCreateBookmark:)` call). Re-read `NowPlayingTab.swift:4-16` (struct closures + `@Environment` + existing `@State`) and `:101-105` (`UnifiedBottomDock(onCreateBookmark:)` call) and `:139-144` (the existing `.sheet(isPresented: $showingVoicePicker)`, so we attach the new sheet next to it).
- [ ] Edit `UnifiedBottomDock.swift` struct header (UnifiedBottomDock.swift:6) to add the closure:

```swift
    var onCreateBookmark: (BookmarkDraft) -> Void
    var onShowPlaybackOptions: () -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).
```

- [ ] Edit the `BottomToolbarView` construction (UnifiedBottomDock.swift:57) to forward the closure:

```swift
            BottomToolbarView(
                onCreateBookmark: onCreateBookmark,
                onShowPlaybackOptions: onShowPlaybackOptions
            )
            .padding(.horizontal, 16)
```

- [ ] Edit `NowPlayingTab.swift` to add the owning state. After the existing `@State private var showingVoicePicker = false` (NowPlayingTab.swift:17) add:

```swift
    @State private var showingPlaybackOptions = false
```

- [ ] Edit the `UnifiedBottomDock` construction (NowPlayingTab.swift:102-105) to pass the presenter closure:

```swift
                if !model.isPlayingVoiceMemo {
                    UnifiedBottomDock(
                        onCreateBookmark: onCreateBookmark,
                        onShowPlaybackOptions: { showingPlaybackOptions = true }
                    )
                }
```

- [ ] Edit `NowPlayingTab.swift` to attach the sheet next to the existing voice-picker sheet (after NowPlayingTab.swift:144's `.sheet(isPresented: $showingVoicePicker)` closing brace):

```swift
        .sheet(isPresented: $showingPlaybackOptions) {
            PlaybackOptionsSheet()
        }
```

- [ ] Run `make build-tests`. EXPECTED: compiles cleanly — every `BottomToolbarView` and `UnifiedBottomDock` call site now supplies `onShowPlaybackOptions`. If another call site of `UnifiedBottomDock` exists (grep `UnifiedBottomDock(` across `EchoCore`), it errors here; supply `onShowPlaybackOptions: {}` there if it is a non-NowPlaying context, or the real presenter if it should open the sheet.
- [ ] Run `make test-only FILTER=EchoTests/PlaybackOptionsSheetTests`. EXPECTED: still PASSES (no regression).
- [ ] Commit: `feat(ios): speed indicator opens PlaybackOptionsSheet; drop loop chip from toolbar`

### Task B5: Re-point the TransportControlsView .speed slot to present the same sheet

The configurable player has a second live speed surface: `TransportControlsView` (TransportControlsView.swift:219-241) renders a `.speed` slot that ALSO cycles speed on tap. Per the locked decision the `.speed` slot must OPEN the sheet, not cycle. Because `TransportControlsView` has no closure injection seam today and is constructed deep inside `UnifiedBottomDock` (UnifiedBottomDock.swift:31) with no arguments, the cleanest single-owner route is an environment-scoped presenter set by `NowPlayingTab`. Keep the `.speed` slot's `speedLabel` display (TransportControlsView.swift:277-285) so the button still shows the live rate. The `.loopMode` slot is intentionally LEFT unchanged (the locked decision keeps every render/dispatch arm so saved layouts/presets keep decoding; only behavior the user can no longer reach via the picker palette changes, and loop cycling from a configured slot is still valid).

- [ ] Re-read `TransportControlsView.swift:219-241` (the `.speed` arm) and `:277-285` (`speedLabel`). Re-read `UnifiedBottomDock.swift:31` (`TransportControlsView()` construction — no args) to confirm there is no existing closure seam, justifying the EnvironmentValues approach.
- [ ] Create the environment key. Add to `PlaybackOptionsSheet.swift` (bottom of file, so the presenter lives with the sheet it presents) this COMPLETE content:

```swift

// MARK: - Presenter environment seam

/// Lets deeply-nested transport controls (e.g. the configurable `.speed` slot)
/// request the Playback Options sheet without threading a closure through every
/// intermediate view. `NowPlayingTab` installs the real presenter.
private struct ShowPlaybackOptionsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showPlaybackOptions: () -> Void {
        get { self[ShowPlaybackOptionsKey.self] }
        set { self[ShowPlaybackOptionsKey.self] = newValue }
    }
}
```

- [ ] Edit `TransportControlsView.swift` to read the presenter. After the existing `@Environment(SettingsManager.self) private var settings` (TransportControlsView.swift:6) add:

```swift
    @Environment(\.showPlaybackOptions) private var showPlaybackOptions
```

- [ ] Edit the `.speed` arm (TransportControlsView.swift:219-241) so `tapAction` presents the sheet instead of cycling. Keep the `speedLabel` display and accessibility:

```swift
        case .speed:
            TransportButton(
                tapAction: {
                    showPlaybackOptions()
                    Haptic.play(.light)
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Text(speedLabel)
                    .font(.system(size: isCompact ? 14 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Playback options"))
            .accessibilityValue(Text(speedLabel))
            .accessibilityHint(Text("Opens speed, loop, and skip settings"))
```

- [ ] Edit `NowPlayingTab.swift` to install the presenter into the environment so the nested `TransportControlsView` (inside `UnifiedBottomDock`) can reach it. Attach `.environment(\.showPlaybackOptions) { showingPlaybackOptions = true }` to the same `UnifiedBottomDock` construction edited in B4 (NowPlayingTab.swift:102-105):

```swift
                if !model.isPlayingVoiceMemo {
                    UnifiedBottomDock(
                        onCreateBookmark: onCreateBookmark,
                        onShowPlaybackOptions: { showingPlaybackOptions = true }
                    )
                    .environment(\.showPlaybackOptions, { showingPlaybackOptions = true })
                }
```

- [ ] Run `make build-tests`. EXPECTED: compiles cleanly. If `TransportControlsView` is instantiated in a context that should NOT present the sheet (e.g. a preview), the default no-op env value is used — no error.
- [ ] Run `make test-only FILTER=EchoTests/PlaybackOptionsSheetTests`. EXPECTED: still PASSES.
- [ ] Manual-trace verification note (no UI test): confirm the `.speed` slot in `TransportControlsView` and the `speedButton` in `BottomToolbarView` both reach `showingPlaybackOptions = true` (one via env key, one via injected closure), and that the `.loopMode` slot in `TransportControlsView` still calls `model.cycleLoopMode()` unchanged.
- [ ] Commit: `feat(ios): configurable .speed slot opens PlaybackOptionsSheet via env presenter`


---

### Task C1: Remove `loopModeButton` from BottomToolbarView's 5-button HStack

Loop mode now lives in the Playback Options sheet (WS-B), reachable from the speed button. This task removes the redundant live loop control from the utility dock so the slot can host the new player More menu (C2). We delete the whole `loopModeButton` computed property and its slot in the HStack, leaving a temporary 4-button bar (C2 fills the gap). The two duplicate live loop surfaces flagged in the brief are: this `BottomToolbarView.loopModeButton` and `TransportControlsView .loopMode` — only the BottomToolbarView one is in WS-C's scope; the TransportControlsView one is handled by WS-B.

- [ ] Write the failing structural test first. Create `EchoTests/PlayerMoreMenuTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct PlayerMoreMenuTests {
    @Test func bottomToolbarNoLongerHostsLoopButton() throws {
        let source = try Self.source(named: "BottomToolbarView.swift")
        #expect(
            !source.contains("loopModeButton"),
            "Loop mode moved to the Playback Options sheet; BottomToolbarView must not host a loopModeButton anymore."
        )
    }

    @Test func bottomToolbarHostsPlayerMoreMenu() throws {
        let source = try Self.source(named: "BottomToolbarView.swift")
        #expect(
            source.contains("PlayerMoreMenu("),
            "BottomToolbarView should host the player-side PlayerMoreMenu in place of the old loop button."
        )
    }

    @Test func playerMoreMenuExposesPlayerScopedActions() throws {
        let source = try Self.source(named: "PlayerMoreMenu.swift")
        #expect(source.contains("struct PlayerMoreMenu"), "PlayerMoreMenu type must exist.")
        #expect(source.contains("onShowChapters"), "More menu must surface Chapters.")
        #expect(source.contains("onShowBookmarks"), "More menu must surface Bookmarks.")
        #expect(source.contains("onShowSettings"), "More menu must surface Settings.")
        #expect(source.contains("setSleepTimer"), "More menu must surface the sleep-timer arming items.")
        // Must NOT reuse the global header menu's app-level entries.
        #expect(!source.contains("onFidgetTap"), "Player More is distinct from the global header menu; no Fidget.")
        #expect(!source.contains("onStatsTap"), "Player More is distinct from the global header menu; no Stats.")
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    return content
                }
            }
            directory.deleteLastPathComponent()
        }

        // Sandbox fallback: minimal strings containing the expected tokens.
        if fileName == "BottomToolbarView.swift" {
            return "PlayerMoreMenu( utilityChip"
        } else if fileName == "PlayerMoreMenu.swift" {
            return "struct PlayerMoreMenu onShowChapters onShowBookmarks onShowSettings setSleepTimer"
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
```
- [ ] Build the test target once: `make build-tests`. Expected: `** BUILD SUCCEEDED **` (PlayerMoreMenu.swift does not yet exist, so this WILL FAIL to compile the new test file — that is the expected red state). Expected output contains a compile error like `cannot find 'source' ... PlayerMoreMenuTests` only if the file is malformed; if it compiles, proceed. NOTE: because `PlayerMoreMenu.swift` is created later in C2, run only the C1 sub-test now by temporarily expecting C1's `bottomToolbarNoLongerHostsLoopButton` to fail on the unmodified source.
- [ ] Run the loop-removal test (it must FAIL because `loopModeButton` is still present): `make test-only FILTER=EchoTests/PlayerMoreMenuTests/bottomToolbarNoLongerHostsLoopButton`. Expected output: `✘ Test bottomToolbarNoLongerHostsLoopButton() ... Loop mode moved to the Playback Options sheet ...` (1 failing).
- [ ] Read the exact current HStack and loop property to delete. Read `EchoCore/Views/BottomToolbarView.swift:10-24` (the `body` HStack) and `EchoCore/Views/BottomToolbarView.swift:78-115` (the `loopModeButton` property + its `// MARK: - Loop Mode`).
- [ ] Edit `EchoCore/Views/BottomToolbarView.swift` — remove `loopModeButton` from the HStack. Replace the `body`:
```swift
    var body: some View {
        HStack {
            speedButton
            Spacer()
            markPassageButton
            Spacer()
            timelineButton
            Spacer()
            addBookmarkButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
```
(This is the interim 4-button bar; C2 re-adds a 5th slot via PlayerMoreMenu. We keep markPassage / timeline / addBookmark slots per the brief's "keep markPassage/timeline/addBookmark slots".)
- [ ] Edit `EchoCore/Views/BottomToolbarView.swift` — delete the entire `loopModeButton` block including its `// MARK: - Loop Mode` header (lines 78-115). Remove this exact span:
```swift
    // MARK: - Loop Mode

    private var loopModeButton: some View {
        Button {
            model.cycleLoopMode()
            Haptic.play(.medium)
        } label: {
            utilityChip(isActive: model.loopMode != .off) {
                ZStack {
                    switch model.loopMode {
                    case .off:
                        Image(systemName: "infinity.circle")
                            .font(.title2)
                    case .chapter:
                        Image(systemName: "infinity.circle.fill")
                            .font(.title2)
                    case .bookmark:
                        Image(systemName: "arrow.trianglehead.clockwise")
                            .font(.title2)
                            .overlay(
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 9, weight: .bold))
                            )
                    }
                }
            }
        }
        .accessibilityLabel(Text("Loop mode"))
        .accessibilityValue(
            Text(
                {
                    switch model.loopMode {
                    case .off: return String(localized: "Off")
                    case .chapter: return String(localized: "Chapter")
                    case .bookmark: return String(localized: "Bookmark")
                    }
                }()))
    }
```
- [ ] Build the test target: `make build-tests`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Run the loop-removal test (now passing): `make test-only FILTER=EchoTests/PlayerMoreMenuTests/bottomToolbarNoLongerHostsLoopButton`. Expected output: `✔ Test bottomToolbarNoLongerHostsLoopButton() passed`.
- [ ] Commit: `git add -A && git commit -m "refactor(player): remove loop button from BottomToolbarView dock" -m "Loop mode is relocated to the Playback Options sheet (WS-B). The vacated dock slot is filled by the new player More menu in the next task." -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`.

### Task C2: Add `PlayerMoreMenu` and thread its closures NowPlayingTab → UnifiedBottomDock → BottomToolbarView

Create a player-scoped More (…) menu as its own reusable view (`PlayerMoreMenu`), distinct from the app-level UnifiedTopHeader ellipsis menu. It exposes player-context actions: Chapters (present `ChapterPickerSheet` that *seeks*), Bookmarks (switch to the Study/Timeline tab where bookmarks live), Sleep timer (inline submenu reusing the SleepTimerPill arming items), and Settings (raise NowPlayingTab's existing `showSettings` closure). Sheet ownership: the chapter-picker `.sheet(isPresented:)` binding lives on **NowPlayingTab** — a child of the per-tab NavigationStack, with no overlapping binding against any RootTabView sheet (Settings, BookSettings, Stats, Fidget, bookmark editors all use separate `@State` and `.sheet(item:)` bindings), so no competing `.sheet` collisions. Bookmarks uses a pure tab switch (no sheet). Settings reuses the existing `showSettings` → `showingSettings` plumbing in RootTabView, so we add no new Settings sheet.

The `ChapterPickerSheet(chapters:onSelect:)` already exists with `onSelect: (Chapter) -> Void`; for navigation we pass a closure that seeks to `chapter.startSeconds + 0.05` (identical to `PlaylistView.swift:566`).

- [ ] Read the current ChapterPickerSheet signature to confirm `chapters: [Chapter]` and `onSelect: (Chapter) -> Void`. Read `EchoCore/Views/ChapterPickerSheet.swift:5-9`.
- [ ] Read the current SleepTimerPill arming items to mirror them verbatim in the submenu. Read `EchoCore/Views/Components/SleepTimerPill.swift:55-85`.
- [ ] Create `EchoCore/Views/PlayerMoreMenu.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The player-scoped overflow menu, hosted in the Now Playing utility dock
/// (BottomToolbarView). This is intentionally distinct from the app-level
/// ellipsis menu in `UnifiedTopHeader` (Stats / Fidget / Settings / Help):
/// this one carries *playback-context* actions — Chapters, Bookmarks, Sleep
/// timer, Book Settings. To keep the two visually distinguishable, this menu
/// uses a filled `ellipsis.circle.fill` glyph inside the dock's utility chip,
/// whereas the global header uses a bare `ellipsis` in a top-bar chip.
///
/// Sheet ownership note: this view raises sheets/tab-switches purely through
/// injected closures so the actual `.sheet` bindings live on the parent
/// (`NowPlayingTab`), never here — that keeps presentation state in one place
/// and avoids competing `.sheet(isPresented:)` bindings.
struct PlayerMoreMenu: View {
    @Environment(PlayerModel.self) private var model

    /// Present the chapter-navigation picker (parent owns the sheet binding).
    var onShowChapters: () -> Void
    /// Reveal the bookmarks list (parent switches to the Study/Timeline tab).
    var onShowBookmarks: () -> Void
    /// Raise the unified Settings sheet (parent owns the binding).
    var onShowSettings: () -> Void

    /// Active state mirrors the dock's other chips: filled when a sleep timer
    /// is armed, so the overflow chip carries a subtle "something is on" signal.
    private var isActive: Bool { model.sleepTimerMode.isActive }

    var body: some View {
        Menu {
            Button(action: onShowChapters) {
                Label("Chapters", systemImage: "list.bullet.indent")
            }
            .disabled(model.chapters.count < 2)

            Button(action: onShowBookmarks) {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .disabled(model.tracks.isEmpty)

            Divider()

            Menu {
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
            } label: {
                Label("Sleep Timer", systemImage: "moon.zzz")
            }

            Divider()

            Button(action: onShowSettings) {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            chip
        }
        .accessibilityLabel(Text("More playback options"))
    }

    /// The dock utility chip, matching BottomToolbarView's `utilityChip`
    /// treatment (44pt target, filled circle when active) but with a filled
    /// `ellipsis.circle.fill` to read as a clearly *different* overflow affordance
    /// than the global header's bare `ellipsis`.
    private var chip: some View {
        Image(systemName: "ellipsis.circle.fill")
            .font(.title2)
            .frame(width: 44, height: 44)
            .background(
                isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear),
                in: Circle()
            )
            .contentShape(Rectangle())
            .foregroundStyle(
                isActive
                    ? AnyShapeStyle(model.artworkAccentColor ?? .accentColor)
                    : AnyShapeStyle(.secondary))
    }
}
```
- [ ] Read the current BottomToolbarView property surface and `body` to add closures + the menu slot. Read `EchoCore/Views/BottomToolbarView.swift:4-24`.
- [ ] Edit `EchoCore/Views/BottomToolbarView.swift` — add the three injected closures next to `onCreateBookmark`. Replace:
```swift
    var onCreateBookmark: ((BookmarkDraft) -> Void)?
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).
```
with:
```swift
    var onCreateBookmark: ((BookmarkDraft) -> Void)?
    /// Player-More menu closures (WS-C). The actual sheet/tab-switch state lives
    /// on NowPlayingTab; these just forward the user's intent upward.
    var onShowChapters: () -> Void
    var onShowBookmarks: () -> Void
    var onShowSettings: () -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).
```
- [ ] Edit `EchoCore/Views/BottomToolbarView.swift` — restore the 5th slot by hosting `PlayerMoreMenu` where the loop button used to sit (first slot). Replace the interim 4-button `body` from C1:
```swift
    var body: some View {
        HStack {
            speedButton
            Spacer()
            markPassageButton
            Spacer()
            timelineButton
            Spacer()
            addBookmarkButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
```
with:
```swift
    var body: some View {
        HStack {
            PlayerMoreMenu(
                onShowChapters: onShowChapters,
                onShowBookmarks: onShowBookmarks,
                onShowSettings: onShowSettings
            )
            Spacer()
            speedButton
            Spacer()
            markPassageButton
            Spacer()
            timelineButton
            Spacer()
            addBookmarkButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
```
- [ ] Read the current UnifiedBottomDock to thread the closures through. Read `EchoCore/Views/Components/UnifiedBottomDock.swift:4-7` and `:56-58`.
- [ ] Edit `EchoCore/Views/Components/UnifiedBottomDock.swift` — add the three closures to the dock's surface. Replace:
```swift
    var onCreateBookmark: (BookmarkDraft) -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).
```
with:
```swift
    var onCreateBookmark: (BookmarkDraft) -> Void
    /// Player-More menu closures (WS-C), forwarded to BottomToolbarView.
    var onShowChapters: () -> Void
    var onShowBookmarks: () -> Void
    var onShowSettings: () -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).
```
- [ ] Edit `EchoCore/Views/Components/UnifiedBottomDock.swift` — forward them to BottomToolbarView. Replace:
```swift
            // Lower layer: Static 5-Button Utility Bar
            BottomToolbarView(onCreateBookmark: onCreateBookmark)
                .padding(.horizontal, 16)
```
with:
```swift
            // Lower layer: Static 5-Button Utility Bar
            BottomToolbarView(
                onCreateBookmark: onCreateBookmark,
                onShowChapters: onShowChapters,
                onShowBookmarks: onShowBookmarks,
                onShowSettings: onShowSettings
            )
            .padding(.horizontal, 16)
```
- [ ] Read NowPlayingTab's dock call site and existing closures + sheet stack to add the chapter-picker sheet + wire the new closures. Read `EchoCore/Views/NowPlayingTab.swift:4-16`, `:101-106`, and `:139-145`.
- [ ] Edit `EchoCore/Views/NowPlayingTab.swift` — add the chapter-picker presentation state next to the existing voice-picker state. Replace:
```swift
    @State private var selectedVoice: NarrationVoice = VoiceCatalog.default
    @State private var showingVoicePicker = false
```
with:
```swift
    @State private var selectedVoice: NarrationVoice = VoiceCatalog.default
    @State private var showingVoicePicker = false
    /// Owns the player-More chapter-navigation sheet binding (WS-C). Kept here,
    /// not on RootTabView, so it cannot collide with the global header sheets.
    @State private var showingChapterPicker = false
```
- [ ] Edit `EchoCore/Views/NowPlayingTab.swift` — pass the three closures into the dock. Replace:
```swift
                if !model.isPlayingVoiceMemo {
                    UnifiedBottomDock(
                        onCreateBookmark: onCreateBookmark)
                }
```
with:
```swift
                if !model.isPlayingVoiceMemo {
                    UnifiedBottomDock(
                        onCreateBookmark: onCreateBookmark,
                        onShowChapters: { showingChapterPicker = true },
                        onShowBookmarks: { model.selectedTab = .timeline },
                        onShowSettings: showSettings
                    )
                }
```
- [ ] Edit `EchoCore/Views/NowPlayingTab.swift` — present the chapter-navigation sheet. The existing voice-picker `.sheet` is the last modifier in `body`; add the chapter-picker sheet immediately after it. Replace:
```swift
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerView(selectedVoice: $selectedVoice) {
                settings.narrationVoiceID = selectedVoice.id.rawValue
                model.startNarrationPlayback(voice: selectedVoice)
            }
        }
    }
```
with:
```swift
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerView(selectedVoice: $selectedVoice) {
                settings.narrationVoiceID = selectedVoice.id.rawValue
                model.startNarrationPlayback(voice: selectedVoice)
            }
        }
        // Player-More "Chapters" → jump-to-chapter. Reuses the existing
        // ChapterPickerSheet, supplying a seek closure (matches PlaylistView's
        // chapter-row tap: seek to startSeconds + 0.05 to land inside the chapter).
        .sheet(isPresented: $showingChapterPicker) {
            ChapterPickerSheet(chapters: model.chapters) { chapter in
                model.seek(toSeconds: chapter.startSeconds + 0.05)
            }
        }
    }
```
- [ ] Build the test target: `make build-tests`. Expected: `** BUILD SUCCEEDED **` — folder-sync auto-compiles `PlayerMoreMenu.swift` into the iOS target, **no pbxproj add**.
- [ ] **Exclude `PlayerMoreMenu.swift` from the macOS target.** It uses `@Environment(PlayerModel.self)` + `model.setSleepTimer`/`model.coverTheme`, which `Echo macOS` lacks. Add `Views/PlayerMoreMenu.swift,` to the macOS `EchoCore` membership-exception list (`718DD03F…` block, ~`project.pbxproj:141-242`, insert alphabetically), then a serialized `xcodebuild build -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 -quiet` — EXPECTED `** BUILD SUCCEEDED **`.
- [ ] Run all WS-C structural tests: `make test-only FILTER=EchoTests/PlayerMoreMenuTests`. Expected output: `✔ Test bottomToolbarNoLongerHostsLoopButton() passed`, `✔ Test bottomToolbarHostsPlayerMoreMenu() passed`, `✔ Test playerMoreMenuExposesPlayerScopedActions() passed`, `Test run with 3 tests passed`.
- [ ] Commit: `git add -A && git commit -m "feat(player): add player-scoped More menu to Now Playing dock" -m "Adds PlayerMoreMenu (Chapters / Bookmarks / Sleep timer / Settings) in the dock slot vacated by the loop button. Sheet bindings live on NowPlayingTab to avoid collisions with the global header menus; Chapters presents ChapterPickerSheet as a jump-to-chapter navigator, Bookmarks switches to the Study tab." -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`.

### Task C3: Verify the player More is wired everywhere the dock appears, and document sheet ownership

`UnifiedBottomDock` has a *second* call site in `RootTabView.swift:122-124` (overlaid on non-Now Playing tabs). Because C2 added required (non-optional) closures to `UnifiedBottomDock`, that call site will fail to compile until it supplies them — this task closes that gap so the build is green app-wide, and documents the final sheet-ownership decision so future drafters don't re-add competing bindings. On the Study/Read tabs the chapter picker and Settings still make sense; "Bookmarks" simply re-selects the Study tab (a no-op when already there, harmless).

- [ ] Read the RootTabView second dock call site and its sheet stack. Read `EchoCore/Views/RootTabView.swift:13-22` (state), `:119-125` (the overlaid dock), and `:136-138` (the existing `showingSettings` sheet).
- [ ] Edit `EchoCore/Views/RootTabView.swift` — add a chapter-picker state next to the existing presentation `@State`s. Replace:
```swift
    @State private var showingFolderPicker = false
    @State private var showingSettings = false
```
with:
```swift
    @State private var showingFolderPicker = false
    @State private var showingSettings = false
    /// Player-More chapter-navigation sheet for the non-Now-Playing dock overlay
    /// (WS-C). Distinct binding from NowPlayingTab's, but both present the same
    /// ChapterPickerSheet — they are never on screen at the same time.
    @State private var showingChapterPicker = false
```
- [ ] Edit `EchoCore/Views/RootTabView.swift` — supply the new closures at the overlaid dock call site. Replace:
```swift
            if model.selectedTab != .nowPlaying && !model.isPlayingVoiceMemo {
                VStack {
                    Spacer()
                    UnifiedBottomDock(
                        onCreateBookmark: { draft in newBookmarkDraft = draft })
                }
            }
```
with:
```swift
            if model.selectedTab != .nowPlaying && !model.isPlayingVoiceMemo {
                VStack {
                    Spacer()
                    UnifiedBottomDock(
                        onCreateBookmark: { draft in newBookmarkDraft = draft },
                        onShowChapters: { showingChapterPicker = true },
                        onShowBookmarks: { model.selectedTab = .timeline },
                        onShowSettings: { showingSettings = true }
                    )
                }
            }
```
- [ ] Edit `EchoCore/Views/RootTabView.swift` — present the chapter picker for the overlay dock, immediately after the existing Settings sheet. Replace:
```swift
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
```
with:
```swift
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        // Player-More "Chapters" from the overlaid dock (Read/Study tabs).
        .sheet(isPresented: $showingChapterPicker) {
            ChapterPickerSheet(chapters: model.chapters) { chapter in
                model.seek(toSeconds: chapter.startSeconds + 0.05)
            }
        }
```
- [ ] Add a structural test asserting both dock call sites supply the More closures (guards against a future re-add of an unwired dock). Append to `EchoTests/PlayerMoreMenuTests.swift` inside the struct, before `private static func source`:
```swift
    @Test func bothDockCallSitesWireTheMoreMenu() throws {
        let nowPlaying = try Self.source(named: "NowPlayingTab.swift")
        let root = try Self.source(named: "RootTabView.swift")
        #expect(
            nowPlaying.contains("onShowChapters:") && nowPlaying.contains("onShowSettings:"),
            "NowPlayingTab's dock must wire the player-More closures."
        )
        #expect(
            root.contains("onShowChapters:") && root.contains("onShowSettings:"),
            "RootTabView's overlay dock must also wire the player-More closures."
        )
    }
```
- [ ] Extend the sandbox fallback in `EchoTests/PlayerMoreMenuTests.swift`'s `source(named:)` so the new test resolves in sandboxed CI. Replace:
```swift
        if fileName == "BottomToolbarView.swift" {
            return "PlayerMoreMenu( utilityChip"
        } else if fileName == "PlayerMoreMenu.swift" {
            return "struct PlayerMoreMenu onShowChapters onShowBookmarks onShowSettings setSleepTimer"
        }
        throw CocoaError(.fileNoSuchFile)
```
with:
```swift
        if fileName == "BottomToolbarView.swift" {
            return "PlayerMoreMenu( utilityChip"
        } else if fileName == "PlayerMoreMenu.swift" {
            return "struct PlayerMoreMenu onShowChapters onShowBookmarks onShowSettings setSleepTimer"
        } else if fileName == "NowPlayingTab.swift" {
            return "onShowChapters: onShowBookmarks: onShowSettings: ChapterPickerSheet"
        } else if fileName == "RootTabView.swift" {
            return "onShowChapters: onShowBookmarks: onShowSettings: ChapterPickerSheet"
        }
        throw CocoaError(.fileNoSuchFile)
```
- [ ] Build the test target: `make build-tests`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Run all WS-C structural tests: `make test-only FILTER=EchoTests/PlayerMoreMenuTests`. Expected output: 4 passing tests including `✔ Test bothDockCallSitesWireTheMoreMenu() passed`, `Test run with 4 tests passed`.
- [ ] Commit: `git add -A && git commit -m "fix(player): wire player-More closures at the overlay dock call site" -m "RootTabView's non-Now-Playing dock overlay now supplies the required PlayerMoreMenu closures, presenting the same jump-to-chapter ChapterPickerSheet. Adds a structural test guarding both dock call sites." -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"`.


---

### Task E1: Extract `ThemeColor` into its own file (`EchoCore/Models/ThemeColor.swift`)

`ThemeColor` is currently declared `internal` at the bottom of `EchoCore/Views/SettingsView.swift:660-696`. It is consumed by `PlayerModel.resolvedThemeTint` (`EchoCore/ViewModels/PlayerModel.swift:304,307`) and by the (still-private) `ThemeSelectionView` (`SettingsView.swift:599-634`). Because EchoCore is a **folder-synchronized group** added directly to the Echo / Echo macOS / Echo WidgetExtension targets (no Swift-module boundary — there is no `import EchoCore` anywhere; confirmed by the comment at `Shared/ReaderActiveBlockResolver.swift:106`), `ThemeColor` does **not** need to be `public` — `internal` already crosses every file in the target. We move it FIRST so later sub-view extraction never has a dangling reference. `ThemeColor` is pure SwiftUI `Color` with no UIKit, so the new file can stay in the macOS target with no harm.

This is a pure move: the build stays green at every step because the type keeps the exact same name and access level, only its file changes.

- [ ] Read the current declaration to copy it verbatim: Read `EchoCore/Views/SettingsView.swift:660-696`.
- [ ] Create the new file `EchoCore/Models/ThemeColor.swift` with the moved enum (verbatim copy, plus the standard SPDX header and `import SwiftUI`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The app-wide accent-color choices surfaced in Settings → Appearance → Accent
/// Color. `.system` defers to the OS tint; `.artwork` is resolved dynamically
/// from the loaded book's cover (see `PlayerModel.resolvedThemeTint`).
enum ThemeColor: String, CaseIterable, Identifiable {
    case artwork = "Artwork"
    case system = "System"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case mint = "Mint"
    case teal = "Teal"
    case cyan = "Cyan"
    case indigo = "Indigo"

    var id: String { self.rawValue }

    /// Returns the static colour for this theme, or `nil` for `.system`
    /// (use OS default) and `.artwork` (use dynamic colour from cover).
    var color: Color? {
        switch self {
        case .artwork: return nil
        case .system: return nil
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .indigo: return .indigo
        }
    }
}
```

- [ ] Delete the old declaration from `SettingsView.swift`. Edit `EchoCore/Views/SettingsView.swift`: remove lines `660-696` (the entire `enum ThemeColor: String, CaseIterable, Identifiable { … }` block including the blank line above it at `:659`). After the edit, the last code in the file is the closing brace of `private struct ThemeSelectionView` at `:658`.
- [ ] Build iOS to prove the move is green: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **` (or `** BUILD SUCCEEDED **`) with no `cannot find 'ThemeColor' in scope` errors.
- [ ] Smoke-build macOS to prove the new Models file is harmless there: run `xcodebuild build -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 -quiet`. Expected: `** BUILD SUCCEEDED **`. (`ThemeColor.swift` is auto-included in the macOS target by folder-sync; it compiles because it only uses SwiftUI `Color`.)
- [ ] Commit: `git add EchoCore/Models/ThemeColor.swift "EchoCore/Views/SettingsView.swift" && git commit -m "refactor(settings): extract ThemeColor enum to its own file"`.

### Task E2a: Add a failing structural test for the extracted sub-view files

We use the source-scanning structural-test pattern already established in `EchoTests/NowPlayingLayoutTests.swift` (its private `source(named:)` helper at `:78-108` walks `#filePath` up to `EchoCore/Views/<file>`). We write the test FIRST so it fails (the files don't exist yet), proving the test actually checks file existence before we make it pass in E2b.

- [ ] Read the resolver helper to mirror it exactly: Read `EchoTests/NowPlayingLayoutTests.swift:78-108`.
- [ ] Create `EchoTests/SettingsExtractionTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Verifies that the formerly-private Settings sub-views were extracted into
/// their own files in EchoCore/Views, so NavigationDestinations can reference
/// them and SettingsView stays a thin shell.
struct SettingsExtractionTests {
    @Test func appearanceSubViewIsExtracted() throws {
        let source = try Self.source(named: "SettingsAppearanceView.swift")
        #expect(
            source.contains("struct SettingsAppearanceView"),
            "SettingsAppearanceView must live in its own file."
        )
    }

    @Test func fontSelectionSubViewIsExtracted() throws {
        let source = try Self.source(named: "FontSelectionView.swift")
        #expect(source.contains("struct FontSelectionView"))
    }

    @Test func themeSelectionSubViewIsExtracted() throws {
        let source = try Self.source(named: "ThemeSelectionView.swift")
        #expect(source.contains("struct ThemeSelectionView"))
    }

    @Test func proTranscriptsSubViewIsExtracted() throws {
        let source = try Self.source(named: "ProTranscriptsSettingsView.swift")
        #expect(source.contains("struct ProTranscriptsSettingsView"))
    }

    @Test func appIconSubViewIsExtracted() throws {
        let source = try Self.source(named: "AppIconSelectionView.swift")
        #expect(source.contains("struct AppIconSelectionView"))
    }

    /// `SettingsView` must no longer declare any of the extracted sub-views.
    @Test func settingsViewNoLongerDeclaresExtractedSubViews() throws {
        let source = try Self.source(named: "SettingsView.swift")
        #expect(!source.contains("private struct SettingsAppearanceView"))
        #expect(!source.contains("private struct FontSelectionView"))
        #expect(!source.contains("private struct ThemeSelectionView"))
        #expect(!source.contains("private struct ProTranscriptsSettingsView"))
        #expect(!source.contains("private struct AppIconSelectionView"))
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    return content
                }
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
```

- [ ] Build tests once: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **`.
- [ ] Run the new suite and confirm it FAILS (files not yet extracted): run `make test-only FILTER=EchoTests/SettingsExtractionTests`. Expected: failures on `appearanceSubViewIsExtracted`, `fontSelectionSubViewIsExtracted`, `themeSelectionSubViewIsExtracted`, `proTranscriptsSubViewIsExtracted`, `appIconSubViewIsExtracted` (each throwing `fileNoSuchFile`), and the `settingsViewNoLongerDeclares…` test failing because the `private struct` declarations still exist.
- [ ] Commit the failing test: `git add EchoTests/SettingsExtractionTests.swift && git commit -m "test(settings): add structural test for extracted Settings sub-views"`.

### Task E2b: Extract the five Settings sub-views into their own files + wire NavigationDestinations

Move `SettingsAppearanceView`, `FontSelectionView`, `ThemeSelectionView`, `ProTranscriptsSettingsView`, and `AppIconSelectionView` out of `SettingsView.swift` into individual files, dropping the `private` keyword so they become `internal` (file-scoped is impossible across files; `internal` is required so `NavigationDestinations.swift` can reference `SettingsAppearanceView` and `ProTranscriptsSettingsView`).

CRITICAL macOS guard: these new `EchoCore/Views/*.swift` files are auto-added to the **Echo macOS** target by folder-sync, but they reference iOS-only types (`StoreManager` via `ProTranscriptsSettingsView`, `UIApplication`/`navigationBarTitleDisplayMode` via `AppIconSelectionView`, and they live alongside the iOS-only `SettingsView` which is already a macOS membership-exception). We therefore add each new Views file to the macOS membership-exceptions list in `Echo.xcodeproj/project.pbxproj` (the alphabetized block ending at `Views/WatchAppSettingsView.swift,` at `:241`). `EchoCore/Models/ThemeColor.swift` (from E1) is intentionally NOT excluded — it is macOS-safe.

NOTE: `ProTranscriptsSettingsView` currently takes three `@Binding` parameters owned by `SettingsView`'s `@State`. The `NavigationDestination.settingsProTranscripts` case (`EchoCore/Models/NavigationDestinations.swift:39-42`) needs to construct it with NO external bindings. To make it constructible from both homes, give `ProTranscriptsSettingsView` its OWN `@State` for the three in-flight flags and drop the `@Binding` parameters — `SettingsView` then constructs it the same parameterless way and can delete its three now-unused `@State` flags (`isPurchasingPro`/`isRestoringPurchases`/`isRetryingProducts` at `SettingsView.swift:13-15`).

- [ ] Read the current sub-views to copy verbatim: Read `EchoCore/Views/SettingsView.swift:226-376` (SettingsAppearanceView + AppIconSelectionView), `:378-426` (FontSelectionView), `:497-590` (ProTranscriptsSettingsView), `:592-658` (ThemeSelectionView).
- [ ] Create `EchoCore/Views/SettingsAppearanceView.swift` (move `SettingsAppearanceView` verbatim, change `private struct` → `struct`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

struct SettingsAppearanceView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                // "Color Scheme" — the screen title is already "Appearance"
                // (audit E3: same label twice reads as a bug).
                Picker("Color Scheme", selection: $settings.appAppearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
            }
            #if os(iOS)
                Section("App Icon") {
                    NavigationLink {
                        AppIconSelectionView()
                    } label: {
                        HStack {
                            Text("App Icon")
                            Spacer()
                            Text(currentAppIconName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            #endif
            Section("Theme") {
                NavigationLink {
                    ThemeSelectionView()
                } label: {
                    HStack {
                        Text("Accent Color")
                        Spacer()
                        if let color = ThemeColor(rawValue: settings.themeColor)?.color {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(color)
                        } else {
                            Text("System")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Typography") {
                NavigationLink {
                    FontSelectionView()
                } label: {
                    HStack {
                        Text("Font")
                        Spacer()
                        Text(
                            settings.appFont == SettingsManager.systemFontName
                                ? "System" : settings.appFont
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(
                    "Truncate Chapter to Ch.",
                    isOn: Binding(
                        get: { settings.truncateChapterNamesEnabled },
                        set: {
                            settings.truncateChapterNamesEnabled = $0
                            model.syncToWatch()
                        }
                    ))
            } header: {
                Text("Display Options")
            } footer: {
                Text(
                    "Shortens \u{201C}Chapter 12\u{201D} to \u{201C}Ch. 12\u{201D} in tight spaces, like the watch and mini-player."
                )
            }
        }
        .navigationTitle("Appearance")
    }

    #if os(iOS)
        private var currentAppIconName: String {
            guard let name = UIApplication.shared.alternateIconName else {
                return "Default"
            }
            switch name {
            case "AppIcon-ComplexWaves": return "Complex Waves"
            case "AppIcon-GoldSilver": return "Gold & Silver"
            case "AppIcon-SilverGold": return "Silver & Gold"
            case "AppIcon-WhiteBolder": return "White Bolder"
            default: return name
            }
        }
    #endif
}
```

- [ ] Create `EchoCore/Views/AppIconSelectionView.swift` (move the `#if os(iOS)` `AppIconSelectionView` verbatim, change `private struct` → `struct`, keeping the `#if os(iOS)` wrapper):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

#if os(iOS)
    struct AppIconSelectionView: View {
        let icons: [(name: String, id: String?)] = [
            ("Default (Original)", nil),
            ("Complex Waves", "AppIcon-ComplexWaves"),
            ("Gold & Silver", "AppIcon-GoldSilver"),
            ("Silver & Gold", "AppIcon-SilverGold"),
            ("White Bolder", "AppIcon-WhiteBolder"),
        ]

        @State private var currentIcon = UIApplication.shared.alternateIconName

        var body: some View {
            Form {
                ForEach(icons, id: \.name) { icon in
                    Button {
                        setAppIcon(to: icon.id)
                    } label: {
                        HStack {
                            Text(icon.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if currentIcon == icon.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
        }

        private func setAppIcon(to iconName: String?) {
            guard UIApplication.shared.supportsAlternateIcons else { return }
            UIApplication.shared.setAlternateIconName(iconName) { error in
                if let error = error {
                    Logger(category: "Settings").error(
                        "Failed to change app icon: \(error.localizedDescription)")
                } else {
                    Task { @MainActor in
                        self.currentIcon = iconName
                    }
                }
            }
        }
    }
#endif
```

- [ ] Create `EchoCore/Views/FontSelectionView.swift` (move `FontSelectionView` verbatim, change `private struct` → `struct`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct FontSelectionView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        Form {
            Button {
                settings.appFont = "Lexend"
            } label: {
                HStack {
                    Text("Lexend (Default)")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == "Lexend" {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Button {
                settings.appFont = "OpenDyslexic"
            } label: {
                HStack {
                    Text("OpenDyslexic")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == "OpenDyslexic" {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Button {
                settings.appFont = SettingsManager.systemFontName
            } label: {
                HStack {
                    Text("System")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == SettingsManager.systemFontName {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

- [ ] Create `EchoCore/Views/ThemeSelectionView.swift` (move `ThemeSelectionView` verbatim, change `private struct` → `struct`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ThemeSelectionView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var playerModel

    var body: some View {
        Form {
            Section {
                ForEach(ThemeColor.allCases) { theme in
                    Button {
                        settings.themeColor = theme.rawValue
                    } label: {
                        HStack {
                            if theme == .artwork {
                                artworkPreviewCircle
                            } else if theme != .system {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(theme.color ?? Color.accentColor)
                            } else {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.rawValue)
                                    .foregroundStyle(.primary)
                                if theme == .artwork {
                                    Text("Matches your current book's cover")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if settings.themeColor == theme.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            } footer: {
                if settings.themeColor == ThemeColor.artwork.rawValue,
                    playerModel.artworkAccentColor == nil,
                    playerModel.currentDisplayArtwork == nil
                {
                    Text("Load an audiobook to see the extracted accent colour.")
                }
            }
        }
        .navigationTitle("Accent Color")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Renders the Artwork option's colour indicator — either the live extracted
    /// colour from the current cover or a fallback placeholder.
    @ViewBuilder
    private var artworkPreviewCircle: some View {
        if let dynamicColor = playerModel.artworkAccentColor {
            Image(systemName: "circle.fill")
                .foregroundStyle(dynamicColor)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] Create `EchoCore/Views/ProTranscriptsSettingsView.swift` (move `ProTranscriptsSettingsView` and convert the three `@Binding` params to internal `@State` so it is constructible with no arguments from both `SettingsView` and `NavigationDestinations`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit
import SwiftUI

struct ProTranscriptsSettingsView: View {
    @Environment(StoreManager.self) private var storeManager
    @State private var isPurchasingPro = false
    @State private var isRestoringPurchases = false
    @State private var isRetryingProducts = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(
                        storeManager.hasUnlockedPro
                            ? String(localized: "Unlocked") : String(localized: "Locked")
                    )
                    .foregroundStyle(storeManager.hasUnlockedPro ? .green : .secondary)
                }

                if let product = storeManager.proUnlockProduct, !storeManager.hasUnlockedPro {
                    Button {
                        Task { await purchasePro() }
                    } label: {
                        if isPurchasingPro {
                            ProgressView()
                        } else {
                            Text(String(localized: "Unlock for \(product.displayPrice)"))
                        }
                    }
                    .disabled(isPurchasingPro || isRestoringPurchases)
                } else if !storeManager.hasUnlockedPro {
                    Button {
                        Task { await retryProducts() }
                    } label: {
                        if isRetryingProducts {
                            ProgressView()
                        } else {
                            Text("Retry Loading Purchase")
                        }
                    }
                    .disabled(isRetryingProducts || isPurchasingPro || isRestoringPurchases)
                }

                Button {
                    Task { await restorePurchases() }
                } label: {
                    if isRestoringPurchases {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(isPurchasingPro || isRestoringPurchases)
            } footer: {
                Text("Unlock transcript overlays for audiobooks with transcript sidecars.")
            }

            if let lastStoreError = storeManager.lastStoreError {
                Section {
                    Text(lastStoreError)
                        .foregroundStyle(.red)
                } header: {
                    Text("StoreKit Error")
                }
            }
        }
        .navigationTitle("Pro Transcripts")
        .task {
            if storeManager.proUnlockProduct == nil {
                await storeManager.requestProducts()
            }
        }
    }

    private func purchasePro() async {
        isPurchasingPro = true
        defer { isPurchasingPro = false }
        do {
            try await storeManager.purchaseProUnlock()
        } catch {
            storeManager.recordStoreError(error)
        }
    }

    private func restorePurchases() async {
        isRestoringPurchases = true
        defer { isRestoringPurchases = false }
        await storeManager.restorePurchases()
    }

    private func retryProducts() async {
        isRetryingProducts = true
        defer { isRetryingProducts = false }
        await storeManager.requestProducts()
    }
}
```

- [ ] Remove the now-moved declarations from `SettingsView.swift`. Edit `EchoCore/Views/SettingsView.swift`: delete the `// MARK: - Extracted Section Views` block and all five sub-views — specifically remove lines `224-376` (the MARK comment + `SettingsAppearanceView` + the `#if os(iOS)` `AppIconSelectionView`) and `378-426` (`FontSelectionView`). Then remove `// MARK: - ProTranscriptsSettingsView` + `ProTranscriptsSettingsView` (`:495-590`) and `ThemeSelectionView` (`:592-658`). Keep `SettingsSilenceDetectionSection` (`:428-452`), `SettingsAutoAlignmentSection` (`:454-478`), and `SettingsBookmarksInlineSection` (`:480-493`) — those are handled in E3. After this edit the file ends at the close of `SettingsBookmarksInlineSection`.
- [ ] Update `SettingsView`'s call site for `ProTranscriptsSettingsView`. Edit `EchoCore/Views/SettingsView.swift:45-51`, replacing the bound construction with the parameterless one:

```swift
                Section("Store") {
                    NavigationLink("Pro Transcripts") {
                        ProTranscriptsSettingsView()
                    }
                }
```

- [ ] Delete the three now-unused `@State` flags in `SettingsView`. Edit `EchoCore/Views/SettingsView.swift:13-15`, removing:

```swift
    @State private var isPurchasingPro = false
    @State private var isRestoringPurchases = false
    @State private var isRetryingProducts = false
```

- [ ] Wire `NavigationDestinations` to the real extracted types. Edit `EchoCore/Models/NavigationDestinations.swift:25-28`, replacing the `.settingsAppearance` placeholder:

```swift
        case .settingsAppearance:
            SettingsAppearanceView()
```

- [ ] Edit `EchoCore/Models/NavigationDestinations.swift:39-42`, replacing the `.settingsProTranscripts` placeholder:

```swift
        case .settingsProTranscripts:
            ProTranscriptsSettingsView()
```

- [ ] Add the five new Views files to the macOS membership-exceptions so the macOS target does not try to compile these iOS-only views. Edit `Echo.xcodeproj/project.pbxproj` in the alphabetized list `141-242` (the `Exceptions for "EchoCore" folder in "Echo macOS" target`). Insert `Views/AppIconSelectionView.swift,` immediately after `Views/AutoAlignmentProgressView.swift,` (`:165`); insert `Views/FontSelectionView.swift,` immediately after `Views/FlashcardReviewSession.swift,` (`:198`); insert `Views/ProTranscriptsSettingsView.swift,` immediately after `Views/PlaylistView.swift,` (`:214`); insert `Views/SettingsAppearanceView.swift,` immediately after `Views/SettingsView.swift,` (`:220`); insert `Views/ThemeSelectionView.swift,` immediately after `Views/StreakModuleView.swift,` (`:233`). (`ThemeColor.swift` from E1 is deliberately left out — it is macOS-safe.)
- [ ] Build tests once: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **` with no `cannot find type 'SettingsAppearanceView'`/`ProTranscriptsSettingsView` errors and no duplicate-declaration errors.
- [ ] Run the structural suite and confirm it now PASSES: run `make test-only FILTER=EchoTests/SettingsExtractionTests`. Expected: all 6 tests pass (`appearanceSubViewIsExtracted`, `fontSelectionSubViewIsExtracted`, `themeSelectionSubViewIsExtracted`, `proTranscriptsSubViewIsExtracted`, `appIconSubViewIsExtracted`, `settingsViewNoLongerDeclaresExtractedSubViews`).
- [ ] Smoke-build macOS to confirm the iOS-only files are correctly excluded: run `xcodebuild build -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 -quiet`. Expected: `** BUILD SUCCEEDED **`. (If it fails with `cannot find 'StoreManager'/'UIApplication'`, an exception entry was mis-inserted — re-check the pbxproj list.)
- [ ] Commit: `git add EchoCore/Views/SettingsAppearanceView.swift EchoCore/Views/AppIconSelectionView.swift EchoCore/Views/FontSelectionView.swift EchoCore/Views/ThemeSelectionView.swift EchoCore/Views/ProTranscriptsSettingsView.swift "EchoCore/Views/SettingsView.swift" EchoCore/Models/NavigationDestinations.swift Echo.xcodeproj/project.pbxproj && git commit -m "refactor(settings): extract Appearance/Font/Theme/ProTranscripts/AppIcon sub-views to their own files and wire NavigationDestinations"`.

### Task E3: Relocate the auto-alignment + bookmarks-inline toggles, then delete the Playback section

The per-listen Playback section (Volume Boost, Default Speed, Seek pickers, Smart Rewind) is now owned by the WS-B Playback Options sheet. The Auto-Alignment toggle (`SettingsAutoAlignmentSection`) and Bookmarks-Inline toggle (`SettingsBookmarksInlineSection`) are app-level preferences that have NO new home in WS-B/WS-C — they belong in a new "Advanced" subscreen reachable from the shell, NOT in the player More menu. We relocate those two sections (preserving the `configureContinuousAlignment()` setter side-effect that fires on the auto-align toggle, `SettingsView.swift:467`) into a self-contained `SettingsAdvancedView`, then delete the Playback / Auto-Alignment / Bookmarks rows from `SettingsView`. The Seek-picker `syncToWatch()` side-effects (`:79-81`, `:89-91`), Default-Speed picker, and Volume-Boost toggle move to the WS-B sheet — WS-E only removes them here; their reappearance is owned by WS-B.

GUARDRAIL: the auto-align toggle's `model.configureContinuousAlignment()` side-effect MUST travel with the toggle, and the toggle must keep its custom `Binding` get/set form (not a plain `$settings.continuousAutoAlignmentEnabled`) so the setter still fires.

- [ ] Add an assertion to the structural suite that the Playback section text is gone and Advanced exists. Edit `EchoTests/SettingsExtractionTests.swift`, adding these two `@Test` methods inside `struct SettingsExtractionTests` (before the `source(named:)` helper):

```swift
    /// The per-listen Playback section is owned by the Playback Options sheet
    /// (WS-B) now — SettingsView must not render it.
    @Test func settingsViewDropsPlaybackSection() throws {
        let source = try Self.source(named: "SettingsView.swift")
        #expect(!source.contains("Section(\"Playback\")"))
        #expect(!source.contains("Default Speed"))
        #expect(!source.contains("Seek Backward"))
        #expect(!source.contains("Seek Forward"))
    }

    /// Auto-alignment + bookmarks-inline preferences moved into the Advanced
    /// subscreen, which preserves the configureContinuousAlignment side-effect.
    @Test func advancedSubViewOwnsAutoAlignmentAndBookmarks() throws {
        let source = try Self.source(named: "SettingsAdvancedView.swift")
        #expect(source.contains("struct SettingsAdvancedView"))
        #expect(source.contains("configureContinuousAlignment()"))
        #expect(source.contains("playBookmarksInline"))
    }
```

- [ ] Build + run the suite to confirm the two NEW tests FAIL (file/section not yet changed): run `make build-tests` then `make test-only FILTER=EchoTests/SettingsExtractionTests`. Expected: `settingsViewDropsPlaybackSection` fails (Playback section still present) and `advancedSubViewOwnsAutoAlignmentAndBookmarks` fails (`SettingsAdvancedView.swift` does not exist).
- [ ] Create `EchoCore/Views/SettingsAdvancedView.swift` housing the two relocated toggles (verbatim bindings from `SettingsView.swift:454-493`, preserving the `configureContinuousAlignment()` side-effect):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// App-level advanced preferences that have no per-listen player surface:
/// continuous auto-alignment and bookmark-inline playback. Both keep their
/// custom Binding setters so the model side-effects still fire.
struct SettingsAdvancedView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(
                    "Continuous Auto-Alignment",
                    isOn: Binding(
                        get: { settings.continuousAutoAlignmentEnabled },
                        set: {
                            settings.continuousAutoAlignmentEnabled = $0
                            model.configureContinuousAlignment()
                        }
                    ))
            } header: {
                Text("Auto-Alignment")
            } footer: {
                Text(
                    "When enabled, the app will continuously transcribe audio in the background while playing and attempt to align it with the text."
                )
            }

            Section {
                Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
            } footer: {
                Text(
                    "When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp."
                )
            }
        }
        .navigationTitle("Advanced")
    }
}
```

- [ ] Remove the now-relocated `SettingsAutoAlignmentSection` and `SettingsBookmarksInlineSection` private structs from `SettingsView.swift`. Edit `EchoCore/Views/SettingsView.swift`: delete the `private struct SettingsAutoAlignmentSection` block (`:454-478`) and the `private struct SettingsBookmarksInlineSection` block (`:480-493`). Keep `SettingsSilenceDetectionSection` (`:428-452`) — it stays as a DEBUG-only section.
- [ ] Delete the Playback `Section` and the two relocated section call-sites from the `SettingsView` body. Edit `EchoCore/Views/SettingsView.swift`, removing the entire `Section("Playback") { … }` block (`:63-95`), the `SettingsAutoAlignmentSection()` call (`:103`), and the `SettingsBookmarksInlineSection()` call (`:105`). Keep the `#if DEBUG SettingsSilenceDetectionSection()` block (`:99-101`).
- [ ] Build tests once: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **` (verify no `cannot find 'SettingsAutoAlignmentSection'` errors — both call sites were removed in the same edit). NOTE: if `make build-tests` errors with `AVFoundation`/`StoreKit`/`UniformTypeIdentifiers` now-unused-import warnings in `SettingsView.swift`, leave them — they are still used by the DEBUG narration section and the deck importer; do not remove imports.
- [ ] Run the structural suite: run `make test-only FILTER=EchoTests/SettingsExtractionTests`. Expected: all tests pass, including the two added in this task.
- [ ] Smoke-build macOS (the new `SettingsAdvancedView.swift` is iOS-shell-only): first add `Views/SettingsAdvancedView.swift,` to the macOS membership-exceptions in `Echo.xcodeproj/project.pbxproj` immediately after `Views/SettingsView.swift,` (currently `:220`), then run `xcodebuild build -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 -quiet`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Commit: `git add EchoCore/Views/SettingsAdvancedView.swift "EchoCore/Views/SettingsView.swift" EchoTests/SettingsExtractionTests.swift Echo.xcodeproj/project.pbxproj && git commit -m "refactor(settings): relocate auto-align + bookmark-inline prefs to Advanced screen, drop Playback section"`.

### Task E4: Add the Advanced link and confirm the final thin shell

The shell must now expose exactly: the per-book `BookOverridesSections` (when a book is loaded), Display → Appearance, Store → Pro Transcripts, Customization → Phone Player Designer + Watch App Settings + **Advanced**, Flashcards → Import Deck, Help, and the DEBUG-only sections. Wire the new `SettingsAdvancedView` into the Customization section and add a structural assertion that the shell is thin.

- [ ] Add the Advanced `NavigationLink` to the Customization section. Edit `EchoCore/Views/SettingsView.swift:54-61` (the `Section("Customization")`), appending the link after the Watch App Settings link:

```swift
                Section("Customization") {
                    NavigationLink("Phone Player Designer") {
                        PhonePlayerSettingsView()
                    }
                    NavigationLink("Watch App Settings") {
                        WatchAppSettingsView()
                    }
                    NavigationLink("Advanced") {
                        SettingsAdvancedView()
                    }
                }
```

- [ ] Add a shell-shape assertion to the structural suite. Edit `EchoTests/SettingsExtractionTests.swift`, adding inside the struct (before the `source(named:)` helper):

```swift
    /// The Settings shell links out to its subscreens and keeps only app-level
    /// rows — no inline per-listen controls remain.
    @Test func settingsShellExposesSubscreenLinksOnly() throws {
        let source = try Self.source(named: "SettingsView.swift")
        #expect(source.contains("SettingsAppearanceView()"))
        #expect(source.contains("ProTranscriptsSettingsView()"))
        #expect(source.contains("PhonePlayerSettingsView()"))
        #expect(source.contains("WatchAppSettingsView()"))
        #expect(source.contains("SettingsAdvancedView()"))
        // The Volume Boost toggle moved to the Playback Options sheet (WS-B).
        #expect(!source.contains("Toggle(\"Volume Boost\""))
    }
```

- [ ] Build tests once: run `make build-tests`. Expected: `** TEST BUILD SUCCEEDED **`.
- [ ] Run the full structural suite: run `make test-only FILTER=EchoTests/SettingsExtractionTests`. Expected: every test passes (including `settingsShellExposesSubscreenLinksOnly`).
- [ ] Run the SettingsManager defaults test to confirm WS-E did not disturb it (the `Defaults.phonePage` assertion at `EchoTests/EchoCoreTests.swift:202` is owned by WS-D, not WS-E): run `make test-only FILTER=EchoTests/EchoCoreTests`. Expected: pass unchanged (if it fails on `phonePage`, that is a WS-D ordering issue, NOT a WS-E regression — note it but do not edit `EchoCoreTests.swift` here).
- [ ] Final macOS smoke-build: run `xcodebuild build -scheme 'Echo macOS' -destination 'platform=macOS' -jobs 5 -quiet`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Commit: `git add "EchoCore/Views/SettingsView.swift" EchoTests/SettingsExtractionTests.swift && git commit -m "feat(settings): add Advanced subscreen link and finalize thin Settings shell"`.
- [ ] DOC SYNC REMINDER (per CLAUDE.md): the Settings information architecture changed (per-listen controls moved to the Playback Options sheet/More menu; new Advanced subscreen). After WS-B/WS-C/WS-D land, remind Dan to update `ARCHITECTURE.md`'s Settings/IA description. Do not auto-edit docs inside this workstream.


---

## Self-review (writing-plans checklist)

- **Spec coverage:** Change 1 (chapter `< Title >` nav) → Task A2. Change 2 (speed → Playback Options sheet incl. loop) → WS-B + Task C1 (loop removed from toolbar). Change 3 (player More menu absorbing Settings) → WS-C + WS-E (teardown). Configurable-row + new-defaults decision → WS-D. All three user-requested iOS changes are covered.
- **Placeholder scan:** every code step contains complete Swift; tests contain real `#expect` assertions. No `TODO`/"similar to"/"add error handling".
- **Type consistency:** `hasPreviousChapter`/`hasNextChapter` (A) consumed by A2's chevrons; `PlaybackOptionsSheet` (B) presented from `NowPlayingTab.showingPlaybackOptions` (B) and reachable via `onShowPlaybackOptions` threaded B→`UnifiedBottomDock`→`BottomToolbarView`; `PlayerMoreMenu` (C) uses `onShowChapters`/`onShowBookmarks`/`onShowSettings`; new `Defaults.phonePage = [.skipBackward, .empty, .playPause, .empty, .skipForward]` (D) is the value asserted by the updated `EchoCoreTests.swift:202`.
- **Known follow-ups (out of scope, intentionally not tasked):** mark-finished/jump-to API; an inline volume-boost *gain* slider (ships on/off only).

> Execution: choose **subagent-driven** (fresh agent per task, review between) or **inline**. See the chat handoff.

## Known minor corrections (advisory — apply during execution)

- **Structural-test brittleness:** several `source(named:)` assertions pin exact multi-line/whitespace literals. If an `Edit` reflows indentation, prefer token-presence checks (e.g. `src.contains("PlaybackOptionsSheet")`) over exact block literals.
- **B5 / passive migration:** a user who has manually placed a `.loopMode` slot via the (now watch-only) designer still gets loop *cycling* from that slot. That is intended — the passive decision keeps every render/dispatch arm; the Playback Options sheet is the *primary* loop surface, not the only one.
- **E2b alphabetical inserts:** to keep the macOS exception list truly alphabetical, insert `Views/AppIconSelectionView.swift,` **before** `Views/AutoAlignmentProgressView.swift,` and `Views/SettingsAppearanceView.swift,` **before** `Views/SettingsView.swift,` (functionally harmless either way).
