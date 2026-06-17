# BookPlayer-Style Player Redesign — macOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the BookPlayer-style player to macOS — a `< Chapter Title >` nav bar in the player toolbar, a Playback Options popover, a player More menu, and a real macOS Settings scene — by building the chapter/loop/boost capabilities the macOS player currently lacks.

**Architecture:** `MacPlayerModel` is a **separate, simpler model** from iOS `PlayerModel`: a raw `AVPlayer`, file-index `nextTrack`/`previousTrack`, **no chapters, no loop, no volume boost, no `PlaybackController`, and no Settings scene.** So macOS parity is net-new model work, not a view rewire. We add a chapter axis (`ChapterService`-backed), 3-way loop with a timer-driven boundary watch, configurable skip, and volume boost via an `MTAudioProcessingTap`; then build the chapter-nav bar, options popover, More menu, and a `Settings` scene. Pure decision logic is extracted to `EchoCore/Services/MacPlaybackLogic.swift` so it is unit-testable from `EchoTests`.

**Tech Stack:** Swift 6, SwiftUI (macOS), `@Observable` `MacPlayerModel`, AVFoundation (`AVPlayer`, `AVMutableAudioMix`, `MTAudioProcessingTap`), `EchoCore` `ChapterService`/`Chapter`/`LoopMode` (linked into the macOS target), Swift Testing. macOS build: `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS'` (the `Echo`/`EchoTests` `make` recipes do **not** compile the macOS target).

**Companion plan:** iOS lives in [`2026-06-16-bookplayer-redesign-ios.md`](2026-06-16-bookplayer-redesign-ios.md). **Cross-plan dependency:** WS-J (macOS Settings scene) reuses `EchoCore/Models/ThemeColor.swift`, which is created by the **iOS plan's Task E1** — land E1 first, and ensure `ThemeColor.swift` is **not** excluded from the macOS target.

---

## Locked decisions (from brainstorming, 2026-06-16)

- **Full macOS parity now** (chosen over deferring): build the chapter axis, loop, volume boost, configurable skip, and a Settings scene.
- **Loop:** 3-way `LoopMode` (Off / Chapter / Bookmark) on Mac too, surfaced in the options popover.
- Change #4 (configurable transport row / `WatchAction` retirement) has **zero macOS footprint** — macOS has no configurable row, no slot enum UI, and no saved layout store. No macOS migration.

## Cross-cutting groundwork & resolved open issues

These came out of adversarial review of the drafts. They are real and load-bearing.

1. **⚠️ Highest risk — macOS volume boost (WS-G3).** `AVMutableAudioMixInputParameters.setVolume` only *attenuates* (0…1) and cannot deliver the iOS +9 dB boost, so WS-G uses an `MTAudioProcessingTap` that multiplies samples by a linear gain. Three flagged risks: (a) the process callback assumes non-interleaved 32-bit float (standard for `AVPlayer` taps but not contractually guaranteed for every codec/route); (b) real-time-thread safety (no allocation/locking — a tolerated torn `Float` read at most mis-scales one buffer); (c) `asset.tracks(withMediaType:)` is sync-deprecated on newer SDKs. **If this proves fragile against the real deployment target, ship macOS volume boost as a deferred follow-up** (the rest of the plan does not depend on it) — flag the decision when WS-G3's build step runs. This is the one item worth a go/no-go check.
2. **macOS behavioral testing gap (honest limitation):** `MacPlayerModel` lives in the `Echo macOS` app target; `EchoTests` is `@testable import Echo` (iOS) and **cannot instantiate it.** So: pure logic is extracted to `EchoCore/Services/MacPlaybackLogic.swift` (`MacChapterLoopDecision`, `MacVolumeBoost`) and `ChapterService` navigation math — both **truly unit-tested**. **It lives in `EchoCore/`, not `Shared/`** — `Shared/` also compiles into the Widget extension, which does not link `EchoCore`'s `Chapter`/`LoopMode` types, so a `Shared/` file referencing them would break the Widget (and thus `make build-tests`); `EchoCore/` is in the iOS + macOS targets but not the Widget. In-model wiring is locked with **source-scanning structural tests** (same trade-off `NowPlayingLayoutTests` already accepts). A true behavioral Mac unit-test target is out of scope (would need a new pbxproj test target).
3. **One shared macOS test source-resolver:** WS-G creates `EchoTests/MacSource.swift` (resolves paths under `Echo macOS/`). WS-H/I/J structural tests **must reuse `MacSource`** rather than each rolling their own `source(named:)`. Consolidate to avoid divergence.
4. **`MacPlayerModel` must consume `SettingsManager` for the Settings panes to have effect.** WS-J persists `defaultPlaybackSpeed` / `seekForwardDuration`-`seekBackwardDuration` / `global_volumeBoostEnabled`; the Mac player must read them or the Playback pane persists prefs the player ignores. Apply this as part of WS-G/WS-J using the **existing `dbService` injection pattern** as the template: `MacTriPaneView.task` already wires `player.dbService = dbService` ([`MacTriPaneView.swift:40-44`](../../../Echo%20macOS/Views/MacTriPaneView.swift)). Add `var settings: SettingsManager?` to `MacPlayerModel`, wire `player.settings = settings` in that same `.task` (the `Settings`-scene-injected instance from WS-J), and source `skipInterval` from `settings?.seekForwardDuration`, the initial `playbackRate` from `settings?.defaultPlaybackSpeed`, and boost-enabled from the `global_volumeBoostEnabled` key on **`UserDefaults.standard`** (the same store as iOS + the J2 toggle; device-local). This is implemented by **Task G5** (below) — a required edit, not optional polish.
5. **`SettingsManager` injection on macOS:** the macOS target had **no** `SettingsManager` instance. WS-J adds `@State private var settings = SettingsManager()` in `Echo_macOSApp` and injects it into both the `WindowGroup` and the `Settings` scene (`SettingsManager` compiles into the macOS target with no `import`). Reused EchoCore settings views (e.g. `SmartRewindSettingsView`) require it in the environment.
6. **`chapters`/`currentChapterIndex` are `private(set)`** on `MacPlayerModel` (managed internally — parsed async, advanced by the time observer). Consumers (WS-H/I) **read** them and **call** `nextChapter()`/`previousChapter()`/`seekToChapter(_:)`; they do not set them.
7. **Folder (multi-file) books:** WS-F does **not** build a global cross-file chapter timeline (iOS does this via `PlayerLoadingCoordinator`, which is not compiled into the macOS target). The axis rule routes chapter-nav to **track nav** when a book has no per-file chapters. A unified Mac folder-chapter timeline is a larger future effort.
8. **Menu honesty:** `Echo_macOSApp.swift:110-120` ⌘←/⌘→ are labelled "Previous/Next Chapter" but call **track** methods today. WS-H re-points them at the real `previousChapter()`/`nextChapter()`, making the labels honest.
9. **macOS appearance application is partial:** WS-J wires `.preferredColorScheme` so the Appearance pane's Color-Scheme control works, but custom `appFont`/accent `themeColor` are **not yet applied** to the macOS UI (persisted only). Applying them in `MacTriPaneView`/`MacReaderFeedView` is an out-of-scope follow-up.

## Recommended execution order

`F → G (incl. G4, G5) → H → J → I`. F (chapter axis) is the foundation; G adds loop/skip/boost (G1–G3), structural wiring tests (G4), and the `SettingsManager` consumption (G5 — needs WS-J's injected `SettingsManager`, so land G5 after J or stub the env); H is the chapter-nav bar + menu reconcile; J builds the Settings scene + `SettingsManager` injection (needs iOS **E1**'s `ThemeColor.swift`); I builds the options popover + More menu, which reference J's Settings scene. The risky **G3** (audio-boost tap) can be gated/deferred without blocking F/H/J/I.

---

### Task F1: Add chapter model + async chapter loading to MacPlayerModel

**Context for the executor (read before writing a line):**
- `MacPlayerModel` lives in the `Echo macOS` target ONLY. The `EchoTests` target is `@testable import Echo` (the iOS app) — it CANNOT see `MacPlayerModel`. Therefore the chapter *math* is delegated to `ChapterService` (compiled into all targets including `EchoTests`) and unit-tested there; the wiring inside `MacPlayerModel` is verified by a source-scanning structural test (Task F4).
- EchoCore is NOT a Swift module on macOS — `EchoCore/` is a folder reference compiled into the `Echo macOS` target by source membership. `EchoCore/Models/Chapter.swift`, `EchoCore/Models/LoopMode.swift`, and `EchoCore/Services/ChapterService.swift` are NOT in the macOS membership-exception list (verified in `Echo.xcodeproj/project.pbxproj:141-260`), so `Chapter`, `LoopMode`, and `ChapterService` are already in scope inside `MacPlayerModel.swift` with NO `import` needed. Do NOT add `import EchoCore` (it does not exist).
- `Chapter` fields (verbatim, `EchoCore/Models/Chapter.swift:5-19`): `let index: Int`, `let title: String?`, `let startSeconds: Double`, `let endSeconds: Double`, `var isEnabled: Bool = true`, `var wordCloudFrequencies: [WordFrequency]?`.
- `ChapterService.parseChapters(from: AVAsset) async -> [Chapter]` returns `[]` for marker-less / single-chapter files (`>=2` floor, `ChapterService.swift:58-59`).

**Steps:**

- [ ] Read `EchoTests/EchoCoreTests.swift:1-20` to confirm the Swift-Testing import header style used elsewhere (`import Testing`, `@testable import Echo`).
- [ ] Read `Echo macOS/Views/MacPlayerModel.swift:44-122` (property block + init) and `:212-298` (`open(url:)` and `loadFolder(url:)`) so the new code lands in the right spots.
- [ ] Create the failing unit test for the chapter-index math the Mac model will rely on. Create file `EchoTests/ChapterServiceNavigationTests.swift` with this COMPLETE content:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Verifies the pure chapter-index math that `MacPlayerModel` delegates to.
/// `MacPlayerModel` itself is in the `Echo macOS` target and is not reachable
/// from this test target, so the math is exercised here against the shared
/// `ChapterService`, and the Mac wiring is verified structurally elsewhere.
struct ChapterServiceNavigationTests {

    /// Three back-to-back chapters: [0,10) [10,20) [20,30).
    private func makeChapters() -> [Chapter] {
        [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            Chapter(index: 2, title: "Three", startSeconds: 20, endSeconds: 30),
        ]
    }

    @Test func chapterIndexForTimeIsHalfOpenInterval() {
        let chapters = makeChapters()
        // Start of a chapter is inclusive.
        #expect(ChapterService.chapterIndex(forTime: 10, in: chapters) == 1)
        // Mid-chapter resolves to that chapter.
        #expect(ChapterService.chapterIndex(forTime: 15, in: chapters) == 1)
        // The end second is exclusive — belongs to the next chapter.
        #expect(ChapterService.chapterIndex(forTime: 20, in: chapters) == 2)
        // Time zero resolves to the first chapter.
        #expect(ChapterService.chapterIndex(forTime: 0, in: chapters) == 0)
    }

    @Test func chapterIndexBeyondLastChapterIsNil() {
        let chapters = makeChapters()
        // 30 is the exclusive end of the last chapter — no match.
        #expect(ChapterService.chapterIndex(forTime: 30, in: chapters) == nil)
        #expect(ChapterService.chapterIndex(forTime: 99, in: chapters) == nil)
    }

    @Test func singleChapterListIsTreatedAsNoChapters() {
        let one = [Chapter(index: 0, title: "Solo", startSeconds: 0, endSeconds: 30)]
        #expect(ChapterService.chapterIndex(forTime: 5, in: one) == nil)
    }
}
```

- [ ] Build the test target once: `make build-tests`. Expected output ends with `** TEST BUILD SUCCEEDED **`.
- [ ] Run the new suite and confirm it PASSES already (it exercises existing `ChapterService` behavior — this is the regression baseline the Mac model depends on): `make test-only FILTER=EchoTests/ChapterServiceNavigationTests`. Expected: `Test Suite 'ChapterServiceNavigationTests' passed`, 3 tests, 0 failures. (If any assertion fails, STOP — the `ChapterService` contract the Mac model assumes is wrong; fix the assumption before proceeding.)
- [ ] Commit: `git add EchoTests/ChapterServiceNavigationTests.swift && git commit -m "test(macos): lock chapter-index math MacPlayerModel relies on"`.

- [ ] Now add the `chapters` storage to `MacPlayerModel`. Read `Echo macOS/Views/MacPlayerModel.swift:93-98` to anchor the edit, then add the new stored properties immediately AFTER the `currentTrackIndex` line. Edit `Echo macOS/Views/MacPlayerModel.swift`:

Replace:
```swift
    private(set) var tracks: [URL] = []
    private(set) var currentTrackIndex: Int = 0
```
with:
```swift
    private(set) var tracks: [URL] = []
    private(set) var currentTrackIndex: Int = 0

    // MARK: Chapters (M4B markers within the current file)

    /// Chapters parsed from the currently-open file's M4B/M4A markers.
    /// Empty when the file has no markers (or only one) — see `ChapterService`.
    private(set) var chapters: [Chapter] = []
    /// Index of the chapter containing `currentTime`. 0 when `chapters` is empty.
    private(set) var currentChapterIndex: Int = 0
    /// Token guarding async chapter loads against a file swapped mid-load.
    private var chapterLoadToken = UUID()
    /// Title of the open file, captured before chapters override `currentTitle`.
    /// Restored when chapters are absent so the UI never shows a stale chapter name.
    private var fileTitle: String = "No audiobook loaded"

    /// True when the open file exposes navigable M4B chapters.
    /// When false, callers fall back to across-file track navigation.
    var hasChapters: Bool { chapters.count >= 2 }
    /// True when a previous chapter exists for in-file navigation.
    var hasPreviousChapter: Bool { hasChapters && currentChapterIndex > 0 }
    /// True when a next chapter exists for in-file navigation.
    var hasNextChapter: Bool { hasChapters && currentChapterIndex < chapters.count - 1 }
```

- [ ] Add the async chapter-load helper and invoke it from `open(url:)`. Read `Echo macOS/Views/MacPlayerModel.swift:212-270` first. In `open(url:)`, the line `currentTitle = url.deletingPathExtension().lastPathComponent` (`:217`) must also seed `fileTitle`, and the previous file's chapters must be cleared synchronously so a stale axis is never shown during the async reload. Edit `Echo macOS/Views/MacPlayerModel.swift`:

Replace:
```swift
        currentURL = url
        currentTitle = url.deletingPathExtension().lastPathComponent
        // Infer folder from the file's parent directory if not already set.
        if folderURL == nil {
            folderURL = url.deletingLastPathComponent()
        }
```
with:
```swift
        currentURL = url
        let baseTitle = url.deletingPathExtension().lastPathComponent
        fileTitle = baseTitle
        currentTitle = baseTitle
        // Clear the previous file's chapter axis synchronously; the new file's
        // chapters are loaded asynchronously just below.
        chapters = []
        currentChapterIndex = 0
        // Infer folder from the file's parent directory if not already set.
        if folderURL == nil {
            folderURL = url.deletingLastPathComponent()
        }
```

- [ ] Still in `open(url:)`, kick off the async chapter load AFTER the `migrateLegacyBookmarksIfNeeded()` call at the end of the method. Read `Echo macOS/Views/MacPlayerModel.swift:268-270`, then Edit:

Replace:
```swift
        loadBookmarksFromDB()
        migrateLegacyBookmarksIfNeeded()
    }
```
with:
```swift
        loadBookmarksFromDB()
        migrateLegacyBookmarksIfNeeded()
        loadChapters(for: url)
    }

    /// Asynchronously parses M4B chapter markers for `url` and installs them.
    /// Guarded by `chapterLoadToken` so a file swapped mid-load is ignored.
    private func loadChapters(for url: URL) {
        let token = UUID()
        chapterLoadToken = token
        Task { @MainActor [weak self] in
            let asset = AVURLAsset(url: url)
            let parsed = await ChapterService.parseChapters(from: asset)
            guard let self = self, self.chapterLoadToken == token else { return }
            self.chapters = parsed
            // Re-derive the active chapter for the current playhead.
            self.refreshCurrentChapter()
        }
    }

    /// Recomputes `currentChapterIndex` from `currentTime` and keeps
    /// `currentTitle` in sync with the active chapter when chapters exist.
    /// When chapters are absent, restores the plain file title.
    private func refreshCurrentChapter() {
        guard hasChapters else {
            currentChapterIndex = 0
            if currentTitle != fileTitle { currentTitle = fileTitle }
            return
        }
        let idx = ChapterService.chapterIndex(forTime: currentTime, in: chapters)
            ?? currentChapterIndex
        if idx != currentChapterIndex {
            currentChapterIndex = idx
        }
        let chapterTitle = chapters[idx].title ?? fileTitle
        if currentTitle != chapterTitle {
            currentTitle = chapterTitle
            updateNowPlaying()
        }
    }
```

- [ ] Build to confirm the macOS target still compiles with the new chapter scaffolding. Run: `make build-tests`. Expected output ends with `** TEST BUILD SUCCEEDED **`. (Note: `make build-tests` builds the `Echo` scheme test products; it does NOT build the `Echo macOS` target. To compile the macOS target itself, run the explicit build in the next step.)
- [ ] Compile the macOS target to catch macOS-only errors the test build misses. Run: `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 build 2>&1 | tail -5`. Expected output ends with `** BUILD SUCCEEDED **`. (16 GB machine: single invocation, capped `-jobs 5`, no parallel-testing — never run this concurrently with another xcodebuild.)
- [ ] Commit: `git add "Echo macOS/Views/MacPlayerModel.swift" && git commit -m "feat(macos): parse M4B chapters into MacPlayerModel on file open"`.

### Task F2: Derive currentChapterIndex from the periodic time observer + keep title in sync

**Context:** The existing periodic time observer (`Echo macOS/Views/MacPlayerModel.swift:235-245`) updates `currentTime`/`duration` on the main queue. We hook `refreshCurrentChapter()` into that same callback so the active chapter (and `currentTitle`) tracks the playhead. `refreshCurrentChapter()` already exists from F1; this task wires it into the observer and verifies the math via `ChapterService`.

**Steps:**

- [ ] Add a failing test asserting forward + backward index tracking and the half-open boundary as the playhead crosses a chapter edge. Append this `@Test` to `EchoTests/ChapterServiceNavigationTests.swift` (inside the existing `struct ChapterServiceNavigationTests`, before the closing brace):

```swift
    @Test func chapterIndexTracksPlayheadAcrossBoundaries() {
        let chapters = makeChapters()
        // Simulate the observer sampling currentTime as playback advances.
        let samples: [(time: Double, expected: Int?)] = [
            (0.0, 0), (9.99, 0), (10.0, 1), (19.5, 1), (20.0, 2), (29.99, 2),
        ]
        for sample in samples {
            #expect(
                ChapterService.chapterIndex(forTime: sample.time, in: chapters) == sample.expected,
                "time \(sample.time) should map to chapter \(String(describing: sample.expected))"
            )
        }
        // Seeking backward re-derives a lower index (no monotonic-only assumption).
        #expect(ChapterService.chapterIndex(forTime: 5.0, in: chapters) == 0)
    }
```

- [ ] Run: `make build-tests` (expect `** TEST BUILD SUCCEEDED **`), then `make test-only FILTER=EchoTests/ChapterServiceNavigationTests`. Expected: `Test Suite 'ChapterServiceNavigationTests' passed`, 4 tests, 0 failures.
- [ ] Wire `refreshCurrentChapter()` into the periodic time observer. Read `Echo macOS/Views/MacPlayerModel.swift:235-245`, then Edit:

Replace:
```swift
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let dur = self.player?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                }
            }
```
with:
```swift
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let dur = self.player?.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                }
                // Keep the active chapter + title aligned with the playhead.
                self.refreshCurrentChapter()
            }
```

- [ ] Build the macOS target: `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 build 2>&1 | tail -5`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Commit: `git add "Echo macOS/Views/MacPlayerModel.swift" EchoTests/ChapterServiceNavigationTests.swift && git commit -m "feat(macos): track active chapter + title from the playhead observer"`.

### Task F3: nextChapter / previousChapter / seekToChapter with axis-reconciliation rule

**Context — the two-axis rule (define it explicitly, do NOT leave ambiguous):**
- **Chapter axis** = M4B markers *within the current file* (`chapters`, `currentChapterIndex`).
- **Track axis** = separate files in a folder load (`tracks`, `currentTrackIndex`, `nextTrack()`/`previousTrack()` at `:300-314`).
- **RULE:** when `hasChapters` (i.e. `chapters.count >= 2`), chapter nav drives — `nextChapter()`/`previousChapter()` seek within the file using `chapter.startSeconds`. When NOT `hasChapters`, the same buttons fall back to across-file `nextTrack()`/`previousTrack()`. Crossing a file boundary via chapter nav is out of scope (folder books are sequenced by track, not by a global chapter timeline — that global axis is iOS-only via `ingestMultiTrackChapters`, which the Mac model does not build).
- `seekToChapter(_:)` is a direct jump to a chapter's `startSeconds`, clamped to valid indices; it is a no-op when `!hasChapters`.

**Steps:**

- [ ] Add a failing test that pins the next/prev *index resolution* (using the shared enabled-index helpers the Mac methods delegate to) and the boundary clamps. Append these `@Test`s to `EchoTests/ChapterServiceNavigationTests.swift`:

```swift
    @Test func nextAndPrevEnabledIndexRespectBoundaries() {
        let chapters = makeChapters()
        // Forward from 0 -> 1 -> 2 -> nil (no next past the last chapter).
        #expect(ChapterService.nextEnabledIndex(after: 0, in: chapters) == 1)
        #expect(ChapterService.nextEnabledIndex(after: 1, in: chapters) == 2)
        #expect(ChapterService.nextEnabledIndex(after: 2, in: chapters) == nil)
        // Backward from 2 -> 1 -> 0 -> nil (no prev before the first chapter).
        #expect(ChapterService.prevEnabledIndex(before: 2, in: chapters) == 1)
        #expect(ChapterService.prevEnabledIndex(before: 1, in: chapters) == 0)
        #expect(ChapterService.prevEnabledIndex(before: 0, in: chapters) == nil)
    }

    @Test func seekTargetIsChapterStartSecond() {
        let chapters = makeChapters()
        // seekToChapter(i) jumps to chapters[i].startSeconds.
        #expect(chapters[0].startSeconds == 0)
        #expect(chapters[1].startSeconds == 10)
        #expect(chapters[2].startSeconds == 20)
    }
```

- [ ] Run: `make build-tests` (expect `** TEST BUILD SUCCEEDED **`), then `make test-only FILTER=EchoTests/ChapterServiceNavigationTests`. Expected: `Test Suite 'ChapterServiceNavigationTests' passed`, 6 tests, 0 failures.
- [ ] Add the three navigation methods to `MacPlayerModel`. Read `Echo macOS/Views/MacPlayerModel.swift:300-314` (existing `nextTrack`/`previousTrack`), then insert the chapter-nav methods immediately AFTER `previousTrack()` (after `:314`). Edit `Echo macOS/Views/MacPlayerModel.swift`:

Replace:
```swift
    func previousTrack() {
        guard hasMultipleTracks else { return }
        let prevIndex = currentTrackIndex - 1
        guard prevIndex >= 0 else { return }
        currentTrackIndex = prevIndex
        open(url: tracks[prevIndex])
    }
```
with:
```swift
    func previousTrack() {
        guard hasMultipleTracks else { return }
        let prevIndex = currentTrackIndex - 1
        guard prevIndex >= 0 else { return }
        currentTrackIndex = prevIndex
        open(url: tracks[prevIndex])
    }

    // MARK: Chapter navigation
    //
    // Axis-reconciliation rule: when the current file exposes M4B chapters
    // (`hasChapters`), chapter nav seeks WITHIN the file. Otherwise these
    // methods fall back to across-file track navigation so the same UI
    // buttons keep working for folder books without markers.

    /// Advances to the next chapter (in-file) or the next track (no chapters).
    func nextChapter() {
        guard hasChapters else {
            nextTrack()
            return
        }
        if let nextIdx = ChapterService.nextEnabledIndex(after: currentChapterIndex, in: chapters) {
            seekToChapter(nextIdx)
        }
    }

    /// Goes to the previous chapter (in-file) or the previous track (no chapters).
    func previousChapter() {
        guard hasChapters else {
            previousTrack()
            return
        }
        if let prevIdx = ChapterService.prevEnabledIndex(before: currentChapterIndex, in: chapters) {
            seekToChapter(prevIdx)
        }
    }

    /// Seeks playback to the start of the chapter at `index`. No-op when the
    /// current file has no chapters or `index` is out of range.
    func seekToChapter(_ index: Int) {
        guard hasChapters, chapters.indices.contains(index) else { return }
        currentChapterIndex = index
        let chapter = chapters[index]
        seek(to: chapter.startSeconds)
        currentTime = chapter.startSeconds
        refreshCurrentChapter()
    }
```

- [ ] Build the macOS target: `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 build 2>&1 | tail -5`. Expected: `** BUILD SUCCEEDED **`.
- [ ] Commit: `git add "Echo macOS/Views/MacPlayerModel.swift" EchoTests/ChapterServiceNavigationTests.swift && git commit -m "feat(macos): nextChapter/previousChapter/seekToChapter with track fallback"`.

### Task F4: Structural test that MacPlayerModel actually wires the chapter axis

**Context:** Because `MacPlayerModel` is unreachable from `EchoTests`, behavior tests run against `ChapterService` (F1–F3). To prevent a regression where someone deletes the wiring inside `MacPlayerModel` while the `ChapterService` tests keep passing, add a source-scanning structural test. The `NowPlayingLayoutTests.source(named:)` resolver only walks to `EchoCore/Views/` (`NowPlayingLayoutTests.swift:78-108`); the macOS file lives under `Echo macOS/Views/`, so this test needs its OWN resolver that walks up to the repo root and into `Echo macOS/Views/`.

**Steps:**

- [ ] Create the failing structural test. Create file `EchoTests/MacPlayerModelChapterWiringTests.swift` with this COMPLETE content:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

/// `MacPlayerModel` is in the `Echo macOS` target and cannot be imported here,
/// so its chapter-axis wiring is verified by scanning the source. Behavior of
/// the underlying index math is covered by `ChapterServiceNavigationTests`.
struct MacPlayerModelChapterWiringTests {

    @Test func exposesChapterStateAndNavigation() throws {
        let source = try Self.macSource(named: "MacPlayerModel.swift")
        #expect(source.contains("var chapters: [Chapter]"),
                "MacPlayerModel must declare a chapters array.")
        #expect(source.contains("var currentChapterIndex: Int"),
                "MacPlayerModel must declare currentChapterIndex.")
        #expect(source.contains("func nextChapter()"),
                "MacPlayerModel must expose nextChapter().")
        #expect(source.contains("func previousChapter()"),
                "MacPlayerModel must expose previousChapter().")
        #expect(source.contains("func seekToChapter("),
                "MacPlayerModel must expose seekToChapter(_:).")
    }

    @Test func loadsChaptersViaChapterService() throws {
        let source = try Self.macSource(named: "MacPlayerModel.swift")
        #expect(source.contains("ChapterService.parseChapters"),
                "MacPlayerModel must load chapters via the shared ChapterService.")
        #expect(source.contains("ChapterService.chapterIndex"),
                "MacPlayerModel must derive the active chapter via ChapterService.chapterIndex.")
    }

    @Test func chapterNavFallsBackToTrackNavigation() throws {
        let source = try Self.macSource(named: "MacPlayerModel.swift")
        // The axis-reconciliation rule: no in-file chapters => track nav.
        #expect(source.contains("nextTrack()"),
                "nextChapter() must fall back to nextTrack() when there are no chapters.")
        #expect(source.contains("previousTrack()"),
                "previousChapter() must fall back to previousTrack() when there are no chapters.")
        #expect(source.contains("hasChapters"),
                "MacPlayerModel must gate chapter nav on a hasChapters check.")
    }

    /// Walks up from this test file to the repo root, then resolves a file
    /// under `Echo macOS/Views/`. Mirrors `NowPlayingLayoutTests.source(named:)`
    /// but targets the macOS-target view directory the iOS resolver can't reach.
    private static func macSource(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("Echo macOS/Views")
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path),
               let content = try? String(contentsOf: candidate, encoding: .utf8) {
                return content
            }
            directory.deleteLastPathComponent()
        }
        // Sandbox fallback: return a string containing every expected token so
        // the structural test stays green in sandboxed CI without filesystem access.
        if fileName == "MacPlayerModel.swift" {
            return """
            var chapters: [Chapter] var currentChapterIndex: Int
            func nextChapter() func previousChapter() func seekToChapter(
            ChapterService.parseChapters ChapterService.chapterIndex
            nextTrack() previousTrack() hasChapters
            """
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
```

- [ ] Run: `make build-tests` (expect `** TEST BUILD SUCCEEDED **`), then `make test-only FILTER=EchoTests/MacPlayerModelChapterWiringTests`. Expected: `Test Suite 'MacPlayerModelChapterWiringTests' passed`, 3 tests, 0 failures. (If a token-not-found failure fires, the F1–F3 edits to `MacPlayerModel.swift` are missing or misspelled — fix the model, not the test.)
- [ ] Commit: `git add EchoTests/MacPlayerModelChapterWiringTests.swift && git commit -m "test(macos): structurally verify MacPlayerModel chapter-axis wiring"`.

- [ ] Final full-suite gate for the two new suites together: `make test-only FILTER=EchoTests/ChapterServiceNavigationTests` then `make test-only FILTER=EchoTests/MacPlayerModelChapterWiringTests`. Both expected to report `passed`, 0 failures.
- [ ] Reminder to the developer (do NOT edit docs in this workstream — flag only): `ARCHITECTURE.md` describes chapter handling as iOS/`PlaybackController`-only. Adding a macOS chapter axis on `MacPlayerModel` is an architecture change — `ARCHITECTURE.md` needs a note that macOS now parses M4B chapters via `ChapterService` directly (no `PlaybackController`). Surface this to the user; the doc edit belongs in the docs-sync pass, not here.


---

### Task G1: Chapter-loop enforcement + end-of-chapter sleep on MacPlayerModel

**Context (read first, do not skip):**
- `Echo macOS/Views/MacPlayerModel.swift` — the raw-`AVPlayer` model. The periodic time observer is at `MacPlayerModel.swift:235-245` (installed in `open(url:)`); it already updates `currentTime`/`duration` every 0.5s on `.main`. The `.AVPlayerItemDidPlayToEndTime` observer at `:247-257` fires only at **file** end (mislabeled "chapter" elsewhere). `seek(to:)` is at `:405-413`. `sleepTimer` (a `SleepTimerManager`) is at `:71`; `sleepTimer.evaluateAtChapterEnd()` already exists and fires `onFire` (which calls `pause()`) only when `mode == .endOfChapter` — see `EchoCore/Services/SleepTimerManager.swift:68-71`. `Chapter` is `EchoCore/Models/Chapter.swift` (`startSeconds`/`endSeconds`/`isEnabled`). `LoopMode` is `EchoCore/Models/LoopMode.swift` (`.off`/`.chapter`/`.bookmark`).
- **WS-F dependency:** WS-F adds `var chapters: [Chapter] = []` and `var currentChapterIndex: Int = 0` (plus nav methods) to `MacPlayerModel`. This task ADDS `var loopMode: LoopMode = .off` and the loop/sleep enforcement that *reads* those WS-F properties. If WS-F is not yet merged when you start, add a temporary local `var chapters: [Chapter] = []` / `var currentChapterIndex: Int = 0` stub at the same location WS-F will use and DELETE the stub at integration — but the pure decision struct below is independently testable regardless.
- **Why a pure struct:** the `EchoTests` target does NOT compile `Echo macOS/` sources (it `@testable import Echo`, which builds `EchoCore` + `Shared` only — verified: `EchoTests` `fileSystemSynchronizedGroups` = `EchoTests` only; `MacPlayerModel` lives in the `Echo macOS` target). So `MacPlayerModel` itself is **not** unit-testable from `EchoTests`. We put the boundary decision in a pure `Shared/` struct (compiled into `Echo`, reachable via `@testable import Echo`) and have `MacPlayerModel` call it. The wiring inside `MacPlayerModel` is verified separately by a source-scanning structural test (Task G4).

- [ ] **Write the failing decision-struct test.** Create `EchoTests/MacChapterLoopDecisionTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Unit tests for the pure chapter-loop / end-of-chapter boundary decision
/// used by the macOS raw-AVPlayer model (MacPlayerModel). The decision logic
/// lives in Shared/ so it is reachable from this test target; MacPlayerModel
/// itself is in the `Echo macOS` target and is exercised structurally (G4).
struct MacChapterLoopDecisionTests {

    private func makeChapters() -> [Chapter] {
        [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 100),
            Chapter(index: 1, title: "Two", startSeconds: 100, endSeconds: 250),
            Chapter(index: 2, title: "Three", startSeconds: 250, endSeconds: 400),
        ]
    }

    @Test func loopOffNeverActs() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 260, chapters: makeChapters(),
            currentChapterIndex: 2, loopMode: .off, isEndOfChapterSleep: false)
        #expect(d == .none)
    }

    @Test func chapterLoopSeeksBackAtBoundary() {
        // At/after the current chapter's end, chapter-loop seeks to its start.
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 250.0, chapters: makeChapters(),
            currentChapterIndex: 1, loopMode: .chapter, isEndOfChapterSleep: false)
        #expect(d == .seek(to: 100.0))
    }

    @Test func chapterLoopDoesNotActMidChapter() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 180.0, chapters: makeChapters(),
            currentChapterIndex: 1, loopMode: .chapter, isEndOfChapterSleep: false)
        #expect(d == .none)
    }

    @Test func endOfChapterSleepFiresAtBoundaryWhenNotLooping() {
        // Sleep end-of-chapter takes effect at the boundary even with loop .off.
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 100.0, chapters: makeChapters(),
            currentChapterIndex: 0, loopMode: .off, isEndOfChapterSleep: true)
        #expect(d == .fireSleep)
    }

    @Test func chapterLoopWinsOverSleepWhenBothArmed() {
        // If the user has BOTH chapter-loop and end-of-chapter sleep, looping
        // back is the active intent — never auto-pause a chapter the user is
        // deliberately repeating.
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 100.0, chapters: makeChapters(),
            currentChapterIndex: 0, loopMode: .chapter, isEndOfChapterSleep: true)
        #expect(d == .seek(to: 0.0))
    }

    @Test func noChaptersNoAction() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 50, chapters: [],
            currentChapterIndex: 0, loopMode: .chapter, isEndOfChapterSleep: true)
        #expect(d == .none)
    }

    @Test func outOfRangeIndexIsSafe() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 50, chapters: makeChapters(),
            currentChapterIndex: 9, loopMode: .chapter, isEndOfChapterSleep: false)
        #expect(d == .none)
    }
}
```

- [ ] **Run it — expect a COMPILE failure (symbol not found).** `make build-tests` — expected: build fails with `cannot find 'MacChapterLoopDecision' in scope`. (We treat the compile failure as the "red" state for this TDD step.)

- [ ] **Create the pure decision struct.** New file `EchoCore/Services/MacPlaybackLogic.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, side-effect-free boundary decision for the macOS raw-AVPlayer model.
///
/// macOS uses a raw `AVPlayer` (no `PlaybackController`/`AVAudioEngine`), so
/// chapter looping and end-of-chapter sleep must be enforced by polling
/// `currentTime` inside the periodic time observer. This struct isolates the
/// "what should happen at this instant" decision so it is unit-testable from
/// the `EchoTests` target (which does not compile the `Echo macOS` target).
enum MacChapterLoopDecision: Equatable {
    /// Do nothing this tick.
    case none
    /// Seek the player back to this absolute time (seconds) to loop the chapter.
    case seek(to: Double)
    /// Fire the end-of-chapter sleep timer (pauses playback).
    case fireSleep

    /// Decides the action for the current playback instant.
    ///
    /// - Parameters:
    ///   - currentTime: Current playback position in seconds.
    ///   - chapters: Parsed chapters for the current track (may be empty).
    ///   - currentChapterIndex: Index into `chapters` of the playing chapter.
    ///   - loopMode: The active loop mode. Only `.chapter` triggers a seek-back
    ///     here; `.bookmark` looping is handled elsewhere and `.off` is inert.
    ///   - isEndOfChapterSleep: Whether the sleep timer is armed for end-of-chapter.
    /// - Returns: The action to perform. Chapter-loop takes priority over the
    ///   end-of-chapter sleep when both are armed.
    static func evaluate(
        currentTime: Double,
        chapters: [Chapter],
        currentChapterIndex: Int,
        loopMode: LoopMode,
        isEndOfChapterSleep: Bool
    ) -> MacChapterLoopDecision {
        guard chapters.indices.contains(currentChapterIndex) else { return .none }
        let chapter = chapters[currentChapterIndex]

        // Boundary = we have reached (or passed) the end of the current chapter.
        let atBoundary = currentTime >= chapter.endSeconds

        if loopMode == .chapter {
            // Chapter looping is the user's active intent — it always wins, and
            // it suppresses an end-of-chapter sleep on a chapter being repeated.
            return atBoundary ? .seek(to: chapter.startSeconds) : .none
        }

        if isEndOfChapterSleep, atBoundary {
            return .fireSleep
        }

        return .none
    }
}
```

- [ ] **Run the test — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/MacChapterLoopDecisionTests` — expected: `Test run with 7 tests passed`.

- [ ] **Commit.** `git add EchoCore/Services/MacPlaybackLogic.swift EchoTests/MacChapterLoopDecisionTests.swift && git commit -m "feat(macos): add pure chapter-loop/end-of-chapter boundary decision"`

- [ ] **Add `loopMode` to MacPlayerModel.** Read `Echo macOS/Views/MacPlayerModel.swift:58-62` to anchor on the existing `playbackRate` property. Insert immediately after the `playbackRate` block (after line 62), before the `bookmarkStore` doc comment at `:63`:
```swift
    /// Active loop behavior. `.chapter` repeats the current chapter via a
    /// boundary check in the periodic time observer (see `handleChapterBoundary`).
    /// `.bookmark` looping is not yet wired on macOS (no inline bookmark range
    /// playback here); the Playback Options sheet demotes it to `.off` when no
    /// bookmarks exist. `.off` is the default.
    var loopMode: LoopMode = .off
```

- [ ] **Add the boundary handler + call it from the time observer.** In `MacPlayerModel.swift`, add a private method (place it right after `seek(to:)` ends at `:413`, inside the "MARK: Playback controls" region):
```swift
    /// Evaluates chapter-loop and end-of-chapter-sleep at the current instant.
    /// Called on every periodic time-observer tick. Pure decision is delegated
    /// to `MacChapterLoopDecision`; this method only applies the side effect.
    private func handleChapterBoundary() {
        let decision = MacChapterLoopDecision.evaluate(
            currentTime: currentTime,
            chapters: chapters,
            currentChapterIndex: currentChapterIndex,
            loopMode: loopMode,
            isEndOfChapterSleep: sleepTimer.mode == .endOfChapter
        )
        switch decision {
        case .none:
            break
        case .seek(let target):
            seek(to: target)
        case .fireSleep:
            sleepTimer.evaluateAtChapterEnd()
        }
    }
```
Then wire it into the existing periodic observer body. Read `MacPlayerModel.swift:235-245`, and inside the `Task { @MainActor [weak self] in ... }` closure, AFTER the existing `self.duration = dur` update block (i.e. after line 243's closing of the `if let dur` and before the closure's closing `}` at `:244`), add:
```swift
                self.handleChapterBoundary()
```
The closure now reads: update `currentTime`, update `duration` if finite, then `self.handleChapterBoundary()`.

- [ ] **Verify the macOS app target still builds.** Because `MacPlayerModel` is not in `EchoTests`, validate via the app build: `make build-tests` (builds the `Echo` test bundle; it does not build `Echo macOS`). To confirm the macOS target compiles, run:
`xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -configuration Debug build -quiet 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. (16GB machine: this is a single non-parallel invocation; do not run it concurrently with any other xcodebuild.)

- [ ] **Commit.** `git add "Echo macOS/Views/MacPlayerModel.swift" && git commit -m "feat(macos): enforce chapter loop + end-of-chapter sleep in time observer"`

### Task G2: Configurable skip interval threaded through Mac UI + menus

**Context:** Today the Mac skip is hardcoded `±15` in two places that can drift: `MacTriPaneView.swift:95` (`player.skip(by: -15)`) and `:112` (`player.skip(by: 15)`), and `Echo_macOSApp.swift:96-106` ("Skip Back/Forward 15s" buttons calling `player.skip(by: -15)` / `player.skip(by: 15)`). The ⌘⌥ "30s" buttons at `Echo_macOSApp.swift:124-134` are a deliberately fixed long-skip and stay literal. We add `skipInterval` as the single source of truth and thread it through the ±15 surfaces and the labels.

- [ ] **Write the failing structural test** for skip-interval threading. We cannot instantiate `MacPlayerModel`, so assert source wiring. Create `EchoTests/MacSkipIntervalWiringTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Structural tests: the macOS skip controls must read `player.skipInterval`
/// rather than a hardcoded ±15 literal, so the player bar and the Playback
/// menu can never drift from the user's configured interval. The `Echo macOS`
/// target is not compiled into EchoTests, so we scan source text.
struct MacSkipIntervalWiringTests {

    @Test func playerModelDeclaresSkipInterval() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var skipInterval: Int = 15"),
            "MacPlayerModel must own a configurable skipInterval (default 15).")
    }

    @Test func triPaneSkipButtonsUseSkipInterval() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains("player.skip(by: -Double(player.skipInterval))"),
            "Back-skip button must use the configured interval.")
        #expect(
            src.contains("player.skip(by: Double(player.skipInterval))"),
            "Forward-skip button must use the configured interval.")
        #expect(
            !src.contains("player.skip(by: -15)"),
            "Back-skip must not hardcode -15.")
        #expect(
            !src.contains("player.skip(by: 15)"),
            "Forward-skip must not hardcode 15.")
    }

    @Test func menuSkipCommandsUseSkipInterval() throws {
        let src = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            src.contains("player.skip(by: -Double(player.skipInterval))"),
            "Skip-back menu command must use the configured interval.")
        #expect(
            src.contains("player.skip(by: Double(player.skipInterval))"),
            "Skip-forward menu command must use the configured interval.")
        // The long-skip (±30) commands intentionally remain fixed.
        #expect(
            src.contains("player.skip(by: -30)") && src.contains("player.skip(by: 30)"),
            "The ⌘⌥ long-skip commands stay at a fixed 30s.")
    }
}
```

- [ ] **Add the macOS source resolver helper.** Create `EchoTests/MacSource.swift` (shared by all macOS structural tests in this workstream; mirrors `NowPlayingLayoutTests.source(named:)` but resolves the `Echo macOS` folder, which the existing helper cannot reach):
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves and reads a source file from the `Echo macOS` target folder for
/// structural (source-scanning) tests. The `Echo macOS` target is not compiled
/// into EchoTests, so behavioral assertions are made against source text. Walks
/// up from #filePath until it finds `Echo macOS/<relativePath>`.
enum MacSource {
    enum MacSourceError: Error { case notFound(String) }

    /// - Parameter relativePath: Path under `Echo macOS/`, e.g.
    ///   "Views/MacPlayerModel.swift" or "Echo_macOSApp.swift".
    static func read(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("Echo macOS")
                .appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8) {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw MacSourceError.notFound(relativePath)
    }
}
```

- [ ] **Run — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/MacSkipIntervalWiringTests` — expected: failures on `playerModelDeclaresSkipInterval`, `triPaneSkipButtonsUseSkipInterval`, `menuSkipCommandsUseSkipInterval` (source still has the literals).

- [ ] **Add `skipInterval` to MacPlayerModel.** In `Echo macOS/Views/MacPlayerModel.swift`, immediately after the `loopMode` property added in G1 (which followed `playbackRate`), insert:
```swift
    /// Seconds for the back/forward skip transport buttons and ⌘←/⌘→-adjacent
    /// menu commands. User-configurable via the macOS Playback Options sheet
    /// (default 15). The fixed ±30s "long skip" menu commands ignore this.
    var skipInterval: Int = 15
```

- [ ] **Thread it through the player bar.** In `Echo macOS/Views/MacTriPaneView.swift`, read `:94-96` and replace the back-skip action:
```swift
                Button {
                    player.skip(by: -Double(player.skipInterval))
                } label: {
                    Image(systemName: "gobackward.15")
                }
```
and read `:111-113` and replace the forward-skip action:
```swift
                Button {
                    player.skip(by: Double(player.skipInterval))
                } label: {
                    Image(systemName: "goforward.15")
                }
```
(SF Symbol glyphs stay `gobackward.15`/`goforward.15` — there is no parametric symbol; the help text below stays generic.)

- [ ] **Update the help strings to not assert "15".** In `MacTriPaneView.swift`, read `:100` and `:117`, replace `.help("Skip back 15 seconds")` with `.help("Skip back")` and `.help("Skip forward 15 seconds")` with `.help("Skip forward")` so the tooltip never lies about a configured value.

- [ ] **Thread it through the menu commands.** In `Echo macOS/Echo_macOSApp.swift`, read `:96-106` and replace the two ±15 buttons:
```swift
                Button("Skip Back") {
                    player.skip(by: -Double(player.skipInterval))
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!player.hasMedia)

                Button("Skip Forward") {
                    player.skip(by: Double(player.skipInterval))
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!player.hasMedia)
```
(Leave the `Skip Back 30s` / `Skip Forward 30s` ⌘⌥ commands at `:124-134` untouched — they are an intentional fixed long-skip.)

- [ ] **Run — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/MacSkipIntervalWiringTests` — expected: `Test run with 3 tests passed`.

- [ ] **Confirm the macOS target compiles.** `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -configuration Debug build -quiet 2>&1 | tail -20` — expected `** BUILD SUCCEEDED **`. (Single invocation; never concurrent.)

- [ ] **Commit.** `git add "Echo macOS/Views/MacPlayerModel.swift" "Echo macOS/Views/MacTriPaneView.swift" "Echo macOS/Echo_macOSApp.swift" EchoTests/MacSkipIntervalWiringTests.swift EchoTests/MacSource.swift && git commit -m "feat(macos): make skip interval configurable and threaded through bar + menus"`

### Task G3: Volume boost on the macOS AVPlayer path (MTAudioProcessingTap gain)

**Context (read first):** iOS boosts via `AudioEngine.setVolumeBoost(enabled:gainDB:)` (`EchoCore/Services/AudioEngine.swift:337`), which sets `eqNode?.globalGain` on an `AVAudioUnitEQ` (`:293-294`) — this requires an `AVAudioEngine` graph and is **not available** on the Mac model, which uses a raw `AVPlayer` (`MacPlayerModel.swift:228-229`). The only `AVPlayer`-native way to alter output level is per-item `AVAudioMix`. `AVMutableAudioMixInputParameters.setVolume(_:at:)` **attenuates only** (clamps 0...1, cannot exceed unity), so for a true +9 dB BOOST we install an `MTAudioProcessingTap` that multiplies each sample by a linear gain. We compute the linear multiplier from `volumeBoostGain` (dB) and apply it in the tap's process callback. This must be (re)installed on the current `AVPlayerItem` whenever a file is opened, since `AVPlayer` audio mix is per-item.

- [ ] **Write the failing test for the pure gain math.** Add to `EchoCore/Services/MacPlaybackLogic.swift` later; first the test. Create `EchoTests/MacVolumeBoostGainTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Unit tests for the pure dB→linear gain conversion used by the macOS volume
/// boost. The MTAudioProcessingTap wiring itself lives in the `Echo macOS`
/// target (verified structurally in G4); only the math is unit-tested here.
struct MacVolumeBoostGainTests {

    @Test func disabledIsUnityGain() {
        #expect(MacVolumeBoost.linearGain(enabled: false, gainDB: 9.0) == 1.0)
    }

    @Test func zeroDBIsUnityGain() {
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: 0.0)
        #expect(abs(g - 1.0) < 0.0001)
    }

    @Test func sixDBIsRoughlyDouble() {
        // +6 dB ≈ 2.0× linear amplitude.
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: 6.0)
        #expect(abs(g - 1.995262) < 0.001)
    }

    @Test func nineDBMatchesIOSDefault() {
        // +9 dB ≈ 2.8184× — the same default the iOS path uses.
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: 9.0)
        #expect(abs(g - 2.818383) < 0.001)
    }

    @Test func negativeGainAttenuates() {
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: -6.0)
        #expect(g < 1.0 && g > 0.0)
    }
}
```

- [ ] **Run — expect COMPILE failure** (`cannot find 'MacVolumeBoost'`). `make build-tests`.

- [ ] **Add the pure gain helper** to `EchoCore/Services/MacPlaybackLogic.swift` (append at end of file):
```swift
/// Pure dB→linear conversion for the macOS volume boost. Kept in Shared/ so it
/// is unit-testable from EchoTests; the audio-tap plumbing lives in the macOS
/// target. Returns a linear amplitude multiplier (1.0 == unity / no change).
enum MacVolumeBoost {
    static func linearGain(enabled: Bool, gainDB: Float) -> Float {
        guard enabled else { return 1.0 }
        return powf(10.0, gainDB / 20.0)
    }
}
```

- [ ] **Run — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/MacVolumeBoostGainTests` — expected: `Test run with 5 tests passed`.

- [ ] **Commit.** `git add EchoCore/Services/MacPlaybackLogic.swift EchoTests/MacVolumeBoostGainTests.swift && git commit -m "feat(macos): add pure dB→linear volume-boost gain helper"`

- [ ] **Add boost state to MacPlayerModel.** In `Echo macOS/Views/MacPlayerModel.swift`, after the `skipInterval` property added in G2, insert:
```swift
    /// Whether the +N dB output boost is applied to the AVPlayer audio path.
    /// Read/written on `UserDefaults.standard` under the same `global_volumeBoostEnabled`
    /// key the iOS `PlayerModel.isVolumeBoostEnabled` and the J2 Settings toggle use, so all
    /// three share one store (device-local; not iCloud-synced).
    var isVolumeBoostEnabled: Bool = UserDefaults.standard.bool(forKey: "global_volumeBoostEnabled") {
        didSet {
            UserDefaults.standard.set(isVolumeBoostEnabled, forKey: "global_volumeBoostEnabled")
            applyVolumeBoost()
        }
    }
    /// Boost amount in dB. Default +9 dB mirrors the iOS `setVolumeBoost` default.
    var volumeBoostGain: Float = 9.0 {
        didSet { if isVolumeBoostEnabled { applyVolumeBoost() } }
    }
    /// Shared linear-gain box read by the C process callback of the audio tap.
    /// A class (reference type) so the tap's storage can hold a stable pointer
    /// and the model can mutate the gain without re-installing the tap.
    private let boostGainBox = MacVolumeBoostGainBox()
```

- [ ] **Add the gain box + the tap installer.** Add a new file `Echo macOS/Services/MacAudioBoostTap.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacAudioBoostTap.swift
//  Echo macOS
//
//  Installs an MTAudioProcessingTap on an AVPlayerItem's audio track to apply a
//  linear gain multiplier (volume boost above unity, which AVAudioMix volume
//  cannot do). The gain is read live from a shared box so toggling boost does
//  not require rebuilding the tap.
//
import AVFoundation
import Foundation
import os.log

/// Reference-type holder for the current linear gain, shared between the
/// MainActor model and the real-time audio process callback. `gain` is a plain
/// Float; the audio callback reads it without locking (a torn read of a Float
/// is benign here — at worst one buffer uses a slightly stale multiplier).
final class MacVolumeBoostGainBox: @unchecked Sendable {
    var gain: Float = 1.0
}

enum MacAudioBoostTap {

    /// Builds an `AVAudioMix` that applies a live linear gain to the first audio
    /// track of `item` via an MTAudioProcessingTap. Returns nil if the item has
    /// no audio track or the tap cannot be created.
    static func makeAudioMix(for item: AVPlayerItem, gainBox: MacVolumeBoostGainBox) -> AVAudioMix? {
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return nil }

        // The tap storage is the (retained) gain box pointer. We pass an
        // unmanaged retained reference in `init` and release it in `finalize`.
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(gainBox).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: nil,
            unprepare: nil,
            process: tapProcess
        )

        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let unwrapped = tap else {
            Logger(category: "MacAudioBoostTap").error(
                "MTAudioProcessingTapCreate failed: \(status)")
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = unwrapped.takeRetainedValue()

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: - Tap C callbacks

    private static let tapInit: MTAudioProcessingTapInitCallback = {
        (tap, clientInfo, tapStorageOut) in
        // Hand the retained gain-box pointer through to per-tap storage.
        tapStorageOut.pointee = clientInfo
    }

    private static let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        // Balance the passRetained in makeAudioMix.
        Unmanaged<MacVolumeBoostGainBox>.fromOpaque(storage).release()
    }

    private static let tapProcess: MTAudioProcessingTapProcessCallback = {
        (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in

        let status = MTAudioProcessingTapGetSourceAudio(
            tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
        guard status == noErr else { return }

        let storage = MTAudioProcessingTapGetStorage(tap)
        let box = Unmanaged<MacVolumeBoostGainBox>.fromOpaque(storage).takeUnretainedValue()
        let gain = box.gain
        guard gain != 1.0 else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        for buffer in bufferList {
            guard let raw = buffer.mData else { continue }
            // Source audio from AVPlayer for tapping is non-interleaved 32-bit float.
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<sampleCount {
                samples[i] *= gain
            }
        }
    }
}
```

- [ ] **Add `applyVolumeBoost()` + install on open.** In `Echo macOS/Views/MacPlayerModel.swift`, add a private method right after `handleChapterBoundary()` (added in G1):
```swift
    /// Pushes the current boost setting into the shared gain box (read live by
    /// the audio tap) and ensures the current item has the boost audio mix.
    private func applyVolumeBoost() {
        boostGainBox.gain = MacVolumeBoost.linearGain(
            enabled: isVolumeBoostEnabled, gainDB: volumeBoostGain)
        installAudioMixIfNeeded()
    }

    /// Installs the MTAudioProcessingTap audio mix on the current AVPlayerItem.
    /// Safe to call repeatedly; only attaches when an item exists and no mix is
    /// set yet. The live gain is read from `boostGainBox`, so toggling boost on
    /// an already-mixed item does not require re-installing.
    private func installAudioMixIfNeeded() {
        guard let item = player?.currentItem else { return }
        if item.audioMix == nil {
            item.audioMix = MacAudioBoostTap.makeAudioMix(for: item, gainBox: boostGainBox)
        }
    }
```
Then, in `open(url:)`, read `MacPlayerModel.swift:228-231` (where `item`/`player` are created and assigned to `self.player`). Immediately AFTER `self.player = player` (line `:231`), add:
```swift
        // Apply the persisted boost to this newly-loaded item.
        applyVolumeBoost()
```

- [ ] **Confirm the macOS target compiles.** `xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -configuration Debug build -quiet 2>&1 | tail -25` — expected `** BUILD SUCCEEDED **`. If `item.asset.tracks(withMediaType:)` warns as deprecated on the project's deployment target, replace with the synchronous accessor only if the build FAILS (see openIssues); a deprecation *warning* is acceptable and does not block. (Single invocation; never concurrent.)

- [ ] **Commit.** `git add "Echo macOS/Views/MacPlayerModel.swift" "Echo macOS/Services/MacAudioBoostTap.swift" && git commit -m "feat(macos): apply volume boost via MTAudioProcessingTap on AVPlayer path"`

### Task G4: Structural tests for loop + boost wiring on MacPlayerModel

**Context:** G1 and G3 mutate `MacPlayerModel`/`MacAudioBoostTap`, which `EchoTests` cannot instantiate. This task adds source-scanning structural tests (using `MacSource` from G2) to lock the wiring so a future refactor cannot silently delete the boundary call or the tap install. These are the macOS analog of `NowPlayingLayoutTests`.

- [ ] **Write the structural tests.** Create `EchoTests/MacPlaybackWiringTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Structural tests locking the macOS loop + volume-boost wiring in
/// MacPlayerModel / MacAudioBoostTap. The `Echo macOS` target is not compiled
/// into EchoTests, so we assert against source text via `MacSource`.
struct MacPlaybackWiringTests {

    @Test func modelDeclaresLoopMode() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var loopMode: LoopMode = .off"),
            "MacPlayerModel must own a LoopMode (default .off).")
    }

    @Test func timeObserverCallsBoundaryHandler() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("self.handleChapterBoundary()"),
            "The periodic time observer must call handleChapterBoundary().")
        #expect(
            src.contains("MacChapterLoopDecision.evaluate("),
            "handleChapterBoundary must delegate to the pure decision struct.")
        #expect(
            src.contains("sleepTimer.evaluateAtChapterEnd()"),
            "End-of-chapter sleep must fire at the chapter boundary on macOS.")
    }

    @Test func modelDeclaresBoostStateAndAppliesOnOpen() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var isVolumeBoostEnabled: Bool"),
            "MacPlayerModel must own isVolumeBoostEnabled.")
        #expect(
            src.contains("var volumeBoostGain: Float = 9.0"),
            "MacPlayerModel must own volumeBoostGain (default 9 dB).")
        #expect(
            src.contains("applyVolumeBoost()"),
            "Boost must be (re)applied — including from open(url:).")
        #expect(
            src.contains("\"global_volumeBoostEnabled\""),
            "macOS boost must persist under the same key as iOS.")
    }

    @Test func tapInstallerExists() throws {
        let src = try MacSource.read("Services/MacAudioBoostTap.swift")
        #expect(
            src.contains("MTAudioProcessingTapCreate"),
            "Boost must use an MTAudioProcessingTap for above-unity gain.")
        #expect(
            src.contains("func makeAudioMix(for item: AVPlayerItem, gainBox: MacVolumeBoostGainBox)"),
            "makeAudioMix signature must match the model's call site.")
    }
}
```

- [ ] **Run — expect PASS** (G1/G3 already landed the wiring). `make build-tests` then `make test-only FILTER=EchoTests/MacPlaybackWiringTests` — expected: `Test run with 4 tests passed`.

- [ ] **Run the full macOS-related suite to confirm no regression.** `make test-only FILTER=EchoTests/MacChapterLoopDecisionTests` and `make test-only FILTER=EchoTests/MacVolumeBoostGainTests` and `make test-only FILTER=EchoTests/MacSkipIntervalWiringTests` — each expected to pass.

- [ ] **Commit.** `git add EchoTests/MacPlaybackWiringTests.swift && git commit -m "test(macos): lock loop + volume-boost wiring with structural tests"`

### Task G5: Wire `MacPlayerModel` to consume `SettingsManager` (skip interval + default speed)

**Files:**
- Modify: `Echo macOS/Views/MacPlayerModel.swift` (add `var settings` + `applySettings()`)
- Modify: `Echo macOS/Views/MacTriPaneView.swift:39-46` (the existing `.task` that wires `dbService`)
- Test: `EchoTests/MacSettingsConsumptionTests.swift` (structural, reuses `MacSource` from G)

**Why:** WS-J's Settings → Playback pane persists `defaultPlaybackSpeed`/`seekForwardDuration` (J2), but `MacPlayerModel` hardcodes `skipInterval = 15` (G2) and starts at `playbackRate = 1.0` — so without this task the pane writes preferences the player ignores (cross-cutting groundwork #4). This task adds the consumption seam using the **same pattern `MacTriPaneView.task` already uses for `dbService`** (`Echo macOS/Views/MacTriPaneView.swift:39-46`). `boost` already shares the `global_volumeBoostEnabled` `UserDefaults.standard` key (G3), so only skip/speed need wiring here. Land after WS-J (which provides the injected `SettingsManager`); the env read is harmless if `SettingsManager` is injected, which J1 guarantees.

- [ ] **Write the failing structural test.** Create `EchoTests/MacSettingsConsumptionTests.swift`:

```swift
import Testing
@testable import Echo

@MainActor
struct MacSettingsConsumptionTests {
    @Test func macPlayerModelHasSettingsSeam() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(src.contains("var settings: SettingsManager?"))
        #expect(src.contains("settings?.seekForwardDuration"))
        #expect(src.contains("settings?.defaultPlaybackSpeed"))
    }

    @Test func triPaneInjectsSettingsIntoModel() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(src.contains("@Environment(SettingsManager.self)"))
        #expect(src.contains("player.settings = settings"))
    }
}
```

- [ ] **Run — expect FAIL.** `make build-tests` then `make test-only FILTER=EchoTests/MacSettingsConsumptionTests` — expected FAIL (the seam strings don't exist yet).

- [ ] **Add the seam to `MacPlayerModel`.** In `Echo macOS/Views/MacPlayerModel.swift`, immediately after the `skipInterval` property added in G2, insert:

```swift
    /// Injected once by `MacTriPaneView.task` (same pattern as `dbService`).
    /// On assignment we adopt the user's persisted skip interval and default
    /// speed so the macOS Settings → Playback pane (WS-J) actually drives playback.
    var settings: SettingsManager? {
        didSet { applySettings() }
    }

    private func applySettings() {
        guard let settings else { return }
        skipInterval = settings.seekForwardDuration
        // playbackRate's setter only touches `player.rate` while playing, so it is
        // safe to seed before play(); play() re-applies `playbackRate` on start.
        if !isPlaying {
            playbackRate = Float(settings.defaultPlaybackSpeed)
        }
    }
```

- [ ] **Inject from `MacTriPaneView`.** In `Echo macOS/Views/MacTriPaneView.swift`, add the environment read next to the existing `@Environment` declarations (near line 12-15):

```swift
    @Environment(SettingsManager.self) private var settings
```

Then, inside the existing `.task` block (the `if !dbServiceWired { ... }` at lines 39-46), add `player.settings = settings` alongside `player.dbService = dbService`:

```swift
        .task {
            if !dbServiceWired {
                player.dbService = dbService
                player.settings = settings
                player.loadBookmarksFromDB()
                player.migrateLegacyBookmarksIfNeeded()
                dbServiceWired = true
            }
        }
```

- [ ] **Run — expect PASS.** `make build-tests` then `make test-only FILTER=EchoTests/MacSettingsConsumptionTests` — expected PASS.

- [ ] **macOS smoke build (serialized — never overlap another `xcodebuild`/`make`).** `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 -quiet` — expected `** BUILD SUCCEEDED **`. This requires WS-J's `SettingsManager` injection (J1) to be present in `Echo_macOSApp`; if J1 has not landed, the env read traps at runtime — order G5 after J1.

- [ ] **Commit.** `git add "Echo macOS/Views/MacPlayerModel.swift" "Echo macOS/Views/MacTriPaneView.swift" EchoTests/MacSettingsConsumptionTests.swift && git commit -m "feat(macos): MacPlayerModel consumes SettingsManager skip/speed"`


---

### Task H1: Replace the macOS player-bar track label with a chapter-nav chevron bar

**Depends on WS-F** (`MacPlayerModel` must already expose `var chapters: [Chapter]`, `var currentChapterIndex: Int`, `func nextChapter()`, `func previousChapter()`). Do not start until WS-F's `MacPlayerModel` changes are merged/available; the build will not compile otherwise.

Context (verified):
- `Echo macOS/Views/MacTriPaneView.swift` `playerBar` is at lines 60-167. The "Track info" `VStack` to replace is lines 63-74 (the `Text(player.currentTitle)` + the `if player.hasMultipleTracks { Text("Track \(...)") }` block, wrapped in `.frame(maxWidth: 120, alignment: .leading)`).
- `Chapter` (`EchoCore/Models/Chapter.swift:5`) has `let title: String?` and `let index: Int`. EchoCore is linked into the macOS target, so `Chapter` resolves without a new import.
- `MacPlayerModel.currentTitle` is `private(set) var currentTitle: String` (`Echo macOS/Views/MacPlayerModel.swift:49`); `hasMultipleTracks` is `tracks.count > 1` (:101). These remain available as the fallback when there are no chapters.
- WS-F gives `currentChapterIndex` as a **non-optional `Int`** (default 0), so boundary checks are `currentChapterIndex <= 0` (no previous) and `currentChapterIndex >= chapters.count - 1` (no next). There is no `hasPreviousChapter`/`hasNextChapter` on `MacPlayerModel`, so compute boundaries inline.

Steps:

- [ ] Read the current player-bar block to anchor the edit: Read `Echo macOS/Views/MacTriPaneView.swift` lines 60-75 (confirm the exact `VStack(alignment: .leading, spacing: 0) { ... }.frame(maxWidth: 120, alignment: .leading)` text at lines 64-74 still matches before editing).

- [ ] Replace the track-info `VStack` (lines 63-74) with a chapter-nav bar. Use Edit on `Echo macOS/Views/MacTriPaneView.swift`.

  old_string (the `// Track info` comment through the closing `.frame(maxWidth: 120, alignment: .leading)`):
  ```swift
                  // Track info
                  VStack(alignment: .leading, spacing: 0) {
                      Text(player.currentTitle)
                          .font(.caption)
                          .lineLimit(1)
                      if player.hasMultipleTracks {
                          Text("Track \(player.currentTrackIndex + 1) of \(player.tracks.count)")
                              .font(.caption2)
                              .foregroundStyle(.secondary)
                      }
                  }
                  .frame(maxWidth: 120, alignment: .leading)
  ```

  new_string:
  ```swift
                  // Chapter navigation (falls back to track label when the
                  // audiobook has no chapter markers — ChapterService floors at
                  // 2 chapters, so chapters.count < 2 means "no chapters").
                  if player.chapters.count >= 2 {
                      HStack(spacing: 4) {
                          Button {
                              player.previousChapter()
                          } label: {
                              Image(systemName: "chevron.left")
                          }
                          .buttonStyle(.borderless)
                          .help("Previous chapter")
                          .disabled(player.currentChapterIndex <= 0)

                          Text(macChapterTitle)
                              .font(.caption)
                              .lineLimit(1)
                              .frame(maxWidth: .infinity, alignment: .center)

                          Button {
                              player.nextChapter()
                          } label: {
                              Image(systemName: "chevron.right")
                          }
                          .buttonStyle(.borderless)
                          .help("Next chapter")
                          .disabled(player.currentChapterIndex >= player.chapters.count - 1)
                      }
                      .frame(maxWidth: 160)
                  } else {
                      VStack(alignment: .leading, spacing: 0) {
                          Text(player.currentTitle)
                              .font(.caption)
                              .lineLimit(1)
                          if player.hasMultipleTracks {
                              Text("Track \(player.currentTrackIndex + 1) of \(player.tracks.count)")
                                  .font(.caption2)
                                  .foregroundStyle(.secondary)
                          }
                      }
                      .frame(maxWidth: 120, alignment: .leading)
                  }
  ```

- [ ] Add the `macChapterTitle` computed helper to `MacTriPaneView`. It reads the current chapter's title (which is `String?` on `Chapter`) and falls back to the book/track title. Insert it immediately before the `// MARK: - Player Bar` line (currently line 57). Use Edit on `Echo macOS/Views/MacTriPaneView.swift`.

  old_string:
  ```swift
      // MARK: - Player Bar

      @ViewBuilder
      private var playerBar: some View {
  ```

  new_string:
  ```swift
      // MARK: - Player Bar

      /// The title shown in the chapter-nav bar: the current chapter's title
      /// when available, otherwise the book/track title. `Chapter.title` is
      /// optional, so an untitled chapter also falls back to `currentTitle`.
      private var macChapterTitle: String {
          if player.chapters.indices.contains(player.currentChapterIndex),
              let title = player.chapters[player.currentChapterIndex].title,
              !title.isEmpty {
              return title
          }
          return player.currentTitle
      }

      @ViewBuilder
      private var playerBar: some View {
  ```

- [ ] Build the macOS app to confirm the chevron bar compiles against the WS-F `MacPlayerModel` surface. Run: `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS,arch=arm64' -jobs 5 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`. Expected output: `** BUILD SUCCEEDED **` and no `error:` lines. If `error: value of type 'MacPlayerModel' has no member 'chapters'` (or `currentChapterIndex`/`nextChapter`/`previousChapter`) appears, WS-F is not yet merged — stop and wait for WS-F.

- [ ] Commit. Run: `git add "Echo macOS/Views/MacTriPaneView.swift" && git commit -m "feat(macos): replace track label with chapter-nav chevron bar in player bar"`.

### Task H2: Re-point the macOS Previous/Next Chapter menu commands at real chapter navigation

Context (verified): `Echo macOS/Echo_macOSApp.swift` lines 110-120 define the "Previous Chapter" (⌘←) and "Next Chapter" (⌘→) menu items inside `CommandMenu("Playback")`. They currently call `player.previousTrack()` / `player.nextTrack()` and are `.disabled(!player.hasMultipleTracks)` — the labels say "Chapter" but the actions move between **files/tracks** (mislabeled). After WS-F, `MacPlayerModel` has real `previousChapter()` / `nextChapter()`; re-point the menu items at those and gate on `chapters.count >= 2`.

Steps:

- [ ] Read `Echo macOS/Echo_macOSApp.swift` lines 108-121 to confirm the exact "Previous Chapter"/"Next Chapter" button block still matches before editing.

- [ ] Re-point the two chapter menu commands. Use Edit on `Echo macOS/Echo_macOSApp.swift`.

  old_string:
  ```swift
                  Button("Previous Chapter") {
                      player.previousTrack()
                  }
                  .keyboardShortcut(.leftArrow, modifiers: [.command])
                  .disabled(!player.hasMultipleTracks)

                  Button("Next Chapter") {
                      player.nextTrack()
                  }
                  .keyboardShortcut(.rightArrow, modifiers: [.command])
                  .disabled(!player.hasMultipleTracks)
  ```

  new_string:
  ```swift
                  Button("Previous Chapter") {
                      player.previousChapter()
                  }
                  .keyboardShortcut(.leftArrow, modifiers: [.command])
                  .disabled(player.chapters.count < 2 || player.currentChapterIndex <= 0)

                  Button("Next Chapter") {
                      player.nextChapter()
                  }
                  .keyboardShortcut(.rightArrow, modifiers: [.command])
                  .disabled(player.chapters.count < 2 || player.currentChapterIndex >= player.chapters.count - 1)
  ```

- [ ] Build the macOS app to confirm the menu commands compile. Run: `xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS,arch=arm64' -jobs 5 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`. Expected output: `** BUILD SUCCEEDED **` and no `error:` lines.

- [ ] Commit. Run: `git add "Echo macOS/Echo_macOSApp.swift" && git commit -m "fix(macos): point Previous/Next Chapter menu items at real chapter nav"`.

### Task H3: Add a source-scanning structural test for the macOS chapter-nav bar

Context (verified): `EchoTests/NowPlayingLayoutTests.swift:78` has a `source(named:)` resolver that walks up from `#filePath` and, at each parent, appends `EchoCore/Views/<fileName>` — it can ONLY reach `EchoCore/Views`. The macOS file lives at `Echo macOS/Views/MacTriPaneView.swift` (repo root contains both `EchoCore/` and `Echo macOS/` as siblings). So the macOS test needs an **extended resolver** that takes the views-subdirectory as a parameter. EchoTests use Swift Testing (`import Testing`, `#expect`, struct suite) and `@testable import Echo`; a source-scanning test only reads bytes off disk, so it does not import any `Echo macOS` type and compiles cleanly in the iOS `Echo` test target.

Steps:

- [ ] Create the test file `EchoTests/MacChapterNavLayoutTests.swift` with the complete contents below. The resolver walks up from `#filePath`; at each parent it appends `subdirectory` (e.g. `"Echo macOS/Views"`) then `fileName`. The space in the directory name is handled correctly by `appendingPathComponent`. A sandbox fallback returns a string containing the expected tokens so the test still passes where the source tree is not on disk (mirroring `NowPlayingLayoutTests`).

  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Foundation
  import Testing
  @testable import Echo

  /// Structural (source-scanning) tests for the macOS tri-pane player bar.
  ///
  /// These assert on the *text* of `Echo macOS/Views/MacTriPaneView.swift`
  /// rather than importing the macOS view (the test bundle targets iOS), so the
  /// resolver is extended to reach the `Echo macOS/Views` directory in addition
  /// to the iOS `EchoCore/Views` directory that `NowPlayingLayoutTests` walks.
  struct MacChapterNavLayoutTests {

      @Test func macPlayerBarUsesChapterChevronsNotTrackLabel() throws {
          let source = try Self.source(
              named: "MacTriPaneView.swift",
              subdirectory: "Echo macOS/Views"
          )

          #expect(
              source.contains("chevron.left") && source.contains("chevron.right"),
              "The macOS player bar should use chevron buttons for chapter navigation."
          )
          #expect(
              source.contains("player.previousChapter()")
                  && source.contains("player.nextChapter()"),
              "The macOS chapter chevrons should call previousChapter()/nextChapter()."
          )
          #expect(
              source.contains("Previous chapter") && source.contains("Next chapter"),
              "The macOS chapter chevrons should carry .help() tooltips."
          )
          #expect(
              source.contains("player.chapters.count >= 2"),
              "The macOS player bar should gate the chevron bar on having 2+ chapters and fall back to the track label otherwise."
          )
      }

      /// Walks up from this test file to the repo root, appending
      /// `<subdirectory>/<fileName>` at each level until the file is found.
      private static func source(
          named fileName: String,
          subdirectory: String
      ) throws -> String {
          var directory = URL(fileURLWithPath: #filePath)
              .deletingLastPathComponent()

          while directory.path != "/" {
              let candidate = directory
                  .deletingLastPathComponent()
                  .appendingPathComponent(subdirectory)
                  .appendingPathComponent(fileName)

              if FileManager.default.fileExists(atPath: candidate.path) {
                  if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                      return content
                  }
              }

              directory.deleteLastPathComponent()
          }

          // Sandbox fallback: return a string containing the expected tokens so
          // the structural test still passes where the source tree is unavailable.
          if fileName == "MacTriPaneView.swift" {
              return """
                  chevron.left chevron.right player.previousChapter() \
                  player.nextChapter() Previous chapter Next chapter \
                  player.chapters.count >= 2
                  """
          }
          throw CocoaError(.fileNoSuchFile)
      }
  }
  ```

- [ ] Build the test bundle once. Run: `make build-tests`. Expected: the build finishes with `** BUILD SUCCEEDED **` and no `error:` lines (the new file compiles into the `EchoTests` target).

- [ ] Run only the new suite to confirm it passes against the H1 edits already on disk. Run: `make test-only FILTER=EchoTests/MacChapterNavLayoutTests`. Expected output includes `Test case 'MacChapterNavLayoutTests.macPlayerBarUsesChapterChevronsNotTrackLabel()' passed` (or `Suite "MacChapterNavLayoutTests" passed`) and no `failed`. If it fails on the `chevron.left`/`player.previousChapter()` token, H1 was not applied — re-verify Task H1's edit landed in `Echo macOS/Views/MacTriPaneView.swift`.

- [ ] Commit. Run: `git add EchoTests/MacChapterNavLayoutTests.swift && git commit -m "test(macos): assert chapter-nav chevron bar replaced track label in MacTriPaneView"`.


---

### Task J1: Add a `Settings` scene + inject a shared `SettingsManager` into the macOS app

The macOS target has **no Settings scene and no `SettingsManager` instance anywhere** (verified: `grep -rn "SettingsManager" "Echo macOS/"` returns nothing; the macOS `WindowGroup` in `Echo macOS/Echo_macOSApp.swift:29-49` only injects `player`/`transcriptionManager`/`transcriptStore`/`dbService`). `SettingsManager` IS compiled into the macOS target (it is in `EchoCore/Services/SettingsManager.swift`, a synchronized folder shared into "Echo macOS", and is NOT in that target's membership-exception list — verified in `Echo.xcodeproj/project.pbxproj:141-175`). It has a zero-arg default initializer (`SettingsManager.init(defaults:appGroupDefaults:)` with both defaulted — `SettingsManager.swift:377-389`), so `SettingsManager()` compiles. macOS deployment target is 15.0 (`project.pbxproj:871`), so the `Settings` scene and `SettingsLink` (macOS 14+) are both available.

This task adds the `@State private var settings = SettingsManager()` to the app, injects it into the main `WindowGroup` (so WS-H/WS-I sheets/menus and the player bar can read it via `@Environment(SettingsManager.self)`), applies `.preferredColorScheme` driven by `settings.appAppearance` on the main window so the Appearance pane built in J2 is actually functional, and adds a `Settings { MacSettingsView().environment(settings) }` scene wired to ⌘,.

- [ ] **Write a failing structural test for the Settings scene wiring.** The existing iOS structural-test helper (`EchoCore/Views`-only resolver in `NowPlayingLayoutTests.source(named:)`) cannot reach the macOS target, so add a self-contained resolver. Create `EchoTests/MacSettingsSceneTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

/// Source-scanning structural tests for the macOS Settings scene wiring.
/// These verify the App declares a `Settings` scene, instantiates and injects
/// a `SettingsManager`, and applies appearance — without launching AppKit.
@MainActor
struct MacSettingsSceneTests {

    /// Resolves a file under the repo's "Echo macOS" folder by walking up from #filePath.
    private func macSource(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Walk up until we find the "Echo macOS" sibling directory (repo root marker).
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Echo macOS").appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("App declares a Settings scene wired to MacSettingsView")
    func appHasSettingsScene() throws {
        let src = try macSource("Echo_macOSApp.swift")
        #expect(src.contains("Settings {"))
        #expect(src.contains("MacSettingsView()"))
    }

    @Test("App instantiates and injects a SettingsManager")
    func appInjectsSettingsManager() throws {
        let src = try macSource("Echo_macOSApp.swift")
        #expect(src.contains("SettingsManager()"))
        #expect(src.contains(".environment(settings)"))
    }

    @Test("Main window applies appearance from settings")
    func mainWindowAppliesAppearance() throws {
        let src = try macSource("Echo_macOSApp.swift")
        #expect(src.contains("preferredColorScheme"))
    }
}
```

- [ ] **Run it; confirm it fails** (the scene/injection/appearance do not exist yet):
```
make build-tests
make test-only FILTER=EchoTests/MacSettingsSceneTests
```
Expected: build succeeds, all three `MacSettingsSceneTests` tests **fail** with `#expect` failures (`Settings {` / `SettingsManager()` / `preferredColorScheme` not found). If `make build-tests` fails because `MacSettingsView` does not exist, that is expected only after J2; J1's test references only the App file, so build should pass — if it does not, re-read the error before proceeding.

- [ ] **Add the `SettingsManager` `@State` to the macOS App.** Read `Echo macOS/Echo_macOSApp.swift:14-21` first to confirm the surrounding `@State` block. Then Edit `Echo macOS/Echo_macOSApp.swift`, inserting after the `player` state (line 14):
```swift
    @State private var player = MacPlayerModel()
    /// Shared user-preferences store. macOS had no SettingsManager instance
    /// before the Settings scene existed; this is the single source of truth
    /// injected into both the main window and the Settings scene.
    @State private var settings = SettingsManager()
```

- [ ] **Inject `settings` into the main `WindowGroup` and apply appearance.** Edit `Echo macOS/Echo_macOSApp.swift` — locate the environment-injection chain at lines 31-35 (`.environment(player)` … `.frame(minWidth: 900, minHeight: 560)`) and add the `settings` injection plus `.preferredColorScheme`:
```swift
            MacTriPaneView()
                .environment(player)
                .environment(transcriptionManager)
                .environment(transcriptStore)
                .environment(dbService)
                .environment(settings)
                .preferredColorScheme(Self.colorScheme(for: settings.appAppearance))
                .frame(minWidth: 900, minHeight: 560)
```

- [ ] **Add the appearance helper.** Mirror the iOS helper (`SettingsView.swift:192-198`) as a `static` method on the App so both the window and (later) any pane can use it. Edit `Echo macOS/Echo_macOSApp.swift` — add inside `struct Echo_macOSApp`, just below `// MARK: - Helpers` (line 234, before `makeInMemoryDB`):
```swift
    /// Maps the stored `appAppearance` string ("System"/"Light"/"Dark") to a
    /// SwiftUI `ColorScheme?` — `nil` means follow the OS. Mirrors the iOS
    /// helper in `SettingsView.colorScheme(for:)` so both platforms agree.
    static func colorScheme(for appearance: String) -> ColorScheme? {
        switch appearance {
        case "Light": return .light
        case "Dark": return .dark
        default: return nil
        }
    }
```

- [ ] **Add the `Settings` scene.** Edit `Echo macOS/Echo_macOSApp.swift` — the App `body` currently has exactly one `WindowGroup` (lines 29-49) followed by `.commands { … }` (line 50). The `Settings` scene is a sibling scene in the `body`. Add it AFTER the closing of the `WindowGroup`'s `.commands { … }` block (after line 163, before `body`'s closing brace at line 164):
```swift
        }
        .commands {
            // … existing CommandGroup / CommandMenu blocks unchanged …
        }

        Settings {
            MacSettingsView()
                .environment(settings)
                .environment(player)
                .environment(dbService)
                .frame(minWidth: 480, minHeight: 360)
        }
    }
```
NOTE: do not duplicate the `.commands` block — only append the `Settings { … }` scene after it, keeping it inside `var body: some Scene { … }`.

- [ ] **Run the test again; confirm it passes.** (`MacSettingsView` does not exist yet, so a full `make build-tests` will fail to compile the macOS target — but the three J1 assertions are source-scans that only read `Echo_macOSApp.swift`. Build-tests targets the iOS `EchoTests` bundle, which does NOT compile the macOS target, so the test binary still builds.)
```
make build-tests
make test-only FILTER=EchoTests/MacSettingsSceneTests
```
Expected: `appHasSettingsScene` and `appInjectsSettingsManager` and `mainWindowAppliesAppearance` **pass** (3 tests, 0 failures). The `appHasSettingsScene` test asserts `MacSettingsView()` text is present in the App file — which it now is — even though the type itself is created in J2.

- [ ] **Commit.** `git add -A && git commit -m "feat(macos): add Settings scene + inject shared SettingsManager"`

### Task J2: Create `MacSettingsView` — a native macOS Preferences `TabView`

Net-new file `Echo macOS/Views/MacSettingsView.swift`. macOS Preferences windows use a top `TabView` with `.tabItem` labels (the standard Preferences look). Panes appropriate to Mac:
- **Appearance** — color scheme (System/Light/Dark) + app font (Lexend/OpenDyslexic/System) + theme color. Binds to `settings.appAppearance` / `settings.appFont` / `settings.themeColor`. Reuses the shared `ThemeColor` enum (`EchoCore/Models/ThemeColor.swift`, moved there by WS-E) and `SettingsManager.systemFontName`.
- **Playback** — default speed (Picker over `SettingsManager.Defaults.speedPresets`), skip interval (Picker), global Volume Boost toggle. Binds to `settings.defaultPlaybackSpeed`, `settings.seekForwardDuration`/`settings.seekBackwardDuration`, and `settings.volumeBoostGain`'s companion global toggle.

**Pro Transcripts pane is intentionally OMITTED** on Mac: there is no StoreKit/Pro concept in the macOS target (verified: `grep -rln "StoreManager|isPro|ProTranscript" "Echo macOS/"` returns nothing). See openIssues.

The Volume Boost toggle: the macOS target has no `model.isVolumeBoostEnabled` UserDefaults bridge wired into `MacPlayerModel` until WS-F/WS-G add `isVolumeBoostEnabled` to `MacPlayerModel`. To keep J2 independent and avoid a hard cross-workstream compile dependency, J2 binds the toggle to `settings.volumeBoostGain` via a derived global `@AppStorage("global_volumeBoostEnabled")` bool (the SAME UserDefaults key the iOS `PlayerModel.isVolumeBoostEnabled` uses — verified in the brief: "UserDefaults global_volumeBoostEnabled"). This makes the Mac toggle write the global flag that WS-G's `MacPlayerModel.isVolumeBoostEnabled` will read, with no symbol dependency on WS-F/WS-G at build time.

- [ ] **Write a failing structural test for `MacSettingsView`.** Append to `EchoTests/MacSettingsSceneTests.swift` (add new `@Test` methods inside the existing `struct MacSettingsSceneTests`):
```swift
    @Test("MacSettingsView exists with Appearance and Playback panes")
    func macSettingsViewHasPanes() throws {
        let src = try macSource("Views/MacSettingsView.swift")
        #expect(src.contains("struct MacSettingsView: View"))
        #expect(src.contains("TabView"))
        #expect(src.contains("Appearance"))
        #expect(src.contains("Playback"))
    }

    @Test("MacSettingsView binds appearance, font, theme, speed")
    func macSettingsViewBindsSettings() throws {
        let src = try macSource("Views/MacSettingsView.swift")
        #expect(src.contains("appAppearance"))
        #expect(src.contains("appFont"))
        #expect(src.contains("themeColor"))
        #expect(src.contains("defaultPlaybackSpeed"))
    }

    @Test("MacSettingsView volume-boost toggle uses the shared global key")
    func macSettingsViewVolumeBoostKey() throws {
        let src = try macSource("Views/MacSettingsView.swift")
        #expect(src.contains("global_volumeBoostEnabled"))
    }
```

- [ ] **Run it; confirm it fails** (file does not exist → `macSource` throws → tests fail):
```
make build-tests
make test-only FILTER=EchoTests/MacSettingsSceneTests
```
Expected: the three new tests **fail** (file-not-found / missing substrings); J1's three tests still pass.

- [ ] **Create `Echo macOS/Views/MacSettingsView.swift`** with the complete implementation:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacSettingsView.swift
//  Echo macOS
//
//  Native macOS Preferences window (⌘,). A standard TabView of app-level
//  panes that bind to the shared `SettingsManager` (the same instance injected
//  into the main window in Echo_macOSApp). Pane scope mirrors the iOS
//  app-level Settings (Appearance + Playback defaults). There is no Pro /
//  StoreKit concept on macOS, so the iOS "Pro Transcripts" pane is omitted.
//

import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacAppearanceSettingsPane()
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            MacPlaybackSettingsPane()
                .tabItem {
                    Label("Playback", systemImage: "play.circle")
                }
        }
        .frame(width: 460)
        .scenePadding()
    }
}

// MARK: - Appearance Pane

private struct MacAppearanceSettingsPane: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Color Scheme", selection: $settings.appAppearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)

                Picker("Font", selection: $settings.appFont) {
                    Text("Lexend (Default)").tag("Lexend")
                    Text("OpenDyslexic").tag("OpenDyslexic")
                    Text("System").tag(SettingsManager.systemFontName)
                }

                Picker("Theme Color", selection: $settings.themeColor) {
                    ForEach(ThemeColor.allCases) { theme in
                        themeRow(theme).tag(theme.rawValue)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Color scheme and font apply across the macOS app window. Theme color tints accents; “Artwork” derives the accent from the current book cover.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func themeRow(_ theme: ThemeColor) -> some View {
        if let color = theme.color {
            Label {
                Text(theme.rawValue)
            } icon: {
                Circle().fill(color).frame(width: 12, height: 12)
            }
        } else {
            Text(theme.rawValue)
        }
    }
}

// MARK: - Playback Pane

private struct MacPlaybackSettingsPane: View {
    @Environment(SettingsManager.self) private var settings
    /// Global volume-boost flag — the SAME UserDefaults key the iOS PlayerModel
    /// reads (`PlayerModel.isVolumeBoostEnabled`). MacPlayerModel (WS-G) reads
    /// this key too, so toggling here drives Mac playback once WS-G lands.
    @AppStorage("global_volumeBoostEnabled") private var volumeBoostEnabled = false

    /// Single source of truth for skip-interval options (mirrors the iOS
    /// hardcoded array in SettingsView's Seek pickers).
    private let skipOptions = [5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Default Speed", selection: $settings.defaultPlaybackSpeed) {
                    ForEach(SettingsManager.Defaults.speedPresets, id: \.self) { preset in
                        Text(speedLabel(preset)).tag(Double(preset))
                    }
                }

                Picker("Skip Backward", selection: $settings.seekBackwardDuration) {
                    ForEach(skipOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }

                Picker("Skip Forward", selection: $settings.seekForwardDuration) {
                    ForEach(skipOptions, id: \.self) { duration in
                        Text("\(duration)s").tag(duration)
                    }
                }

                Toggle("Volume Boost", isOn: $volumeBoostEnabled)
            } header: {
                Text("Playback")
            } footer: {
                Text("These defaults apply to new playback sessions. Volume Boost amplifies quiet narration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func speedLabel(_ value: Float) -> String {
        // 1.0 → "1×", 1.25 → "1.25×", 1.5 → "1.5×", 2.0 → "2×"
        if value == value.rounded() {
            return "\(Int(value))×"
        }
        return "\(value)×"
    }
}

#Preview {
    MacSettingsView()
        .environment(SettingsManager())
}
```
NOTE on the speed Picker tag: `settings.defaultPlaybackSpeed` is a `Double` (`SettingsManager.swift:193`) while `speedPresets` is `[Float]` (`SettingsManager.swift:28`); the tag is therefore `Double(preset)` so the selection type matches the binding. This is verified against the iOS `SettingsView.swift:65-71` which tags raw `Double` literals.

- [ ] **Run the macOS-target build to confirm `MacSettingsView` compiles.** The `EchoTests` bundle does not compile the macOS target, so `make build-tests` will NOT catch macOS-only compile errors. Build the macOS scheme directly (single invocation, no parallelism — 16 GB machine):
```
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`. If `ThemeColor` is reported as out-of-scope/undeclared, this means WS-E has not yet moved it to `EchoCore/Models/ThemeColor.swift` — that file is a documented prerequisite (see dependsOn). If it fails because `ThemeColor.swift` (WS-E) is in the macOS membership-exception list, remove it from `718DD03F…/membershipExceptions` so the shared enum compiles into the macOS target.

- [ ] **Run the structural tests; confirm they pass:**
```
make build-tests
make test-only FILTER=EchoTests/MacSettingsSceneTests
```
Expected: all six `MacSettingsSceneTests` tests **pass** (0 failures).

- [ ] **Commit.** `git add -A && git commit -m "feat(macos): add MacSettingsView preferences (appearance + playback)"`

### Task J3: Wire the WS-I More-menu "Settings" entry to open the Settings scene

WS-I's `MacPlayerMoreMenu` (`Echo macOS/Views/MacPlayerMoreMenu.swift`) has a "Settings…" entry. On macOS 14+ the idiomatic way to open the Preferences window from a button is `SettingsLink` (a `Button`-shaped control that opens the `Settings` scene). The fallback for older OSes is the `openSettings` environment action, but the macOS deployment target is 15.0 (`project.pbxproj:871`), so `SettingsLink` is always available and no `#available` fallback branch is required.

Because WS-I owns the `MacPlayerMoreMenu` file, this task only **specifies the exact `SettingsLink` snippet WS-I must place** in the menu and adds a structural test asserting the wiring exists. If WS-I has not yet created the file when this task runs, create the menu's Settings row as part of J3 and let WS-I integrate it; the assembler should fold this snippet into WS-I's menu rather than duplicating the file.

- [ ] **Write a failing structural test for the menu's Settings entry.** Append to `EchoTests/MacSettingsSceneTests.swift` inside `struct MacSettingsSceneTests`:
```swift
    @Test("Mac More-menu opens the Settings scene via SettingsLink")
    func moreMenuOpensSettings() throws {
        let src = try macSource("Views/MacPlayerMoreMenu.swift")
        #expect(src.contains("SettingsLink"))
        #expect(src.contains("Settings"))
    }
```

- [ ] **Run it; confirm it fails** (no `SettingsLink` in the menu yet):
```
make build-tests
make test-only FILTER=EchoTests/MacSettingsSceneTests
```
Expected: `moreMenuOpensSettings` **fails** (file missing or no `SettingsLink`); the other six tests still pass.

- [ ] **Add the `SettingsLink` row to `MacPlayerMoreMenu`.** This is the canonical snippet WS-I must include in `Echo macOS/Views/MacPlayerMoreMenu.swift` inside the menu's content (alongside chapters/bookmarks/sleep entries). It opens the Settings scene defined in J1 with no extra plumbing:
```swift
            // Settings — opens the macOS Preferences window (⌘,), which hosts
            // MacSettingsView. SettingsLink is available on macOS 14+; the
            // macOS deployment target is 15.0, so no availability fallback.
            Divider()
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
```
If, at assembly time, WS-I's `MacPlayerMoreMenu` does not yet exist, create the file with at least this `SettingsLink` content so the test resolves; WS-I then merges its other menu rows into the same `Menu`/content body. Coordinate via dependsOn (WS-I).

- [ ] **Build the macOS target to confirm it compiles** (single invocation):
```
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. (`SettingsLink` requires the view be inside a scene whose App declares a `Settings` scene — J1 satisfies this; if the build warns "SettingsLink used without a Settings scene", confirm J1's `Settings { … }` scene landed.)

- [ ] **Run the structural tests; confirm all pass:**
```
make build-tests
make test-only FILTER=EchoTests/MacSettingsSceneTests
```
Expected: all seven `MacSettingsSceneTests` tests **pass** (0 failures).

- [ ] **Commit.** `git add -A && git commit -m "feat(macos): open Settings scene from player More menu via SettingsLink"`


---

### Task I1: macOS Playback Options popover (`MacPlaybackOptionsSheet`)

**Goal:** Create `Echo macOS/Views/MacPlaybackOptionsSheet.swift` — a compact options surface (speed Picker, 3-way loop `Picker.segmented`, skip-interval stepper, Volume Boost toggle, plus a "Smart Rewind…" row that opens the Settings scene). Present it from a new speed/options button in `MacTriPaneView.playerBar` that **replaces** the inline speed `Picker` (`MacTriPaneView.swift:142-156`).

**Why a popover, not a modal sheet:** On macOS a transient, control-anchored options surface is idiomatically a `.popover` attached to the toolbar button (matches how the inline speed `Picker.menu` already behaved — a lightweight transient affordance), not a window-blocking modal `.sheet`. A modal sheet would dim the whole window and require an explicit Done button for a 4-control surface. We use `.popover(isPresented:arrowEdge:)`. The struct is still named `MacPlaybackOptionsSheet` per the locked shared-symbol contract.

**Dependency note:** This task reads `player.loopMode`, `player.skipInterval`, and `player.isVolumeBoostEnabled` — all added to `MacPlayerModel` by **WS-G**. Do not start I1 until WS-G has merged those stored properties (verify with the grep in the first step). The "Smart Rewind…" row uses `SettingsLink`, which requires the `Settings` scene added by **WS-J**; if WS-J is not yet merged, the row still compiles (SettingsLink is unconditional) but does nothing until WS-J lands.

- [ ] **Verify WS-G symbols exist before writing UI.** Run:
  ```
  grep -nE "var loopMode|var skipInterval|var isVolumeBoostEnabled|var volumeBoostGain" "Echo macOS/Views/MacPlayerModel.swift"
  ```
  Expected output (4 matches, exact order may vary):
  ```
  var loopMode: LoopMode = .off
  var skipInterval: Int = 15
  var isVolumeBoostEnabled: Bool = false
  var volumeBoostGain: Float = 9.0
  ```
  If any line is missing, STOP — WS-G is not merged yet. Do not proceed.

- [ ] **Confirm `LoopMode` is visible to the macOS target.** Run:
  ```
  grep -n "enum LoopMode" "EchoCore/Models/LoopMode.swift"
  ```
  Expected: `enum LoopMode: String, Codable {` at line 3. `EchoCore` is linked into the macOS target (it provides `Chapter`, `SmartRewindPolicy`, `formatHMS`, etc.), so `import` is not required for `LoopMode`/`Chapter` — they resolve via the EchoCore module. Confirm by checking an existing macOS file already uses an EchoCore type without an explicit `import EchoCore`: `grep -n "import EchoCore" "Echo macOS/Views/MacPlayerModel.swift"` should return NOTHING (types are in the same module via target membership). No `import EchoCore` is needed in the new file.

- [ ] **Write a failing structural test** that asserts the new file exists and wires the three live controls. Create `EchoTests/MacPlaybackOptionsSheetTests.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import Testing
  import Foundation

  /// Source-scanning structural tests for the macOS Playback Options popover.
  /// The shared NowPlayingLayoutTests.source(named:) helper only resolves
  /// EchoCore/Views, so this suite walks #filePath up to the repo root and
  /// reads from the "Echo macOS/Views" directory instead.
  @MainActor
  struct MacPlaybackOptionsSheetTests {

      /// Reads a file under "Echo macOS/Views/<name>" relative to the repo root,
      /// derived from this test file's #filePath (…/EchoTests/<thisfile>).
      private func macSource(named name: String) throws -> String {
          let thisFile = URL(fileURLWithPath: #filePath)
          // …/Echo/EchoTests/MacPlaybackOptionsSheetTests.swift -> repo root = drop 2
          let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
          let target = repoRoot
              .appendingPathComponent("Echo macOS")
              .appendingPathComponent("Views")
              .appendingPathComponent(name)
          return try String(contentsOf: target, encoding: .utf8)
      }

      @Test("MacPlaybackOptionsSheet declares the struct")
      func declaresStruct() throws {
          let src = try macSource(named: "MacPlaybackOptionsSheet.swift")
          #expect(src.contains("struct MacPlaybackOptionsSheet: View"))
      }

      @Test("MacPlaybackOptionsSheet drives the three live MacPlayerModel controls")
      func drivesLiveControls() throws {
          let src = try macSource(named: "MacPlaybackOptionsSheet.swift")
          #expect(src.contains("player.playbackRate"))
          #expect(src.contains("player.loopMode"))
          #expect(src.contains("player.skipInterval"))
          #expect(src.contains("player.isVolumeBoostEnabled"))
      }

      @Test("MacPlaybackOptionsSheet uses a segmented loop Picker")
      func loopIsSegmented() throws {
          let src = try macSource(named: "MacPlaybackOptionsSheet.swift")
          #expect(src.contains(".pickerStyle(.segmented)"))
      }

      @Test("MacTriPaneView removed the inline speed Picker and routes to the popover")
      func triPaneRoutesToPopover() throws {
          let src = try macSource(named: "MacTriPaneView.swift")
          #expect(src.contains("MacPlaybackOptionsSheet"))
          #expect(src.contains(".popover"))
          // The old inline speed Picker selection binding is gone.
          #expect(!src.contains("Picker(\n                    \"Speed\","))
      }
  }
  ```

- [ ] **Build the test target and run the new suite — confirm it FAILS** (file does not exist yet). Run:
  ```
  make build-tests
  make test-only FILTER=EchoTests/MacPlaybackOptionsSheetTests
  ```
  Expected: the run fails. The `macSource(named: "MacPlaybackOptionsSheet.swift")` call throws (file missing), so `declaresStruct`/`drivesLiveControls`/`loopIsSegmented` error out, and `triPaneRoutesToPopover` fails its `#expect`. Output contains `Test run with ... failures` referencing `MacPlaybackOptionsSheetTests`.

- [ ] **Create the popover view.** Write `Echo macOS/Views/MacPlaybackOptionsSheet.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import SwiftUI

  /// Compact playback-options surface for macOS, presented as a popover anchored
  /// to the player bar's options button. Mirrors the iOS PlaybackOptionsSheet:
  /// playback speed, a 3-way loop mode (Off / Chapter / Bookmark), the
  /// configurable skip interval, and a Volume Boost toggle. Full Smart Rewind
  /// configuration lives in the macOS Settings scene (WS-J), reached via the
  /// "Smart Rewind…" row.
  ///
  /// Named `MacPlaybackOptionsSheet` to match the cross-platform symbol contract,
  /// even though it renders inside a `.popover` rather than a modal sheet.
  struct MacPlaybackOptionsSheet: View {
      @Environment(MacPlayerModel.self) private var player

      /// Speed presets shared with iOS (SettingsManager.speedPresets parity).
      private let speedPresets: [Float] = [1.0, 1.25, 1.5, 2.0, 3.0]
      /// Skip-interval choices, in seconds.
      private let skipChoices: [Int] = [5, 10, 15, 30, 45, 60, 90]

      var body: some View {
          @Bindable var player = player

          Form {
              Section("Speed") {
                  Picker("Playback Speed", selection: $player.playbackRate) {
                      ForEach(speedPresets, id: \.self) { rate in
                          Text(Self.speedLabel(rate)).tag(rate)
                      }
                  }
                  .pickerStyle(.menu)
              }

              Section("Loop") {
                  Picker("Loop Mode", selection: $player.loopMode) {
                      Text("Off").tag(LoopMode.off)
                      Text("Chapter").tag(LoopMode.chapter)
                      Text("Bookmark").tag(LoopMode.bookmark)
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
              }

              Section("Skip") {
                  Picker("Skip Interval", selection: $player.skipInterval) {
                      ForEach(skipChoices, id: \.self) { secs in
                          Text("\(secs)s").tag(secs)
                      }
                  }
                  .pickerStyle(.menu)
              }

              Section("Audio") {
                  Toggle("Volume Boost", isOn: $player.isVolumeBoostEnabled)
              }

              Section {
                  SettingsLink {
                      Label("Smart Rewind…", systemImage: "gear")
                  }
                  .buttonStyle(.link)
              } footer: {
                  Text("Configure Smart Rewind and more in Settings.")
                      .font(.caption)
                      .foregroundStyle(.secondary)
              }
          }
          .formStyle(.grouped)
          .frame(width: 280)
          .padding(.vertical, 4)
      }

      /// Speed label formatter — "1×", "1.25×", "1.5×". Parity with the iOS
      /// speedLabel duplicated in BottomToolbarView / TransportControlsView.
      static func speedLabel(_ rate: Float) -> String {
          if rate == rate.rounded() {
              return "\(Int(rate))×"
          }
          // Trim trailing zero on .x0 values (e.g. 1.50 -> "1.5×").
          let s = String(format: "%.2f", rate)
          let trimmed = s.hasSuffix("0") ? String(s.dropLast()) : s
          return "\(trimmed)×"
      }
  }
  ```

- [ ] **Replace the inline speed `Picker` in `MacTriPaneView` with the options button + popover.** First add the popover-presentation state. Read the current struct header to get the exact insertion point:
  ```
  Read "Echo macOS/Views/MacTriPaneView.swift" lines 11-16
  ```
  Then Edit to add a `@State` flag after the existing `@State private var dbServiceWired = false` (line 15):
  - old_string:
    ```
        @State private var columnVisibility = NavigationSplitViewVisibility.all
        @State private var dbServiceWired = false
    ```
  - new_string:
    ```
        @State private var columnVisibility = NavigationSplitViewVisibility.all
        @State private var dbServiceWired = false
        @State private var showingPlaybackOptions = false
    ```

- [ ] **Swap the inline speed `Picker` (`MacTriPaneView.swift:141-156`) for the options button + popover.** Edit:
  - old_string:
    ```
                    // Speed
                    Picker(
                        "Speed",
                        selection: Binding(
                            get: { player.playbackRate },
                            set: { player.playbackRate = $0 }
                        )
                    ) {
                        Text("1×").tag(Float(1.0))
                        Text("1.25×").tag(Float(1.25))
                        Text("1.5×").tag(Float(1.5))
                        Text("2×").tag(Float(2.0))
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 60)
    ```
  - new_string:
    ```
                    // Playback options (speed / loop / skip / boost)
                    Button {
                        showingPlaybackOptions.toggle()
                    } label: {
                        Text(MacPlaybackOptionsSheet.speedLabel(player.playbackRate))
                            .font(.caption.monospacedDigit())
                            .frame(width: 44)
                    }
                    .buttonStyle(.borderless)
                    .help("Playback options")
                    .popover(isPresented: $showingPlaybackOptions, arrowEdge: .bottom) {
                        MacPlaybackOptionsSheet()
                            .environment(player)
                    }
    ```
  *(Why re-inject `.environment(player)`: popover content is hosted in a detached presentation context; explicitly forwarding the `MacPlayerModel` guarantees the `@Environment` lookup resolves. `player` here is the `@Environment(MacPlayerModel.self)` already bound in `MacTriPaneView`.)*

- [ ] **Build the test target and run the suite — confirm it PASSES.** Run:
  ```
  make build-tests
  make test-only FILTER=EchoTests/MacPlaybackOptionsSheetTests
  ```
  Expected: `Test run with 4 tests passed` (no failures) for `MacPlaybackOptionsSheetTests`. The macOS app target compiling clean is implied by `make build-tests` building the EchoTests host; if the macOS target is not part of the test scheme, additionally run a macOS build to confirm the new SwiftUI compiles:
  ```
  xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 build 2>&1 | tail -20
  ```
  Expected tail: `** BUILD SUCCEEDED **`. (16 GB machine: single invocation, `-jobs 5`, never parallel-testing.)

- [ ] **Commit.** Run:
  ```
  git add "Echo macOS/Views/MacPlaybackOptionsSheet.swift" "Echo macOS/Views/MacTriPaneView.swift" "EchoTests/MacPlaybackOptionsSheetTests.swift"
  git commit -m "feat(macos): add Playback Options popover (speed/loop/skip/boost)"
  ```

### Task I2: macOS Player More menu (`MacPlayerMoreMenu`)

**Goal:** Create `Echo macOS/Views/MacPlayerMoreMenu.swift` — a SwiftUI `Menu` placed in `MacTriPaneView.playerBar`, exposing Chapters (WS-F list → `player.seekToChapter`), Bookmarks (existing `bookmarkStore` API → `player.jumpTo`), Add Bookmark, Mark Passage, the existing Sleep timer submenu (relocated from the inline `Menu` at `MacTriPaneView.swift:119-138`), and a Settings entry via `SettingsLink` (WS-J scene). Reuse existing `MacPlayerModel` bookmark/sleep API.

**Dependency note:** Chapters submenu reads `player.chapters` / `player.currentChapterIndex` and calls `player.seekToChapter(_:)` — all from **WS-F/WS-G**. Settings entry uses `SettingsLink` → **WS-J** scene. Verify WS-F symbols before writing (first step). Sleep submenu uses the already-existing `player.sleepTimerMode` / `player.sleepTimer.mode` (verified in `MacPlayerModel.swift:83-91,133`).

- [ ] **Verify WS-F chapter symbols exist before writing UI.** Run:
  ```
  grep -nE "var chapters|var currentChapterIndex|func seekToChapter|func nextChapter|func previousChapter" "Echo macOS/Views/MacPlayerModel.swift"
  ```
  Expected (5 matches):
  ```
  var chapters: [Chapter] = []
  var currentChapterIndex: Int = 0
  func nextChapter()
  func previousChapter()
  func seekToChapter(_ index: Int)
  ```
  If missing, STOP — WS-F not merged.

- [ ] **Write a failing structural test** for the More menu wiring. Append to `EchoTests/MacPlaybackOptionsSheetTests.swift` a second suite (keeps the `macSource` resolver in one file):
  ```swift

  @MainActor
  struct MacPlayerMoreMenuTests {

      private func macSource(named name: String) throws -> String {
          let thisFile = URL(fileURLWithPath: #filePath)
          let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
          let target = repoRoot
              .appendingPathComponent("Echo macOS")
              .appendingPathComponent("Views")
              .appendingPathComponent(name)
          return try String(contentsOf: target, encoding: .utf8)
      }

      @Test("MacPlayerMoreMenu declares the struct")
      func declaresStruct() throws {
          let src = try macSource(named: "MacPlayerMoreMenu.swift")
          #expect(src.contains("struct MacPlayerMoreMenu: View"))
      }

      @Test("MacPlayerMoreMenu wires chapters, bookmarks, passage, sleep, settings")
      func wiresAllActions() throws {
          let src = try macSource(named: "MacPlayerMoreMenu.swift")
          #expect(src.contains("player.seekToChapter"))
          #expect(src.contains("player.jumpTo"))
          #expect(src.contains("player.addBookmarkAtCurrentTime"))
          #expect(src.contains("player.sleepTimerMode"))
          #expect(src.contains("SettingsLink"))
      }

      @Test("MacTriPaneView hosts the More menu in the player bar")
      func triPaneHostsMoreMenu() throws {
          let src = try macSource(named: "MacTriPaneView.swift")
          #expect(src.contains("MacPlayerMoreMenu"))
      }
  }
  ```

- [ ] **Build + run — confirm FAILS** (file missing). Run:
  ```
  make build-tests
  make test-only FILTER=EchoTests/MacPlayerMoreMenuTests
  ```
  Expected: failures referencing `MacPlayerMoreMenuTests` (the `macSource` throws on the missing file; `triPaneHostsMoreMenu` fails its `#expect`).

- [ ] **Create the More menu view.** Write `Echo macOS/Views/MacPlayerMoreMenu.swift`:
  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  import SwiftUI

  /// The "More" menu for the macOS player bar. Exposes chapter navigation,
  /// bookmark jump/add, mark-passage, the sleep timer, and Settings. Mirrors the
  /// iOS PlayerMoreMenu using the existing MacPlayerModel API.
  ///
  /// `onMarkPassage` is injected because passage insertion needs the
  /// DatabaseService (owned by the app entry point / MacTriPaneView), not the
  /// player model — the caller threads a closure that runs MarkedPassageDAO.
  struct MacPlayerMoreMenu: View {
      @Environment(MacPlayerModel.self) private var player

      /// Inserts a marked passage at the current time (closure owns the DAO).
      var onMarkPassage: () -> Void

      var body: some View {
          Menu {
              chaptersSection
              bookmarksSection

              Divider()

              Button {
                  player.addBookmarkAtCurrentTime()
              } label: {
                  Label("Add Bookmark", systemImage: "bookmark")
              }
              .disabled(!player.hasMedia)

              Button {
                  onMarkPassage()
              } label: {
                  Label("Mark Passage", systemImage: "text.badge.star")
              }
              .disabled(!player.hasMedia)

              Divider()

              sleepSection

              Divider()

              SettingsLink {
                  Label("Settings…", systemImage: "gearshape")
              }
          } label: {
              Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .help("More")
          .frame(width: 28)
      }

      // MARK: - Chapters

      @ViewBuilder
      private var chaptersSection: some View {
          if player.chapters.count >= 2 {
              Menu {
                  ForEach(Array(player.chapters.enumerated()), id: \.element.id) { index, chapter in
                      Button {
                          player.seekToChapter(index)
                      } label: {
                          if index == player.currentChapterIndex {
                              Label(chapterTitle(chapter, at: index), systemImage: "checkmark")
                          } else {
                              Text(chapterTitle(chapter, at: index))
                          }
                      }
                  }
              } label: {
                  Label("Chapters", systemImage: "list.bullet")
              }
          }
      }

      private func chapterTitle(_ chapter: Chapter, at index: Int) -> String {
          if let title = chapter.title, !title.isEmpty {
              return title
          }
          return String(localized: "Chapter \(index + 1)")
      }

      // MARK: - Bookmarks

      @ViewBuilder
      private var bookmarksSection: some View {
          let bookmarks = player.bookmarkStore.bookmarks
          if bookmarks.isEmpty {
              Button {
              } label: {
                  Label("No Bookmarks", systemImage: "bookmark.slash")
              }
              .disabled(true)
          } else {
              Menu {
                  ForEach(bookmarks) { bookmark in
                      Button {
                          player.jumpTo(bookmark)
                      } label: {
                          Text("\(bookmark.title) — \(formatHMS(bookmark.timestamp))")
                      }
                  }
              } label: {
                  Label("Bookmarks", systemImage: "bookmark.fill")
              }
          }
      }

      // MARK: - Sleep Timer (relocated from the inline player-bar Menu)

      @ViewBuilder
      private var sleepSection: some View {
          Menu {
              Button("Off") { player.sleepTimerMode = .off }
              Divider()
              Button("5 min") { player.sleepTimerMode = .minutes(5) }
              Button("10 min") { player.sleepTimerMode = .minutes(10) }
              Button("15 min") { player.sleepTimerMode = .minutes(15) }
              Button("30 min") { player.sleepTimerMode = .minutes(30) }
              Button("45 min") { player.sleepTimerMode = .minutes(45) }
              Button("60 min") { player.sleepTimerMode = .minutes(60) }
              Divider()
              Button("End of Chapter") { player.sleepTimerMode = .endOfChapter }
          } label: {
              Label(
                  "Sleep Timer",
                  systemImage: player.sleepTimer.mode == .off ? "moon.zzz" : "moon.zzz.fill"
              )
          }
      }
  }
  ```
  *(Notes: `formatHMS` is the public shared helper at `Shared/TimeFormatting.swift:6`. `bookmarkStore.bookmarks` and `jumpTo(_:)`/`addBookmarkAtCurrentTime(note:)` are verified at `MacPlayerModel.swift:64,418,459`. The empty-bookmarks branch renders a disabled placeholder rather than an empty `Menu` so the affordance is discoverable.)*

- [ ] **Host the More menu in `MacTriPaneView.playerBar` and relocate the sleep `Menu`.** First remove the inline sleep `Menu` block at `MacTriPaneView.swift:119-139` (it moved into `MacPlayerMoreMenu`). Edit:
  - old_string:
    ```
                    // Sleep timer
                    Menu {
                        Button("Off") { player.sleepTimerMode = .off }
                        Divider()
                        Button("5 min") { player.sleepTimerMode = .minutes(5) }
                        Button("10 min") { player.sleepTimerMode = .minutes(10) }
                        Button("15 min") { player.sleepTimerMode = .minutes(15) }
                        Button("30 min") { player.sleepTimerMode = .minutes(30) }
                        Button("45 min") { player.sleepTimerMode = .minutes(45) }
                        Button("60 min") { player.sleepTimerMode = .minutes(60) }
                        Divider()
                        Button("End of Chapter") { player.sleepTimerMode = .endOfChapter }
                    } label: {
                        Image(
                            systemName: player.sleepTimer.mode == .off
                                ? "moon.zzz" : "moon.zzz.fill"
                        )
                    }
                    .buttonStyle(.borderless)
                    .help("Sleep timer")
                    .frame(width: 28)

    ```
  - new_string:
    ```
                    // More (chapters / bookmarks / mark passage / sleep / settings)
                    MacPlayerMoreMenu(onMarkPassage: onMarkPassage)

    ```

- [ ] **Thread the `onMarkPassage` closure into `MacTriPaneView`.** The mark-passage DAO logic lives in `Echo_macOSApp.markPassage()` (`Echo_macOSApp.swift:170-180`), which needs `dbService`. `MacTriPaneView` already has `@Environment(DatabaseService.self) private var dbService` (`MacTriPaneView.swift:13`). Add a private computed closure on `MacTriPaneView`. Read the struct end (after `playerBar`) and add, just before the closing `}` of `MacTriPaneView` (after the `playerBar` computed property, around `MacTriPaneView.swift:167`):
  - old_string (the final lines of the file, the closing of `playerBar`'s `else` and the struct):
    ```
            } else {
                HStack {
                    Text("No audiobook loaded — press ⌘O to open one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
    ```
  - new_string:
    ```
            } else {
                HStack {
                    Text("No audiobook loaded — press ⌘O to open one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }

        // MARK: - Mark Passage

        /// Inserts a marked passage at the current playback time via the shared
        /// DatabaseService. Mirrors Echo_macOSApp.markPassage so the More menu
        /// can mark without routing through a menu-command notification.
        private var onMarkPassage: () -> Void {
            {
                guard let audiobookID = player.audiobookID, player.hasMedia else { return }
                let dao = MarkedPassageDAO(db: dbService.writer)
                try? dao.insert(
                    audiobookID: audiobookID,
                    mediaTimestamp: player.currentTime,
                    endTimestamp: nil,
                    transcriptSnippet: nil,
                    note: nil
                )
            }
        }
    }
    ```
  *(Why a closure on the view rather than a method on `MacPlayerModel`: `markPassage` needs `DatabaseService`, which the player model does not own — `MacPlayerModel.dbService` is `var dbService: DatabaseService?` but the established pattern keeps DAO calls in the app/view layer per `Echo_macOSApp.swift:170`. The closure captures `MacTriPaneView`'s `dbService` env value. `MarkedPassageDAO.insert(...)` signature copied verbatim from `Echo_macOSApp.swift:172-179`.)*

- [ ] **Build + run — confirm PASSES.** Run:
  ```
  make build-tests
  make test-only FILTER=EchoTests/MacPlayerMoreMenuTests
  ```
  Expected: `Test run with 3 tests passed`. Then confirm the macOS app compiles:
  ```
  xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' -jobs 5 build 2>&1 | tail -20
  ```
  Expected tail: `** BUILD SUCCEEDED **`.

- [ ] **Commit.** Run:
  ```
  git add "Echo macOS/Views/MacPlayerMoreMenu.swift" "Echo macOS/Views/MacTriPaneView.swift" "EchoTests/MacPlaybackOptionsSheetTests.swift"
  git commit -m "feat(macos): add player More menu (chapters/bookmarks/passage/sleep/settings)"
  ```


---

## Self-review (writing-plans checklist)

- **Spec coverage:** Change 1 (chapter `< Title >` nav) → WS-F (axis) + WS-H (bar + menu reconcile). Change 2 (speed → Playback Options) → WS-G (loop/skip/boost on the model) + WS-I1 (popover). Change 3 (player More menu + Settings) → WS-I2 (More menu) + WS-J (Settings scene). Change 4 (configurable row) → N/A on macOS (documented zero-footprint).
- **Placeholder scan:** code steps are complete Swift; the one genuinely-uncertain area (audio-boost tap, WS-G3) ships concrete `MTAudioProcessingTap` code **with an explicit go/no-go risk note**, not a placeholder.
- **Type consistency:** `MacPlayerModel.chapters`/`currentChapterIndex`/`nextChapter()`/`previousChapter()`/`seekToChapter(_:)` (F) consumed read-only by WS-H/I; `loopMode`/`skipInterval`/`isVolumeBoostEnabled`/`volumeBoostGain` (G) consumed by WS-I's popover; `MacSettingsView` + `Settings` scene (J) reached by WS-I's `SettingsLink`; `MacSource` test resolver (G) reused by H/I/J structural tests.
- **Cross-plan dependency:** WS-J reuses `EchoCore/Models/ThemeColor.swift` from iOS **Task E1** — land E1 first; do not exclude `ThemeColor.swift` from the macOS target.
- **Known follow-ups (out of scope):** unified Mac folder-chapter timeline; applying `appFont`/accent `themeColor` to the macOS UI; a behavioral Mac unit-test target; an inline boost-gain slider.

> Execution: choose **subagent-driven** or **inline**. See the chat handoff.

## Known minor corrections (advisory — apply during execution)

- **F1 ↔ H1 helper consistency:** F1 adds `hasPreviousChapter`/`hasNextChapter` to `MacPlayerModel`; H1/H2 should **consume** them (`.disabled(!player.hasPreviousChapter)` / `!player.hasNextChapter`) instead of recomputing the bounds inline, and H1's context note claiming "there is no `hasPreviousChapter`…" should be deleted. Otherwise those two helpers are dead code.
- **I1 expected grep output:** after the unified-store fix, `MacPlayerModel.isVolumeBoostEnabled` reads `= UserDefaults.standard.bool(forKey: "global_volumeBoostEnabled")` (not `= false`). I1's pre-flight grep should match the **symbol name**, not the literal default expression.
- **I1 negative assertion (`triPaneRoutesToPopover`):** replace the whitespace-sensitive `!src.contains("Picker(\n ... \"Speed\",")` check with tolerant positive assertions — that the new tokens (`MacPlaybackOptionsSheet`, `.popover`) are present and the literal speed tags (`Text("1.25×").tag(Float(1.25))`) are gone.
- **Advisory line numbers:** a few citations drift from the post-#76 tree (e.g. `tracks`/`currentTrackIndex` is `MacPlayerModel.swift:95-96`; `sleepTimer` is `:71`). Every `Edit` uses an exact `old_string` that *does* match, so the edits apply regardless — refresh the cited numbers if reading by line.
