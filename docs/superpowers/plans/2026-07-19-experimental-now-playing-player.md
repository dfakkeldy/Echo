# Experimental Now Playing Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in experimental iOS Now Playing layout (full-bleed cover + configurable floating Liquid Glass buttons with snap zones and lock/edit mode) plus app-wide tap-to-fullscreen and long-press-save-to-Photos on artwork.

**Architecture:** A `SettingsManager` flag branches `NowPlayingTab` into a new `ExperimentalNowPlayingView` and makes `RootTabView` swap the shared `UnifiedBottomDock` for a full-screen `ExperimentalControlLayer` while the Now Playing tab is active. Button configuration is a small Codable model persisted as JSON `Data` in `UserDefaults`; positioning is a pure zone-resolver function. Image gestures live in one reusable `ZoomableArtwork` component plus a closure-injected `PhotoLibrarySaver`.

**Tech Stack:** SwiftUI, `@Observable`, Swift Testing (EchoTests), PhotosUI/`PHPhotoLibrary`, iOS 26 `.glassEffect` with `.ultraThinMaterial` fallback.

**Spec:** `docs/superpowers/specs/2026-07-19-experimental-now-playing-player-design.md`

## Global Constraints

- iOS-only behavior. macOS (`Mac*` files) and watchOS are untouched. New **view** files must be wrapped in `#if canImport(UIKit)` … `#endif` (whole file, after the SPDX line) so the folder-synced macOS/echo-cli targets still compile without pbxproj membership-exception edits. New **model** files must be platform-neutral (Foundation/CoreGraphics only, no UIKit) because `SettingsManager` compiles into every target.
- Deployment floor is iOS 18. Every `.glassEffect` use MUST be gated `if #available(iOS 26.0, *)` with an `.ultraThinMaterial` + stroke fallback.
- New settings are phone-only: persist via `defaults.set(...)`, never `appGroupSet(...)`.
- First line of every new Swift file: `// SPDX-License-Identifier: GPL-3.0-or-later` (the SwiftFormat edit hook reflows files — verify SPDX stays line 1 after edits).
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) in `EchoTests/`, `@testable import Echo`. Build once with `make build-tests`, then iterate with `make test-only FILTER=EchoTests/<Suite>`. Builds go through the memory-pressure gate automatically; if blocked, wait and retry (`"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests`).
- Conventional Commits. Commit at the end of every task (and mid-task where marked).
- Per AGENTS.md: `foregroundStyle` not `foregroundColor`, `clipShape(.rect(cornerRadius:))`, `Button` not `onTapGesture` (except where tap *location/count* matters), no `GeometryReader` where a newer API works, no computed-property view decomposition — new `View` structs instead.
- UI tests are excluded from the scheme — visual behavior is verified by building and running in the simulator; unit tests cover models, resolvers, codecs, and settings.

## File Structure (locked decomposition)

| File | Responsibility | Task |
|---|---|---|
| `EchoCore/Services/SettingsManager.swift` (modify) | `experimentalNowPlayingLayout: Bool`, `experimentalPlayerLayoutData: Data` | 0, 2 |
| `EchoCore/Views/SettingsNowPlayingView.swift` (modify) | Experimental section: toggle + Reset Layout | 0, 3 |
| `EchoCore/Views/Player/ExperimentalNowPlayingView.swift` (new) | Experimental page: background + metadata + scrubber | 0, 1 |
| `EchoCore/Views/Player/FullBleedCoverBackground.swift` (new) | Cover aspect-fill + gradient dissolve into theme wash | 1 |
| `EchoCore/Models/ExperimentalPlayerLayout.swift` (new) | `PlayerSnapZone`, `ExperimentalPlayerButton`, layout codec + mutations (platform-neutral) | 2, 3 |
| `EchoCore/Models/PlayerZoneResolver.swift` (new) | Pure `(zone, offset, size) → CGPoint` (platform-neutral) | 2 |
| `EchoCore/Views/Player/GlassControlButton.swift` (new) | One round glass button (glassEffect / material fallback) | 2 |
| `EchoCore/Views/Player/ExperimentalControlLayer.swift` (new) | Hosts configured buttons; dispatch; overflow; lock/edit | 2, 3 |
| `EchoCore/Views/RootTabView.swift` (modify) | Dock swap for the experimental layer | 0, 2 |
| `EchoCore/Views/NowPlayingTab.swift` (modify) | Branch to experimental view; `ZoomableArtwork` on cover | 0, 4 |
| `EchoCore/Views/Components/ZoomableArtwork.swift` (new) | Tap→fullscreen wrapper for any `UIImage` | 4 |
| `EchoCore/Views/Components/FullscreenImageViewer.swift` (new) | Zoom/pan/dismiss viewer | 4 |
| `EchoCore/Services/PhotoLibrarySaver.swift` (new) | Add-only Photos save, closure-injected seam | 5 |
| `EchoCore/Views/ReaderTab.swift` + `ReaderTab+Alignment.swift` (modify) | Fullscreen menu action; save path replacement | 4, 5 |
| `EchoTests/ExperimentalPlayerSettingsTests.swift` (new) | Flag + layout persistence | 0, 2 |
| `EchoTests/ExperimentalPlayerLayoutTests.swift` (new) | Codec, defaults, mutations | 2, 3 |
| `EchoTests/PlayerZoneResolverTests.swift` (new) | Zone math | 2 |
| `EchoTests/PhotoLibrarySaverTests.swift` (new) | Save/denied/failed paths | 5 |

**One deliberate refinement vs the spec (§ lock/edit):** edit mode is entered by **long-pressing any glass button** (plus an "Edit Buttons…" item in the experimental overflow menu), not by long-pressing empty space — the layer must stay hit-test-transparent outside button frames so the scrubber/metadata beneath remain usable.

---

### Task 0: Foundation — flag, toggle, shell view, dock suppression

**Files:**
- Modify: `EchoCore/Services/SettingsManager.swift` (Defaults ~line 49, Keys ~line 128, property ~line 181, init ~line 612, registration ~line 831)
- Modify: `EchoCore/Views/SettingsNowPlayingView.swift` (after the "Play Bookmarks Inline" section, ~line 66)
- Create: `EchoCore/Views/Player/ExperimentalNowPlayingView.swift`
- Modify: `EchoCore/Views/NowPlayingTab.swift` (~line 58 branch; ~line 74 bottom inset)
- Modify: `EchoCore/Views/RootTabView.swift` (~line 277 dock condition)
- Test: `EchoTests/ExperimentalPlayerSettingsTests.swift`

**Interfaces:**
- Consumes: `SettingsManager(defaults:appGroupDefaults:)`, `SettingsManager.registerDefaults(defaults:appGroupDefaults:)`, `PlayerModel` environment, `AdaptiveBackground`, `PlayerScrubberView`, `NowPlayingLayout.horizontalPadding`.
- Produces: `settings.experimentalNowPlayingLayout: Bool` (read by Tasks 1–3 and `RootTabView`); `ExperimentalNowPlayingView` (extended by Task 1); the dock-suppression condition (replaced by layer-swap in Task 2).

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ExperimentalPlayerSettingsTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct ExperimentalPlayerSettingsTests {

    @Test func experimentalLayoutDefaultsOffAndPersists() throws {
        let suiteName = "test-exp-player-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: defaults)
        let settings = SettingsManager(defaults: defaults, appGroupDefaults: defaults)

        #expect(SettingsManager.Defaults.experimentalNowPlayingLayout == false)
        #expect(settings.experimentalNowPlayingLayout == false)

        settings.experimentalNowPlayingLayout = true

        let reloaded = SettingsManager(defaults: defaults, appGroupDefaults: defaults)
        #expect(reloaded.experimentalNowPlayingLayout == true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make build-tests`
Expected: **compile failure** — `SettingsManager` has no member `experimentalNowPlayingLayout`. (A compile failure at the right symbol is this step's "red".)

- [ ] **Step 3: Add the setting (5 touch points, mirroring `playerLayoutStyle`/`truncateChapterNamesEnabled`)**

In `EchoCore/Services/SettingsManager.swift`:

In `enum Defaults` (near `static let playerLayoutStyle = "default"`, ~line 59):
```swift
static let experimentalNowPlayingLayout = false
```

In `enum Keys` (near `static let playerLayoutStyle = "playerLayoutStyle"`, ~line 137):
```swift
static let experimentalNowPlayingLayout = "experimentalNowPlayingLayout"
```

With the stored properties (next to `playerLayoutStyle`, ~line 181 — phone-only, so plain `defaults`, NOT `appGroupSet`):
```swift
var experimentalNowPlayingLayout: Bool {
    didSet { defaults.set(experimentalNowPlayingLayout, forKey: Keys.experimentalNowPlayingLayout) }
}
```

In `init` (next to the `playerLayoutStyle` read, ~line 612):
```swift
experimentalNowPlayingLayout = defaults.bool(forKey: Keys.experimentalNowPlayingLayout)
```

In the registration dictionary (near `Keys.playerLayoutStyle: Defaults.playerLayoutStyle`, ~line 831):
```swift
Keys.experimentalNowPlayingLayout: Defaults.experimentalNowPlayingLayout,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/ExperimentalPlayerSettingsTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit the setting**

```bash
git add EchoCore/Services/SettingsManager.swift EchoTests/ExperimentalPlayerSettingsTests.swift
git commit -m "feat(player): add experimentalNowPlayingLayout setting (default off)"
```

- [ ] **Step 6: Add the Settings toggle**

In `EchoCore/Views/SettingsNowPlayingView.swift`, after the "Play Bookmarks Inline" `Section` (closes ~line 66), insert:

```swift
#if os(iOS)
    Section {
        Toggle("Experimental Player Layout", isOn: $settings.experimentalNowPlayingLayout)
    } header: {
        Text("Experimental")
    } footer: {
        Text(
            "A full-bleed cover layout with floating glass buttons you can rearrange. Turn off any time to return to the standard player."
        )
    }
#endif
```

- [ ] **Step 7: Create the shell view**

Create `EchoCore/Views/Player/ExperimentalNowPlayingView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Experimental full-bleed Now Playing layout (behind
    /// `SettingsManager.experimentalNowPlayingLayout`). Task 0 ships the shell:
    /// standard background + cover + metadata + scrubber, no transport controls
    /// (the shared dock is suppressed; lock screen still controls playback).
    /// Task 1 replaces the background, Task 2 adds the glass control layer.
    struct ExperimentalNowPlayingView: View {
        @Environment(PlayerModel.self) private var model

        let showBookSettings: () -> Void

        var body: some View {
            ZStack {
                AdaptiveBackground()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ExperimentalArtworkView()
                        .frame(minHeight: 150, maxHeight: 360)

                    ExperimentalMetadataView(showBookSettings: showBookSettings)
                        .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                        .padding(.top, 16)

                    PlayerScrubberView()
                        .containerRelativeFrame(.horizontal) { width, _ in
                            max(0, width - 2 * NowPlayingLayout.horizontalPadding)
                        }
                        .tint(model.resolvedThemeTint)
                        .padding(.vertical, 16)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Cover image (or placeholder). Same content rules as NowPlayingTab.artworkView.
    struct ExperimentalArtworkView: View {
        @Environment(PlayerModel.self) private var model

        var body: some View {
            Group {
                if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .accessibilityLabel(Text("Cover of \(model.currentTitle)"))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .clipShape(.rect(cornerRadius: 16))
            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
        }
    }

    /// Book eyebrow + title. Chapter chevrons arrive with the control layer (Task 2).
    struct ExperimentalMetadataView: View {
        @Environment(PlayerModel.self) private var model

        let showBookSettings: () -> Void

        var body: some View {
            VStack(spacing: 5) {
                Button(action: showBookSettings) {
                    Text(model.currentBookTitle)
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens book settings")

                Text(model.currentTitle)
                    .font(.title3.bold())
                    .lineLimit(1)
            }
        }
    }
#endif
```

Note: check `PlayerModel` for the exact book-title property before building — `NowPlayingTab.metadataArea` builds a `secondaryLineText` from model fields; reuse the same source fields (grep `secondaryLineText` in `NowPlayingTab.swift` and copy its composition into `ExperimentalMetadataView` if `currentBookTitle` does not exist).

- [ ] **Step 8: Branch NowPlayingTab and free the bottom inset**

In `EchoCore/Views/NowPlayingTab.swift`, replace the layout selection (~lines 53–59):

```swift
if settings.experimentalNowPlayingLayout {
    ExperimentalNowPlayingView(showBookSettings: showBookSettings)
} else if usesWideVisualListeningLayout,
    let snapshot = activeVisualListeningSnapshot
{
    wideVisualListeningLayout(snapshot: snapshot)
} else {
    compactPlaybackLayout
}
```

And make the bottom reservation conditional (~line 74):

```swift
.safeAreaInset(edge: .bottom, spacing: 0) {
    Color.clear.frame(
        height: settings.experimentalNowPlayingLayout ? 0 : model.bottomInset)
}
```

- [ ] **Step 9: Suppress the shared dock on the experimental tab**

In `EchoCore/Views/RootTabView.swift` add a computed property next to `topChromeHidden` (~line 587):

```swift
/// The experimental Now Playing layout draws its own floating controls, so the
/// shared bottom deck must stand down while that tab is frontmost. Reader and
/// Library keep the dock untouched.
private var usesExperimentalPlayerChrome: Bool {
    settings.experimentalNowPlayingLayout
        && model.selectedTab == .nowPlaying
        && model.folderURL != nil
}
```

Change the dock condition (~line 277) from `if !model.isPlayingVoiceMemo {` to:

```swift
if !model.isPlayingVoiceMemo && !usesExperimentalPlayerChrome {
```

(Verify `RootTabView` reads the selected tab as `model.selectedTab` — `NowPlayingTab` line 44 uses `model.selectedTab`, so it does; if `RootTabView` uses a local `selectedTab` binding instead, use that.)

- [ ] **Step 10: Build, run, verify manually**

Run: `make build-tests`
Expected: BUILD SUCCEEDED.

Then in the iPhone 17 simulator: toggle **Settings → Now Playing → Experimental Player Layout** on → Now Playing shows the shell (no dock); Reader tab still shows its dock; toggle off → standard player returns. No layout jump at the bottom edge.

- [ ] **Step 11: Run the full test suite for regressions**

Run: `make test`
Expected: PASS (existing parity/settings-extraction suites unaffected — a phone-only `defaults` key does not enter the watch-sync tables).

- [ ] **Step 12: Commit**

```bash
git add EchoCore/Views/Player/ExperimentalNowPlayingView.swift EchoCore/Views/SettingsNowPlayingView.swift EchoCore/Views/NowPlayingTab.swift EchoCore/Views/RootTabView.swift
git commit -m "feat(player): experimental Now Playing shell behind settings toggle"
```

---

### Task 1: Full-bleed cover-to-theme background

**Files:**
- Create: `EchoCore/Views/Player/FullBleedCoverBackground.swift`
- Modify: `EchoCore/Views/Player/ExperimentalNowPlayingView.swift`

**Interfaces:**
- Consumes: `PlayerModel.currentDisplayArtwork`, `.thumbnailImage`, `AdaptiveBackground`, `UnifiedTopHeader.rowOneHeight`.
- Produces: `FullBleedCoverBackground` view; `ExperimentalNowPlayingView` now content-bottom-weighted (Tasks 2–3 overlay controls; Task 4 adds cover tap).

- [ ] **Step 1: Create the background view**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Spec §5.2 "cover-to-theme blend": the cover aspect-fills the top of the
    /// screen, bleeding off the top and sides, then dissolves via an opacity
    /// mask into the cover-derived AdaptiveBackground wash beneath. The wash is
    /// the bottom layer, so the fade reveals it rather than a hard color.
    struct FullBleedCoverBackground: View {
        @Environment(PlayerModel.self) private var model

        /// Fraction of container height the cover occupies before fully fading.
        static let coverHeightFraction: CGFloat = 0.58
        /// Fade begins at this fraction of the cover's own height.
        static let fadeStartFraction: CGFloat = 0.55

        var body: some View {
            ZStack(alignment: .top) {
                AdaptiveBackground()

                if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                    Color.clear
                        .overlay(alignment: .top) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .containerRelativeFrame(.vertical, alignment: .top) { height, _ in
                            height * Self.coverHeightFraction
                        }
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: Self.fadeStartFraction),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .accessibilityHidden(true)  // decorative; the tappable cover carries the label
                }
            }
            .ignoresSafeArea()
        }
    }
#endif
```

The `Color.clear.overlay + clipped` idiom prevents the `.fill` image from inflating layout width (the same overflow trap the scrubber comment in `NowPlayingTab` documents).

- [ ] **Step 2: Rework `ExperimentalNowPlayingView` to use it**

Replace the shell body: background becomes `FullBleedCoverBackground()`; delete `ExperimentalArtworkView` usage from the VStack (the cover *is* the background now — keep the struct, Task 4 reuses it for the no-artwork placeholder case); metadata + scrubber move to the lower half:

```swift
var body: some View {
    ZStack {
        FullBleedCoverBackground()

        VStack(spacing: 0) {
            Spacer(minLength: 0)  // pushes content into the wash zone

            ExperimentalMetadataView(showBookSettings: showBookSettings)
                .padding(.horizontal, NowPlayingLayout.horizontalPadding)

            PlayerScrubberView()
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(0, width - 2 * NowPlayingLayout.horizontalPadding)
                }
                .tint(model.resolvedThemeTint)
                .padding(.vertical, 16)

            // Clearance for the control layer's bottom-arc buttons (Task 2).
            Spacer(minLength: 0)
                .frame(maxHeight: 160)
        }
    }
}
```

When there is no artwork (`model.currentDisplayArtwork ?? model.thumbnailImage == nil`), `FullBleedCoverBackground` renders just the wash — acceptable; the metadata still identifies the book.

- [ ] **Step 3: Build and verify visually**

Run: `make build-tests`
Expected: BUILD SUCCEEDED.

Simulator checks (iPhone 17): cover bleeds off top/sides under the status bar and `UnifiedTopHeader`; smooth dissolve into the wash (no hard seam — tune `fadeStartFraction` 0.45–0.65 if banding shows); text/scrubber sit on the wash zone with readable contrast in light **and** dark appearance; visual-listening books (scene imagery via `currentDisplayArtwork`) degrade sensibly.

- [ ] **Step 4: Run tests + commit**

Run: `make test-only FILTER=EchoTests/ExperimentalPlayerSettingsTests`
Expected: PASS.

```bash
git add EchoCore/Views/Player/FullBleedCoverBackground.swift EchoCore/Views/Player/ExperimentalNowPlayingView.swift
git commit -m "feat(player): full-bleed cover-to-theme background for experimental layout"
```

---

### Task 2: Layout model, zone resolver, glass buttons, control layer

**Files:**
- Create: `EchoCore/Models/ExperimentalPlayerLayout.swift`
- Create: `EchoCore/Models/PlayerZoneResolver.swift`
- Create: `EchoCore/Views/Player/GlassControlButton.swift`
- Create: `EchoCore/Views/Player/ExperimentalControlLayer.swift`
- Modify: `EchoCore/Services/SettingsManager.swift` (layout Data property, same 5 touch points as Task 0)
- Modify: `EchoCore/Views/RootTabView.swift` (render the layer where the dock was suppressed)
- Test: `EchoTests/ExperimentalPlayerLayoutTests.swift`, `EchoTests/PlayerZoneResolverTests.swift`, extend `EchoTests/ExperimentalPlayerSettingsTests.swift`

**Interfaces:**
- Consumes: `WatchAction` (Shared/WatchAction.swift — `String, Codable, CaseIterable`), `PlayerModel` action methods (`togglePlayPause()`, `skipBackward30()`, `skipForward30()`, `skipBackwardNavigation()`, `skipForwardNavigation()`, `previousSectionOrRestart()`, `nextSection()`, `cycleLoopMode()`, `setSleepTimer(_:)`, `cancelSleepTimer()`, `bookmarkDraftAtCurrentTime()`, `markPassageAtCurrentTime()`), `PlayerMoreMenu` closure set, `Haptic.play(_:)`.
- Produces:
  - `enum PlayerSnapZone: String, Codable, CaseIterable` — `upperLeading, upperTrailing, midLeading, midTrailing, lowerLeading, lowerCenter, lowerTrailing`.
  - `struct ExperimentalPlayerButton: Codable, Equatable, Identifiable { var action: WatchAction; var zone: PlayerSnapZone; var offset: CGSize }`.
  - `struct ExperimentalPlayerLayout: Codable, Equatable { var version: Int; var buttons: [ExperimentalPlayerButton] }` with `static let defaultLayout`, `static func decode(_ data: Data) -> ExperimentalPlayerLayout`, `func encoded() -> Data`.
  - `enum PlayerZoneResolver { static let maxNudge: CGFloat = 28; static func center(for zone: PlayerSnapZone, offset: CGSize, in size: CGSize, diameter: CGFloat) -> CGPoint; static func nearestZone(to point: CGPoint, in size: CGSize, diameter: CGFloat) -> PlayerSnapZone }` (nearestZone consumed by Task 3).
  - `settings.experimentalPlayerLayoutData: Data`.
  - `GlassControlButton(diameter:action:label:)` and `ExperimentalControlLayer` (extended by Task 3).

- [ ] **Step 1: Write failing model tests**

Create `EchoTests/ExperimentalPlayerLayoutTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ExperimentalPlayerLayoutTests {

    @Test func defaultLayoutHasCoreTransportAndFiveButtons() {
        let layout = ExperimentalPlayerLayout.defaultLayout
        #expect(layout.buttons.count == 5)
        #expect(layout.buttons.contains { $0.action == .playPause && $0.zone == .lowerCenter })
        #expect(layout.buttons.contains { $0.action == .skipBackward && $0.zone == .lowerLeading })
        #expect(layout.buttons.contains { $0.action == .skipForward && $0.zone == .lowerTrailing })
    }

    @Test func codecRoundTrips() {
        let layout = ExperimentalPlayerLayout.defaultLayout
        let decoded = ExperimentalPlayerLayout.decode(layout.encoded())
        #expect(decoded == layout)
    }

    @Test func garbageDataFallsBackToDefault() {
        let decoded = ExperimentalPlayerLayout.decode(Data("not json".utf8))
        #expect(decoded == ExperimentalPlayerLayout.defaultLayout)
    }

    @Test func emptyDataFallsBackToDefault() {
        #expect(ExperimentalPlayerLayout.decode(Data()) == ExperimentalPlayerLayout.defaultLayout)
    }
}
```

Create `EchoTests/PlayerZoneResolverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Testing

@testable import Echo

struct PlayerZoneResolverTests {
    private let size = CGSize(width: 390, height: 844)
    private let diameter: CGFloat = 56

    @Test func everyZoneStaysFullyOnScreenEvenWithMaxNudge() {
        for zone in PlayerSnapZone.allCases {
            for offset in [
                CGSize(width: 999, height: 999), CGSize(width: -999, height: -999), CGSize.zero,
            ] {
                let c = PlayerZoneResolver.center(
                    for: zone, offset: offset, in: size, diameter: diameter)
                #expect(c.x >= diameter / 2 && c.x <= size.width - diameter / 2)
                #expect(c.y >= diameter / 2 && c.y <= size.height - diameter / 2)
            }
        }
    }

    @Test func offsetIsClampedToMaxNudge() {
        let base = PlayerZoneResolver.center(
            for: .midLeading, offset: .zero, in: size, diameter: diameter)
        let nudged = PlayerZoneResolver.center(
            for: .midLeading, offset: CGSize(width: 999, height: 0), in: size, diameter: diameter)
        #expect(abs(nudged.x - base.x) <= PlayerZoneResolver.maxNudge + 0.001)
    }

    @Test func lowerCenterIsHorizontallyCentered() {
        let c = PlayerZoneResolver.center(
            for: .lowerCenter, offset: .zero, in: size, diameter: diameter)
        #expect(abs(c.x - size.width / 2) < 0.001)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: compile failure — `ExperimentalPlayerLayout` / `PlayerZoneResolver` undefined.

- [ ] **Step 3: Implement the models**

Create `EchoCore/Models/ExperimentalPlayerLayout.swift` (platform-neutral — no UIKit):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Anchor slots for the experimental player's floating buttons (spec §5.2).
enum PlayerSnapZone: String, Codable, CaseIterable {
    case upperLeading, upperTrailing
    case midLeading, midTrailing
    case lowerLeading, lowerCenter, lowerTrailing
}

/// One configured floating button: which action, which zone, and a bounded
/// fine-tune offset in points from the zone's anchor.
struct ExperimentalPlayerButton: Codable, Equatable, Identifiable {
    var action: WatchAction
    var zone: PlayerSnapZone
    var offset: CGSize = .zero

    var id: String { action.rawValue }
}

/// The persisted button arrangement. Decode failures always fall back to
/// `defaultLayout` — a corrupt blob must never blank the player's controls.
struct ExperimentalPlayerLayout: Codable, Equatable {
    var version: Int = 1
    var buttons: [ExperimentalPlayerButton]

    static let defaultLayout = ExperimentalPlayerLayout(buttons: [
        ExperimentalPlayerButton(action: .skipBackward, zone: .lowerLeading),
        ExperimentalPlayerButton(action: .playPause, zone: .lowerCenter),
        ExperimentalPlayerButton(action: .skipForward, zone: .lowerTrailing),
        ExperimentalPlayerButton(action: .bookmark, zone: .midLeading),
        ExperimentalPlayerButton(action: .speed, zone: .midTrailing),
    ])

    static func decode(_ data: Data) -> ExperimentalPlayerLayout {
        guard !data.isEmpty,
            let layout = try? JSONDecoder().decode(ExperimentalPlayerLayout.self, from: data),
            !layout.buttons.isEmpty
        else { return defaultLayout }
        return layout
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
```

Create `EchoCore/Models/PlayerZoneResolver.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Pure geometry for the experimental player's snap zones. Kept UIKit-free and
/// stateless so it unit-tests without any view in the loop.
enum PlayerZoneResolver {
    /// Maximum fine-tune distance (points) from a zone's anchor, per axis.
    static let maxNudge: CGFloat = 28
    /// Inset of edge anchors from the container bounds.
    static let edgeMargin: CGFloat = 24
    /// Vertical anchor fractions of container height.
    private static let upperY: CGFloat = 0.18
    private static let midY: CGFloat = 0.68
    private static let lowerY: CGFloat = 0.88

    static func anchor(for zone: PlayerSnapZone, in size: CGSize, diameter: CGFloat) -> CGPoint {
        let leadingX = edgeMargin + diameter / 2
        let trailingX = size.width - edgeMargin - diameter / 2
        let centerX = size.width / 2
        switch zone {
        case .upperLeading: return CGPoint(x: leadingX, y: size.height * upperY)
        case .upperTrailing: return CGPoint(x: trailingX, y: size.height * upperY)
        case .midLeading: return CGPoint(x: leadingX, y: size.height * midY)
        case .midTrailing: return CGPoint(x: trailingX, y: size.height * midY)
        case .lowerLeading: return CGPoint(x: leadingX, y: size.height * lowerY)
        case .lowerCenter: return CGPoint(x: centerX, y: size.height * lowerY)
        case .lowerTrailing: return CGPoint(x: trailingX, y: size.height * lowerY)
        }
    }

    static func center(
        for zone: PlayerSnapZone, offset: CGSize, in size: CGSize, diameter: CGFloat
    ) -> CGPoint {
        let anchor = anchor(for: zone, in: size, diameter: diameter)
        let clampedOffset = CGSize(
            width: min(max(offset.width, -maxNudge), maxNudge),
            height: min(max(offset.height, -maxNudge), maxNudge))
        let radius = diameter / 2
        return CGPoint(
            x: min(max(anchor.x + clampedOffset.width, radius), size.width - radius),
            y: min(max(anchor.y + clampedOffset.height, radius), size.height - radius))
    }

    /// The zone whose anchor is closest to `point` (drag-drop target, Task 3).
    static func nearestZone(to point: CGPoint, in size: CGSize, diameter: CGFloat) -> PlayerSnapZone
    {
        PlayerSnapZone.allCases.min { a, b in
            distanceSquared(point, anchor(for: a, in: size, diameter: diameter))
                < distanceSquared(point, anchor(for: b, in: size, diameter: diameter))
        } ?? .lowerCenter
    }

    private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}
```

- [ ] **Step 4: Run model tests**

Run: `make build-tests && make test-only FILTER=EchoTests/ExperimentalPlayerLayoutTests && make test-only FILTER=EchoTests/PlayerZoneResolverTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit models**

```bash
git add EchoCore/Models/ExperimentalPlayerLayout.swift EchoCore/Models/PlayerZoneResolver.swift EchoTests/ExperimentalPlayerLayoutTests.swift EchoTests/PlayerZoneResolverTests.swift
git commit -m "feat(player): snap-zone layout model and pure zone resolver"
```

- [ ] **Step 6: Persist the layout in SettingsManager (test-first)**

Add to `EchoTests/ExperimentalPlayerSettingsTests.swift`:

```swift
@Test func layoutDataDefaultsToDefaultLayoutAndPersists() throws {
    let suiteName = "test-exp-layout-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: defaults)
    let settings = SettingsManager(defaults: defaults, appGroupDefaults: defaults)

    #expect(
        ExperimentalPlayerLayout.decode(settings.experimentalPlayerLayoutData)
            == ExperimentalPlayerLayout.defaultLayout)

    var layout = ExperimentalPlayerLayout.defaultLayout
    layout.buttons[0].zone = .upperLeading
    settings.experimentalPlayerLayoutData = layout.encoded()

    let reloaded = SettingsManager(defaults: defaults, appGroupDefaults: defaults)
    #expect(ExperimentalPlayerLayout.decode(reloaded.experimentalPlayerLayoutData) == layout)
}
```

Then the same 5 touch points as Task 0 Step 3 (mirroring the `phonePage` JSON-`Data` pattern at registration ~line 826):

```swift
// Defaults:
static let experimentalPlayerLayoutData = Data()
// Keys:
static let experimentalPlayerLayoutData = "experimentalPlayerLayoutData"
// stored property:
var experimentalPlayerLayoutData: Data {
    didSet { defaults.set(experimentalPlayerLayoutData, forKey: Keys.experimentalPlayerLayoutData) }
}
// init:
experimentalPlayerLayoutData = defaults.data(forKey: Keys.experimentalPlayerLayoutData) ?? Data()
// registration dict:
Keys.experimentalPlayerLayoutData: ExperimentalPlayerLayout.defaultLayout.encoded(),
```

Run: `make build-tests && make test-only FILTER=EchoTests/ExperimentalPlayerSettingsTests`
Expected: PASS (2 tests). Commit:

```bash
git add EchoCore/Services/SettingsManager.swift EchoTests/ExperimentalPlayerSettingsTests.swift
git commit -m "feat(player): persist experimental button layout in SettingsManager"
```

- [ ] **Step 7: Create `GlassControlButton`**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// A single round Liquid Glass control. iOS 26 gets the real glass effect;
    /// earlier systems get the app's established material-plus-stroke treatment
    /// (deployment floor is iOS 18, so the fallback is mandatory).
    struct GlassControlButton<Label: View>: View {
        var diameter: CGFloat = 56
        let action: () -> Void
        @ViewBuilder let label: () -> Label

        var body: some View {
            Button(action: action) {
                label()
                    .frame(width: diameter, height: diameter)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .modifier(GlassCircleBackground())
        }
    }

    /// Shared circular glass chrome, also used for Menu-based controls that
    /// cannot be a plain Button (sleep timer, overflow).
    struct GlassCircleBackground: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: .circle)
            } else {
                content
                    .background(.ultraThinMaterial, in: .circle)
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            }
        }
    }
#endif
```

Verify `.glassEffect(_:in:)`'s exact signature against the SDK before building (Xcode 26 / axiom-swiftui docs); if the interactive variant differs, use the plain `.glassEffect(in: .circle)` form.

- [ ] **Step 8: Create `ExperimentalControlLayer`**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Full-screen overlay hosting the configured floating glass buttons for the
    /// experimental player. Locked mode only in Task 2 — buttons dispatch their
    /// actions; Task 3 adds edit mode. The layer itself never intercepts touches
    /// outside button frames (no background, hit-testing falls through).
    struct ExperimentalControlLayer: View {
        @Environment(PlayerModel.self) private var model
        @Environment(SettingsManager.self) private var settings

        // Overflow closures, injected from RootTabView (same set as PlayerMoreMenu).
        let onShowChapters: () -> Void
        let onShowBookmarks: () -> Void
        let onShowPlaybackOptions: () -> Void
        let onStats: () -> Void
        let onFidget: () -> Void
        let onSettings: () -> Void
        let onHelp: () -> Void
        let onAddDocument: (() -> Void)?
        let onExport: (() -> Void)?
        let onStudyNotesExport: (() -> Void)?

        @State private var containerSize: CGSize = .zero

        private var layout: ExperimentalPlayerLayout {
            ExperimentalPlayerLayout.decode(settings.experimentalPlayerLayoutData)
        }

        var body: some View {
            ZStack {
                ForEach(layout.buttons) { button in
                    controlButton(for: button.action)
                        .position(
                            PlayerZoneResolver.center(
                                for: button.zone, offset: button.offset,
                                in: containerSize, diameter: diameter(for: button.action)))
                }

                overflowMenu
                    .position(
                        PlayerZoneResolver.center(
                            for: .upperTrailing, offset: .zero,
                            in: containerSize, diameter: 44))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                containerSize = newSize
            }
        }

        private func diameter(for action: WatchAction) -> CGFloat {
            action == .playPause ? 68 : 52
        }

        /// Fixed, non-configurable overflow — everything not promoted to a button.
        private var overflowMenu: some View {
            PlayerMoreMenu(
                onShowChapters: onShowChapters,
                onShowBookmarks: onShowBookmarks,
                onStats: onStats,
                onFidget: onFidget,
                onSettings: onSettings,
                onHelp: onHelp,
                onAddDocument: onAddDocument,
                onExport: onExport,
                onStudyNotesExport: onStudyNotesExport
            )
            .frame(width: 44, height: 44)
            .modifier(GlassCircleBackground())
        }

        @ViewBuilder
        private func controlButton(for action: WatchAction) -> some View {
            switch action {
            case .playPause:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.togglePlayPause()
                    Haptic.play(.light)
                }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(model.resolvedThemeTint ?? .accentColor)
                }
                .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

            case .skipBackward:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipBackward30()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(
                        systemName: WatchAction.skipBackward.dynamicIconName(
                            forDuration: settings.seekBackwardDuration)
                    )
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Skip back \(settings.seekBackwardDuration) seconds"))

            case .skipForward:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipForward30()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(
                        systemName: WatchAction.skipForward.dynamicIconName(
                            forDuration: settings.seekForwardDuration)
                    )
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Skip forward \(settings.seekForwardDuration) seconds"))

            case .previousTrack:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipBackwardNavigation()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(
                    model.chapters.count >= 2 ? Text("Previous chapter") : Text("Previous track"))

            case .nextTrack:
                GlassControlButton(diameter: diameter(for: action), action: {
                    let didJump = model.skipForwardNavigation()
                    Haptic.play(didJump ? .medium : .light)
                }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(
                    model.chapters.count >= 2 ? Text("Next chapter") : Text("Next track"))

            case .previousSection:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.previousSectionOrRestart()
                    Haptic.play(.light)
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Previous section"))

            case .nextSection:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.nextSection()
                    Haptic.play(.light)
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Next section"))

            case .loopMode:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.cycleLoopMode()
                    Haptic.play(.medium)
                }) {
                    Image(systemName: "infinity")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(model.loopMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                }
                .accessibilityLabel(Text("Loop mode"))

            case .speed:
                GlassControlButton(diameter: diameter(for: action), action: {
                    onShowPlaybackOptions()
                    Haptic.play(.light)
                }) {
                    Text(
                        model.speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
                    )
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Playback options"))

            case .sleepTimer:
                Menu {
                    Button("15 Minutes", systemImage: "15.circle") {
                        model.setSleepTimer(.minutes(15))
                    }
                    Button("30 Minutes", systemImage: "30.circle") {
                        model.setSleepTimer(.minutes(30))
                    }
                    Button("45 Minutes", systemImage: "45.circle") {
                        model.setSleepTimer(.minutes(45))
                    }
                    Button("1 Hour", systemImage: "1.circle") {
                        model.setSleepTimer(.minutes(60))
                    }
                    Divider()
                    Button("End of Chapter", systemImage: "book.closed") {
                        model.setSleepTimer(.endOfChapter)
                    }
                    if model.sleepTimerMode.isActive {
                        Divider()
                        Button("Off", systemImage: "xmark.circle", role: .destructive) {
                            model.cancelSleepTimer()
                        }
                    }
                } label: {
                    Image(
                        systemName: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz"
                    )
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(
                        width: diameter(for: action), height: diameter(for: action))
                    .contentShape(.circle)
                }
                .modifier(GlassCircleBackground())
                .accessibilityLabel(Text("Sleep Timer"))

            case .bookmark:
                GlassControlButton(diameter: diameter(for: action), action: {
                    if let draft = model.bookmarkDraftAtCurrentTime() {
                        model.activeBookmarkDraft = draft
                        Haptic.play(.medium)
                    }
                }) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Add bookmark"))
                .disabled(model.tracks.isEmpty)

            case .markPassage:
                GlassControlButton(diameter: diameter(for: action), action: {
                    model.markPassageAtCurrentTime()
                    Haptic.play(.light)
                }) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel(Text("Mark passage for later"))
                .disabled(model.tracks.isEmpty)

            case .pomodoro, .empty:
                EmptyView()
            }
        }
    }
#endif
```

On iOS 26, additionally wrap the ZStack contents in `GlassEffectContainer { ... }` if available so neighboring glass shapes blend correctly — verify the API name in the SDK; if it complicates the availability split, skip it (independent circles render fine without it).

- [ ] **Step 9: Render the layer from RootTabView**

In `EchoCore/Views/RootTabView.swift`, where Task 0 suppressed the dock, render the layer instead (as a sibling ZStack member *above* the header overlay so upper-corner buttons are reachable, sharing the dock's closure wiring):

```swift
if usesExperimentalPlayerChrome && !model.isPlayingVoiceMemo {
    ExperimentalControlLayer(
        onShowChapters: { showingChapterPicker = true },
        onShowBookmarks: { model.selectedTab = .read },
        onShowPlaybackOptions: { showingPlaybackOptions = true },
        onStats: { showingStats = true },
        onFidget: { showingFidget = true },
        onSettings: { showingSettings = true },
        onHelp: { model.showingHelp = true },
        onAddDocument: (model.folderURL != nil
            && !model.narrationPlaybackState.isRunning)
            ? { model.showingDocumentImporter = true } : nil,
        onExport: (model.folderURL != nil
            && !model.narrationPlaybackState.isRunning)
            ? { showingExport = true } : nil,
        onStudyNotesExport: (model.folderURL != nil
            && !model.narrationPlaybackState.isRunning)
            ? { showingStudyNotesExport = true } : nil
    )
}
```

- [ ] **Step 10: Build, verify, run suite**

Run: `make build-tests && make test`
Expected: BUILD SUCCEEDED, all tests PASS.

Simulator: default arrangement (skip-back / play / skip-forward arc, bookmark left rail, speed right rail, glass `⋯` upper-trailing); every button dispatches; scrubber and metadata beneath remain fully interactive; Reader dock unaffected; with the toggle off nothing changed.

- [ ] **Step 11: Commit**

```bash
git add EchoCore/Views/Player/GlassControlButton.swift EchoCore/Views/Player/ExperimentalControlLayer.swift EchoCore/Views/RootTabView.swift
git commit -m "feat(player): floating glass control layer with snap-zone default layout"
```

---

### Task 3: Lock / edit mode

**Files:**
- Modify: `EchoCore/Models/ExperimentalPlayerLayout.swift` (mutation helpers)
- Modify: `EchoCore/Views/Player/ExperimentalControlLayer.swift` (edit state, drag, add/remove, Done chip)
- Modify: `EchoCore/Views/SettingsNowPlayingView.swift` (Reset Layout)
- Test: `EchoTests/ExperimentalPlayerLayoutTests.swift` (extend)

**Interfaces:**
- Consumes: `PlayerZoneResolver.nearestZone(to:in:diameter:)`, `PlayerZoneResolver.center/anchor`, `settings.experimentalPlayerLayoutData`.
- Produces: `ExperimentalPlayerLayout.adding(_ action: WatchAction) -> Self`, `.removing(_ action: WatchAction) -> Self`, `.moving(_ action: WatchAction, to zone: PlayerSnapZone, offset: CGSize) -> Self`, `var availableActions: [WatchAction]`.

- [ ] **Step 1: Write failing mutation tests**

Append to `EchoTests/ExperimentalPlayerLayoutTests.swift`:

```swift
@Test func addingAppendsToFirstFreeZoneAndIgnoresDuplicates() {
    let layout = ExperimentalPlayerLayout.defaultLayout  // occupies lowerL/C/T, midL, midT
    let added = layout.adding(.sleepTimer)
    #expect(added.buttons.count == 6)
    #expect(added.buttons.last?.action == .sleepTimer)
    #expect(added.buttons.last?.zone == .upperLeading)  // first free zone in allCases order
    #expect(added.adding(.sleepTimer) == added)  // no duplicates
}

@Test func removingDeletesOnlyThatAction() {
    let removed = ExperimentalPlayerLayout.defaultLayout.removing(.bookmark)
    #expect(removed.buttons.count == 4)
    #expect(!removed.buttons.contains { $0.action == .bookmark })
}

@Test func movingUpdatesZoneAndOffset() {
    let moved = ExperimentalPlayerLayout.defaultLayout.moving(
        .playPause, to: .upperLeading, offset: CGSize(width: 10, height: -5))
    let play = moved.buttons.first { $0.action == .playPause }
    #expect(play?.zone == .upperLeading)
    #expect(play?.offset == CGSize(width: 10, height: -5))
}

@Test func availableActionsExcludesConfiguredAndNonButtons() {
    let available = ExperimentalPlayerLayout.defaultLayout.availableActions
    #expect(!available.contains(.playPause))
    #expect(!available.contains(.empty))
    #expect(!available.contains(.pomodoro))
    #expect(available.contains(.sleepTimer))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: compile failure — no members `adding/removing/moving/availableActions`.

- [ ] **Step 3: Implement mutations**

Append to `ExperimentalPlayerLayout` in `EchoCore/Models/ExperimentalPlayerLayout.swift`:

```swift
/// Actions eligible for a new button: not already configured, and not the
/// placeholder cases (`empty`) or phone-non-actions (`pomodoro` renders as a
/// blank slot in the classic transport bar — see TransportControlsView).
var availableActions: [WatchAction] {
    let used = Set(buttons.map(\.action))
    return WatchAction.allCases.filter {
        !used.contains($0) && $0 != .empty && $0 != .pomodoro
    }
}

func adding(_ action: WatchAction) -> ExperimentalPlayerLayout {
    guard !buttons.contains(where: { $0.action == action }) else { return self }
    let occupied = Set(buttons.map(\.zone))
    let zone = PlayerSnapZone.allCases.first { !occupied.contains($0) } ?? .lowerCenter
    var copy = self
    copy.buttons.append(ExperimentalPlayerButton(action: action, zone: zone))
    return copy
}

func removing(_ action: WatchAction) -> ExperimentalPlayerLayout {
    var copy = self
    copy.buttons.removeAll { $0.action == action }
    return copy
}

func moving(
    _ action: WatchAction, to zone: PlayerSnapZone, offset: CGSize
) -> ExperimentalPlayerLayout {
    var copy = self
    guard let index = copy.buttons.firstIndex(where: { $0.action == action }) else { return self }
    copy.buttons[index].zone = zone
    copy.buttons[index].offset = offset
    return copy
}
```

- [ ] **Step 4: Run tests**

Run: `make build-tests && make test-only FILTER=EchoTests/ExperimentalPlayerLayoutTests`
Expected: PASS (8 tests). Commit:

```bash
git add EchoCore/Models/ExperimentalPlayerLayout.swift EchoTests/ExperimentalPlayerLayoutTests.swift
git commit -m "feat(player): layout mutations for experimental button edit mode"
```

- [ ] **Step 5: Add edit mode to `ExperimentalControlLayer`**

State + gesture plumbing (in `ExperimentalControlLayer`):

```swift
@State private var isEditing = false
@State private var draggedAction: WatchAction?
@State private var dragLocation: CGPoint = .zero
@State private var showingAddSheet = false

private func persist(_ layout: ExperimentalPlayerLayout) {
    settings.experimentalPlayerLayoutData = layout.encoded()
}
```

Per-button edit affordances — wrap each configured button (in the `ForEach`) so that in edit mode a drag gesture moves it, a long-press enters editing, and a badge removes it:

```swift
controlButton(for: button.action)
    .overlay(alignment: .topTrailing) {
        if isEditing {
            Button("Remove \(button.action.displayName)", systemImage: "minus.circle.fill") {
                persist(layout.removing(button.action))
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.white, .red)
            .offset(x: 6, y: -6)
        }
    }
    .rotationEffect(
        isEditing ? .degrees(draggedAction == button.action ? 0 : 1.5) : .zero
    )
    .animation(
        isEditing
            ? .easeInOut(duration: 0.15).repeatForever(autoreverses: true) : .default,
        value: isEditing
    )
    .simultaneousGesture(
        LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            guard !isEditing else { return }
            isEditing = true
            Haptic.play(.medium)
        }
    )
    .gesture(
        isEditing
            ? DragGesture()
                .onChanged { value in
                    draggedAction = button.action
                    dragLocation = value.location
                }
                .onEnded { value in
                    let zone = PlayerZoneResolver.nearestZone(
                        to: value.location, in: containerSize,
                        diameter: diameter(for: button.action))
                    let anchor = PlayerZoneResolver.anchor(
                        for: zone, in: containerSize,
                        diameter: diameter(for: button.action))
                    let offset = CGSize(
                        width: value.location.x - anchor.x,
                        height: value.location.y - anchor.y)
                    persist(layout.moving(button.action, to: zone, offset: offset))
                    draggedAction = nil
                    Haptic.play(.light)
                }
            : nil
    )
    .position(
        draggedAction == button.action
            ? dragLocation
            : PlayerZoneResolver.center(
                for: button.zone, offset: button.offset,
                in: containerSize, diameter: diameter(for: button.action)))
```

(This replaces the plain `.position(...)` from Task 2. The resolver clamps the persisted offset to `maxNudge` on next render, so a wild drop still snaps into the zone's nudge envelope.)

Edit-mode chrome — add to the layer's ZStack:

```swift
if isEditing {
    // Dashed anchors for every zone.
    ForEach(PlayerSnapZone.allCases, id: \.rawValue) { zone in
        Circle()
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(model.resolvedThemeTint ?? .accentColor)
            .frame(width: 56, height: 56)
            .position(
                PlayerZoneResolver.anchor(for: zone, in: containerSize, diameter: 56))
            .allowsHitTesting(false)
    }

    // Add + Done chips, top center.
    HStack(spacing: 12) {
        Button("Add Button", systemImage: "plus") { showingAddSheet = true }
        Button("Done", systemImage: "lock.fill") {
            isEditing = false
            Haptic.play(.medium)
        }
    }
    .buttonStyle(.bordered)
    .padding(8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
}
```

Add-button sheet (attach to the layer):

```swift
.sheet(isPresented: $showingAddSheet) {
    NavigationStack {
        List(layout.availableActions) { action in
            Button {
                persist(layout.adding(action))
                showingAddSheet = false
            } label: {
                Label(action.displayName, systemImage: action.iconName)
            }
        }
        .navigationTitle("Add Button")
    }
    .presentationDetents([.medium])
}
```

Overflow entry point — add as the first item of the experimental `overflowMenu`'s `Menu` (wrap `PlayerMoreMenu`'s content or prepend via a new optional closure on `PlayerMoreMenu`; simplest: give `PlayerMoreMenu` an optional `onEditLayout: (() -> Void)? = nil` that inserts `Button("Edit Buttons…", systemImage: "slider.horizontal.3", action:)` at the top when non-nil, and pass `{ isEditing = true }` from the layer only):

```swift
// PlayerMoreMenu.swift — new optional property + menu item (top of Menu):
var onEditLayout: (() -> Void)? = nil
...
if let onEditLayout {
    Button("Edit Buttons…", systemImage: "slider.horizontal.3", action: onEditLayout)
    Divider()
}
```

- [ ] **Step 6: Reset Layout in settings**

In `SettingsNowPlayingView.swift`, extend the Experimental section:

```swift
Button("Reset Button Layout", role: .destructive) {
    settings.experimentalPlayerLayoutData =
        ExperimentalPlayerLayout.defaultLayout.encoded()
}
.disabled(!settings.experimentalNowPlayingLayout)
```

- [ ] **Step 7: Build, verify, full suite**

Run: `make build-tests && make test`
Expected: PASS.

Simulator: long-press a button → jiggle + dashed zones + chips; drag play/pause to an upper zone → snaps with the nudge you left it at; relaunch app → arrangement persists and opens locked; remove/add via badge/sheet; `⋯ → Edit Buttons…` also enters edit; Reset restores defaults; VoiceOver reads the remove badges.

- [ ] **Step 8: Commit**

```bash
git add EchoCore/Views/Player/ExperimentalControlLayer.swift EchoCore/Views/PlayerMoreMenu.swift EchoCore/Views/SettingsNowPlayingView.swift
git commit -m "feat(player): lock/edit mode with drag-to-zone, nudge, add/remove, reset"
```

---

### Task 4: `ZoomableArtwork` — tap to fullscreen (everywhere art appears)

**Files:**
- Create: `EchoCore/Views/Components/FullscreenImageViewer.swift`
- Create: `EchoCore/Views/Components/ZoomableArtwork.swift`
- Modify: `EchoCore/Views/NowPlayingTab.swift` (`artworkView`, ~line 266)
- Modify: `EchoCore/Views/Player/ExperimentalNowPlayingView.swift` (cover tap region)
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (presentation state for reader path)
- Modify: `EchoCore/Views/RootTabView.swift` (present the viewer)
- Modify: `EchoCore/Views/ReaderTab.swift` + `EchoCore/Views/ReaderTab+Alignment.swift` (context-menu + accessibility "View Full Screen")

**Interfaces:**
- Consumes: `PlayerModel.currentDisplayArtwork`, `.thumbnailImage`; ReaderTab's image resolution logic (`saveImageToCameraRoll`, `ReaderTab.swift:1061–1074`); context menu builder (`ReaderTab+Alignment.swift:470–478`), accessibility actions (`:297–303`).
- Produces:
  - `struct FullscreenImageItem: Identifiable { let id = UUID(); let image: UIImage }` (on `PlayerModel`: `var fullscreenImage: FullscreenImageItem?`).
  - `FullscreenImageViewer(image: UIImage)`.
  - `ZoomableArtwork(image: UIImage, accessibilityLabel: Text, onLongPress: (() -> Void)? = nil) { label }` — `onLongPress` is wired by Task 5.
  - `ReaderTab.resolvedImage(for block: EPubBlockRecord) -> UIImage?` (extracted; Task 5 reuses it).

- [ ] **Step 1: Create the viewer**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Edge-to-edge image viewer: pinch to zoom (1×–4×), drag to pan when
    /// zoomed, double-tap to toggle zoom, swipe down or tap Close to dismiss.
    struct FullscreenImageViewer: View {
        let image: UIImage
        @Environment(\.dismiss) private var dismiss

        @State private var zoom: CGFloat = 1
        @State private var steadyZoom: CGFloat = 1
        @State private var pan: CGSize = .zero
        @State private var steadyPan: CGSize = .zero

        var body: some View {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .gesture(zoomAndPanGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            steadyZoom = steadyZoom > 1 ? 1 : 2.5
                            zoom = steadyZoom
                            steadyPan = .zero
                            pan = .zero
                        }
                    }
                    .accessibilityLabel(Text("Full screen image"))
                    .accessibilityAddTraits(.isImage)

                Button("Close", systemImage: "xmark.circle.fill") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding()
            }
            .gesture(
                // Swipe down while un-zoomed dismisses.
                DragGesture().onEnded { value in
                    if steadyZoom <= 1 && value.translation.height > 80 { dismiss() }
                }
            )
            .statusBarHidden()
        }

        private var zoomAndPanGesture: some Gesture {
            SimultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        zoom = min(max(steadyZoom * value.magnification, 1), 4)
                    }
                    .onEnded { _ in
                        steadyZoom = zoom
                        if zoom <= 1 {
                            withAnimation(.snappy) {
                                pan = .zero
                                steadyPan = .zero
                            }
                        }
                    },
                DragGesture()
                    .onChanged { value in
                        guard steadyZoom > 1 else { return }
                        pan = CGSize(
                            width: steadyPan.width + value.translation.width,
                            height: steadyPan.height + value.translation.height)
                    }
                    .onEnded { _ in steadyPan = pan }
            )
        }
    }
#endif
```

(`onTapGesture(count: 2)` is the sanctioned exception — tap *count* matters. AGENTS bans only the plain 1-tap use.)

- [ ] **Step 2: Create the wrapper**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Wraps any artwork so tapping opens the fullscreen viewer and (when a
    /// handler is provided — Task 5) long-pressing triggers save-to-Photos.
    /// One component so cover art and reader images behave identically.
    struct ZoomableArtwork<Label: View>: View {
        let image: UIImage
        let accessibilityLabel: Text
        var onLongPress: (() -> Void)? = nil
        @ViewBuilder let label: () -> Label

        @State private var showingViewer = false

        var body: some View {
            Button {
                showingViewer = true
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Double tap to view full screen")
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    onLongPress?()
                }
            )
            .fullScreenCover(isPresented: $showingViewer) {
                FullscreenImageViewer(image: image)
            }
        }
    }
#endif
```

- [ ] **Step 3: Wrap the classic player's cover**

In `NowPlayingTab.artworkView` (~line 266), wrap the image branch:

```swift
if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
    ZoomableArtwork(
        image: image,
        accessibilityLabel: Text("Cover of \(model.currentTitle)")
    ) {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
} else { /* placeholder unchanged */ }
```

- [ ] **Step 4: Make the experimental cover tappable**

In `ExperimentalNowPlayingView`, overlay a tap target over the cover region (the background itself must stay non-interactive so the layer beneath scrolls/hits normally elsewhere). Add as the first element **inside** the VStack, replacing the top `Spacer`:

```swift
if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
    ZoomableArtwork(
        image: image,
        accessibilityLabel: Text("Cover of \(model.currentTitle)")
    ) {
        Color.clear
            .contentShape(.rect)
            .containerRelativeFrame(.vertical) { height, _ in
                height * FullBleedCoverBackground.fadeStartFraction
                    * FullBleedCoverBackground.coverHeightFraction
            }
    }
} else {
    Spacer(minLength: 0)
}
```

- [ ] **Step 5: Reader images — resolution helper + menu actions**

In `EchoCore/Views/ReaderTab.swift`, extract the path-fallback logic out of `saveImageToCameraRoll` (lines 1061–1074) into:

```swift
/// Resolves a block's image from its recorded path, falling back to the
/// EPUBAssets store (same fallback saveImageToCameraRoll used).
func resolvedImage(for block: EPubBlockRecord) -> UIImage? {
    guard let imagePath = block.imagePath else { return nil }
    var url = URL(fileURLWithPath: imagePath)
    if !FileManager.default.fileExists(atPath: url.path) {
        let filename = url.lastPathComponent
        let dirName = url.deletingLastPathComponent().lastPathComponent
        let appSupport = FileLocations.applicationSupportDirectory
        url = appSupport.appendingPathComponent("EPUBAssets").appendingPathComponent(dirName)
            .appendingPathComponent(filename)
    }
    return UIImage(contentsOfFile: url.path)
}

func saveImageToCameraRoll(block: EPubBlockRecord) {
    guard let image = resolvedImage(for: block) else { return }
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)  // replaced in Task 5
}
```

On `PlayerModel` (near `showingMissingBookWarning`, ~line 125):

```swift
/// Image presented edge-to-edge by RootTabView's fullScreenCover.
var fullscreenImage: FullscreenImageItem? = nil
```

With, in `EchoCore/Views/Components/FullscreenImageViewer.swift`:

```swift
struct FullscreenImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}
```

In `RootTabView` (with the other presentation modifiers, after ~line 355):

```swift
.fullScreenCover(
    item: Binding(
        get: { model.fullscreenImage },
        set: { model.fullscreenImage = $0 })
) { item in
    FullscreenImageViewer(image: item.image)
}
```

In `ReaderTab+Alignment.swift` context-menu builder, alongside the `kind == .image` save action (~line 470):

```swift
let viewImageAction = UIAction(
    title: String(localized: "View Full Screen"),
    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
) { [weak model] _ in
    guard let model, let image = resolvedImage(for: block) else { return }
    model.fullscreenImage = FullscreenImageItem(image: image)
}
actions.append(viewImageAction)
```

And the matching accessibility custom action (~line 297):

```swift
actions.append(
    UIAccessibilityCustomAction(name: String(localized: "View Full Screen")) {
        [weak model] _ in
        guard let model, let image = resolvedImage(for: block) else { return false }
        model.fullscreenImage = FullscreenImageItem(image: image)
        return true
    })
```

- [ ] **Step 6: Build, verify, full suite**

Run: `make build-tests && make test`
Expected: PASS.

Simulator: classic player cover tap → viewer (pinch/pan/double-tap/swipe-down all work); experimental cover region tap → viewer; reader image context menu shows "View Full Screen" → viewer; dismissal restores the player untouched.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Views/Components/FullscreenImageViewer.swift EchoCore/Views/Components/ZoomableArtwork.swift EchoCore/Views/NowPlayingTab.swift EchoCore/Views/Player/ExperimentalNowPlayingView.swift EchoCore/ViewModels/PlayerModel.swift EchoCore/Views/RootTabView.swift EchoCore/Views/ReaderTab.swift EchoCore/Views/ReaderTab+Alignment.swift
git commit -m "feat(images): tap-to-fullscreen zoomable viewer for covers and reader images"
```

---

### Task 5: Long-press save-to-Photos with a real permission flow

**Files:**
- Create: `EchoCore/Services/PhotoLibrarySaver.swift`
- Modify: `EchoCore/Views/Components/ZoomableArtwork.swift` (wire `onLongPress` internally)
- Modify: `EchoCore/Views/NowPlayingTab.swift`, `EchoCore/Views/Player/ExperimentalNowPlayingView.swift` (pass saver)
- Modify: `EchoCore/Views/ReaderTab.swift` (replace `UIImageWriteToSavedPhotosAlbum`)
- Modify: `EchoCore/Info.plist` (broaden the existing usage string, line 33)
- Test: `EchoTests/PhotoLibrarySaverTests.swift`

**Interfaces:**
- Consumes: `ZoomableArtwork.onLongPress`, `ReaderTab.resolvedImage(for:)`, existing `NSPhotoLibraryAddUsageDescription` (already present — `EchoCore/Info.plist:33`).
- Produces: `PhotoLibrarySaver` (`@MainActor @Observable final class`) with `enum SaveOutcome: Equatable { case saved, denied, failed }`, `func save(_ image: UIImage) async -> SaveOutcome`, closure seams `requestAuthorization: () async -> PHAuthorizationStatus` and `performSave: (UIImage) async throws -> Void`.

- [ ] **Step 1: Write failing saver tests**

Create `EchoTests/PhotoLibrarySaverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Photos
import Testing
import UIKit

@testable import Echo

@MainActor
struct PhotoLibrarySaverTests {
    private let image = UIImage()

    @Test func authorizedRequestSaves() async {
        var didSave = false
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .authorized },
            performSave: { _ in didSave = true })
        #expect(await saver.save(image) == .saved)
        #expect(didSave)
    }

    @Test func limitedAccessStillSaves() async {
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .limited },
            performSave: { _ in })
        #expect(await saver.save(image) == .saved)
    }

    @Test func deniedNeverAttemptsSave() async {
        var didSave = false
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .denied },
            performSave: { _ in didSave = true })
        #expect(await saver.save(image) == .denied)
        #expect(!didSave)
    }

    @Test func saveErrorReportsFailure() async {
        struct Boom: Error {}
        let saver = PhotoLibrarySaver(
            requestAuthorization: { .authorized },
            performSave: { _ in throw Boom() })
        #expect(await saver.save(image) == .failed)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: compile failure — `PhotoLibrarySaver` undefined.

- [ ] **Step 3: Implement the saver**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import Photos
    import UIKit

    /// Add-only Photos saving with an explicit permission flow. Replaces the
    /// fire-and-forget `UIImageWriteToSavedPhotosAlbum` path: authorization is
    /// requested up front (.addOnly — the narrowest scope), denial is surfaced
    /// to the caller instead of swallowed, and failures are reported.
    ///
    /// DI follows the DatabaseService convention: concrete type + closure
    /// injection, no protocol (the test double injects the closures).
    @MainActor
    final class PhotoLibrarySaver {
        enum SaveOutcome: Equatable {
            case saved, denied, failed
        }

        private let requestAuthorization: () async -> PHAuthorizationStatus
        private let performSave: (UIImage) async throws -> Void

        init(
            requestAuthorization: @escaping () async -> PHAuthorizationStatus = {
                await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            },
            performSave: @escaping (UIImage) async throws -> Void = { image in
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAsset(from: image)
                }
            }
        ) {
            self.requestAuthorization = requestAuthorization
            self.performSave = performSave
        }

        func save(_ image: UIImage) async -> SaveOutcome {
            switch await requestAuthorization() {
            case .authorized, .limited:
                do {
                    try await performSave(image)
                    return .saved
                } catch {
                    return .failed
                }
            default:
                return .denied
            }
        }
    }
#endif
```

- [ ] **Step 4: Run saver tests**

Run: `make build-tests && make test-only FILTER=EchoTests/PhotoLibrarySaverTests`
Expected: PASS (4 tests). Commit:

```bash
git add EchoCore/Services/PhotoLibrarySaver.swift EchoTests/PhotoLibrarySaverTests.swift
git commit -m "feat(images): add-only PhotoLibrarySaver with injected permission seam"
```

- [ ] **Step 5: Wire long-press into `ZoomableArtwork`**

Replace the external `onLongPress` closure with built-in saving + feedback (update the Task 4 call sites to drop the parameter):

```swift
struct ZoomableArtwork<Label: View>: View {
    let image: UIImage
    let accessibilityLabel: Text
    @ViewBuilder let label: () -> Label

    @State private var showingViewer = false
    @State private var saveOutcome: PhotoLibrarySaver.SaveOutcome?
    private let saver = PhotoLibrarySaver()

    var body: some View {
        Button {
            showingViewer = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to view full screen")
        .accessibilityAction(named: "Save to Photos") { saveToPhotos() }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                saveToPhotos()
            }
        )
        .fullScreenCover(isPresented: $showingViewer) {
            FullscreenImageViewer(image: image)
        }
        .alert(
            "Photos Access Needed",
            isPresented: Binding(
                get: { saveOutcome == .denied },
                set: { if !$0 { saveOutcome = nil } })
        ) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Echo to add images to your photo library in Settings.")
        }
        .sensoryFeedback(.success, trigger: saveOutcome == .saved)
    }

    private func saveToPhotos() {
        Task {
            saveOutcome = await saver.save(image)
            if saveOutcome == .saved || saveOutcome == .failed {
                try? await Task.sleep(for: .seconds(2))
                saveOutcome = nil
            }
        }
    }
}
```

Also add a Save button to `FullscreenImageViewer` (next to Close), calling the same saver — so a zoomed-in user can save without dismissing:

```swift
Button("Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos() }
    .labelStyle(.iconOnly)
    .font(.title)
    .foregroundStyle(.white.opacity(0.85))
    .padding(.trailing, 4)
```

(with the same `saver` + `saveOutcome` + alert pattern as `ZoomableArtwork`).

- [ ] **Step 6: Replace the reader's save path**

In `ReaderTab.swift`, `saveImageToCameraRoll(block:)` becomes:

```swift
func saveImageToCameraRoll(block: EPubBlockRecord) {
    guard let image = resolvedImage(for: block) else { return }
    Task { _ = await PhotoLibrarySaver().save(image) }
}
```

(The context-menu path can't easily show the denial alert from a UIKit coordinator; the permission prompt itself is now correct, and denial is silently safe. The SwiftUI surfaces — covers + viewer — carry the full alert UX.)

- [ ] **Step 7: Broaden the usage string**

`EchoCore/Info.plist` line 34 — replace the string value:

```xml
<string>Echo saves book covers and images you choose to your photo library.</string>
```

- [ ] **Step 8: Build, verify, full suite**

Run: `make build-tests && make test`
Expected: PASS.

Simulator: first long-press on a cover → system add-only permission prompt → allow → haptic success, image in Photos; deny (reset via Settings → Privacy) → alert with "Open Settings"; viewer Save button works; reader "Save Image" still saves.

- [ ] **Step 9: Commit**

```bash
git add EchoCore/Views/Components/ZoomableArtwork.swift EchoCore/Views/Components/FullscreenImageViewer.swift EchoCore/Views/ReaderTab.swift EchoCore/Info.plist
git commit -m "feat(images): long-press save-to-Photos with add-only permission flow"
```

---

## After all tasks

- Run the `verify` skill flow: exercise the toggle, drag/lock, fullscreen, and save end-to-end in the simulator.
- Docs (via `doc-sync` skill): `ARCHITECTURE.md` — experimental player components + the two new settings keys; `CHANGELOG.md` entry. Remind Dan explicitly.
- Rebase onto latest `origin/nightly`, push, open PR with `gh pr create --base nightly`, then follow `gh pr checks` until green.
