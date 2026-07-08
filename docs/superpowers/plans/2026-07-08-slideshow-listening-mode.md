# Echo Slideshow Listening Mode - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Echo's first slideshow listening mode: a listening surface that keeps a current EPUB image/figure, required subtitle/read-along text, and karaoke-style active-word cue synchronized with playback. The first shipping slice derives cues from existing EPUB blocks, timeline rows, and word timings, then presents them on iPhone/iPad and macOS without changing system Now Playing metadata.

**Architecture:** Put the timing policy and cue selection in a pure shared resolver first. iOS then gets an additive `@MainActor @Observable` view model and a local Now Playing stage. iPad landscape composes the same stage beside compact player/book context. macOS gets a sibling stage backed by `MacPlayerModel` and the same shared resolver. No new persistence schema is needed for v1; future authored `.echo` visual tracks can feed the same cue model.

**Tech Stack:** Swift 6.0, SwiftUI, GRDB, `@Observable`, existing `ReaderActiveBlockResolver`, `EPubBlockRecord`, `TimelineItem`, `WordTimingRecord`, Swift Testing, Xcode 26.6. Deployment floors stay iOS 18.0, macOS 15.0, watchOS 11.0.

## Global Constraints

- Work from a named branch based on `origin/nightly`; open the PR against `nightly`.
- Use TDD for behavior: write focused failing tests before the implementation for each task.
- Builds/tests must go through the gate: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && ...`.
- Keep new shared files free of UIKit/AppKit so they compile for every target that consumes `Shared/`.
- Do not add third-party dependencies.
- Do not churn system `MPNowPlayingInfoCenter` artwork per visual cue. Slideshow visuals are in-app.
- Do not raise deployment targets or Swift language version.
- Preserve the root-owned `UnifiedTopHeader` and `UnifiedBottomDock` safe-area pattern on iOS.
- Treat subtitles as required. If no precise word timing exists, show a stable line/block subtitle fallback.
- Begin-vs-midpoint image timing must be represented in the pure resolver even before a full authored visual-track importer exists.
- Every new Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- SwiftLint, `git diff --check`, focused tests, broad iOS tests, macOS build, echo-cli build, and hosted CI are the final gates.

## Out of Scope For This Slice

- Importing or exporting authored `visuals/book.visual-track.json`.
- Capturing EPUB `figcaption`, `alt`, `whatToNotice`, or `confidenceNote` from source markup.
- Watch slideshow UI.
- Full-screen image inspector gestures.
- Repeat-listening heatmaps or study analytics intensity.
- Reworking the existing reader feed layout.

## Task Map

| Task | Deliverable | Primary write scope |
|------|-------------|---------------------|
| 1 | Shared pure cue/subtitle resolver with begin/midpoint timing | `Shared/VisualListeningCueResolver.swift`, `EchoTests/VisualListeningCueResolverTests.swift` |
| 2 | iOS view model loading blocks/timeline/words and exposing live snapshots | `EchoCore/ViewModels/VisualListeningViewModel.swift`, `EchoTests/VisualListeningViewModelTests.swift` |
| 3 | iPhone/iPad Now Playing stage using the view model | `EchoCore/Views/VisualListeningStageView.swift`, `EchoCore/Views/NowPlayingTab.swift`, `EchoTests/NowPlayingLayoutTests.swift` |
| 4 | iPad landscape composition and macOS parity stage | `EchoCore/Views/RootTabView.swift` or local Now Playing helpers, `Echo macOS/Views/MacVisualStageView.swift`, `Echo macOS/Views/MacTriPaneView.swift` |
| 5 | Docs, changelog, final verification | `ARCHITECTURE.md`, `CHANGELOG.md`, KB status note if implementation teaches durable operating context |

Recommended implementation order: Task 1 -> Task 2 -> Task 3 -> Task 4 -> Task 5. Do not start Task 4 until Tasks 1-3 are compiling because both iPad and Mac should consume the same model semantics.

---

## Task 1: Shared Visual Listening Cue Resolver

**Files:**
- Create: `Shared/VisualListeningCueResolver.swift`
- Create: `EchoTests/VisualListeningCueResolverTests.swift`

**Interfaces:**
- Produces `VisualListeningSyncPoint` with `.begin` and `.midpoint`.
- Produces `VisualListeningImageCue` with at least `blockID`, `imagePath`, `caption`, `chapterIndex`, `sequenceIndex`, `displayStartTime`, `displayEndTime`, `syncPoint`, and a source label such as `.explicitTimeline` or `.derivedFromNearbyText`.
- Produces `VisualListeningSubtitleCue` with `blockID`, `text`, `activeWordIndex`, and an `alreadyHeardWordCount`/equivalent progress value for the "heard text wash" direction.
- Produces `VisualListeningSnapshot` containing the active image cue, subtitle cue, and active block ID at a playback time.
- Consumes `EPubBlockRecord`, `ReaderActiveBlockResolver.TimelineRow`, `ReaderActiveBlockResolver.WordRow`, current playback time, current track scope, optional segment key, and a sync-point preference.

- [ ] **Step 1: Write failing pure tests**

Cover:

- Image candidates include visible image blocks with non-empty `imagePath`, preserve `sequenceIndex`, and drop hidden/text-only blocks.
- A timestamped image block uses its own `[start, end)` range.
- An untimed image can derive a display window from the nearest in-scope text block so existing EPUB figures still work before authored visual tracks.
- Track scoping prevents a chapter-0 image from appearing while chapter 1 is playing at the same per-track time.
- `begin` timing starts the image at the associated text interval start.
- `midpoint` timing makes the image visible before and after the associated section by expanding around the text interval, clamping start to zero.
- Subtitle resolution reuses `ReaderActiveBlockResolver` semantics and returns an active-word index when word timing covers the current time.
- Subtitle fallback still returns block text when word timing is missing.

- [ ] **Step 2: Implement resolver types and helpers**

Keep the resolver dependency-free and deterministic. Favor small static functions over an instance service. Do not introduce protocols.

Suggested shape:

```swift
enum VisualListeningCueResolver {
    static func snapshot(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        time: TimeInterval,
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?,
        syncPoint: VisualListeningSyncPoint
    ) -> VisualListeningSnapshot
}
```

Implementation policy:

- Sort blocks by `sequenceIndex`.
- Resolve the active subtitle block with `ReaderActiveBlockResolver.activeBlockID`.
- Build image cue windows from image blocks in reading order.
- Prefer explicit timestamped image rows when present.
- For untimed image blocks, derive the reference range from the closest following text timeline row in the same chapter/scope; fall back to the preceding row when there is no following row.
- Clamp derived windows to non-negative times and use `[start, end)` semantics.
- If two image cue windows overlap, the later image in reading order wins at equal/in-overlap times.

- [ ] **Step 3: Run focused tests**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/VisualListeningCueResolverTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Commit**

```bash
git add Shared/VisualListeningCueResolver.swift EchoTests/VisualListeningCueResolverTests.swift
git commit -m "feat(shared): resolve visual listening cues"
```

---

## Task 2: iOS Visual Listening View Model

**Files:**
- Create: `EchoCore/ViewModels/VisualListeningViewModel.swift`
- Create: `EchoTests/VisualListeningViewModelTests.swift`
- Modify only if needed: `Shared/Database/DAOs/EPubBlockDAO.swift` or existing DAO helpers for reusable queries.

**Interfaces:**
- Produces `@MainActor @Observable final class VisualListeningViewModel`.
- Consumes `audiobookID`, `DatabaseWriter`, and optional playlist folder URL if track/scope behavior needs parity with `ReaderFeedViewModel`.
- Exposes:
  - `private(set) var snapshot: VisualListeningSnapshot`
  - `var syncPoint: VisualListeningSyncPoint`
  - `func reload() async`
  - `func update(time:currentTrackSegmentKey:currentTrackChapterIndices:)`
  - `var hasVisualListeningContent: Bool`

- [ ] **Step 1: Write failing view-model tests**

Use `DatabaseService(inMemory:)` and raw/DAO inserts like `ReaderActiveBlockTrackScopingTests` and `ReaderFeedViewModelScopeTests`.

Cover:

- `reload()` loads visible image blocks, timestamped text/image rows, and word rows for one audiobook only.
- `hasVisualListeningContent` is true only when there is at least one usable image and at least one text/timeline subtitle source.
- `update(...)` refreshes image and subtitle as playback time changes.
- Scope/segment values are passed into the shared resolver.
- Changing `syncPoint` recomputes the current snapshot without needing a full reload.

- [ ] **Step 2: Implement the view model**

Mirror the query shape already proven in `ReaderFeedViewModel`:

- Blocks: `EPubBlockDAO(db: db).visibleBlocks(for:)`.
- Timeline: `timeline_item` left-joined to `epub_block`, selecting `audio_start_time`, `audio_end_time`, `epub_block_id`, `segment_key`, and `chapter_index`, filtered to `audio_start_time >= 0`.
- Word rows: `WordTimingDAO(db: db).words(forAudiobook:)`.

Keep errors logged and fail soft with an empty snapshot so the Now Playing screen never crashes because EPUB timing is incomplete.

- [ ] **Step 3: Run focused tests**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/VisualListeningViewModelTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Commit**

```bash
git add EchoCore/ViewModels/VisualListeningViewModel.swift EchoTests/VisualListeningViewModelTests.swift
git commit -m "feat(ios): load visual listening snapshots"
```

---

## Task 3: iPhone/iPad Now Playing Stage

**Files:**
- Create: `EchoCore/Views/VisualListeningStageView.swift`
- Modify: `EchoCore/Views/NowPlayingTab.swift`
- Modify: `EchoTests/NowPlayingLayoutTests.swift`

**Interfaces:**
- Produces a SwiftUI stage that renders the active image cue, caption fallback, subtitle line, and karaoke/progress text treatment.
- `NowPlayingTab` owns a `@State` `VisualListeningViewModel?` when `model.folderURL` and `model.audiobookID`/equivalent current book identity are available.

- [ ] **Step 1: Write view/source tests**

Extend `NowPlayingLayoutTests` or add a focused source-inspection suite to assert:

- `NowPlayingTab` references `VisualListeningViewModel`.
- `NowPlayingTab` updates visual listening from `model.currentPlaybackTime`.
- `VisualListeningStageView` has accessibility labels for the image/caption and subtitle.
- The old artwork path remains as a fallback when visual listening content is unavailable.

- [ ] **Step 2: Build `VisualListeningStageView`**

Design rules:

- Use semantic fonts and Dynamic Type.
- Keep captions/subtitles concise and line-limited in compact layouts, but do not truncate the only subtitle source to zero.
- Use `Image(uiImage:)` for resolved local EPUB images on iOS; file loading stays in the view or a tiny local helper, not in the shared resolver.
- Use the subtitle every time slideshow content is visible.
- Show active-word emphasis and heard-text wash when word timing exists; show a stable subtitle line when it does not.
- Provide VoiceOver labels that include "Current figure" and "Subtitle" context.

- [ ] **Step 3: Wire into `NowPlayingTab`**

Keep the existing artwork/metadata/scrubber fallback. Only swap to the visual stage when `hasVisualListeningContent` is true.

Important:

- Preserve `safeAreaInset(edge: .top)` and bottom dock reservations.
- Do not move the root-owned bottom dock into this view.
- Do not create a new tab in this task.
- Do not update lock-screen artwork for each cue.

- [ ] **Step 4: Run focused tests**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests/NowPlayingLayoutTests -parallel-testing-enabled NO -jobs 5 CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/VisualListeningStageView.swift EchoCore/Views/NowPlayingTab.swift EchoTests/NowPlayingLayoutTests.swift
git commit -m "feat(ios): show visual listening stage"
```

---

## Task 4: iPad Landscape And macOS Parity

**Files:**
- Modify: `EchoCore/Views/NowPlayingTab.swift` and/or a local helper extracted from it.
- Create: `Echo macOS/Views/MacVisualStageView.swift`
- Modify: `Echo macOS/Views/MacTriPaneView.swift`
- Add focused tests only where practical; source-inspection tests are acceptable for layout wiring.

- [ ] **Step 1: iPad landscape composition**

Within the Now Playing surface, use local adaptive layout, not a broad app shell rewrite:

- Regular horizontal size class / landscape-like width: visual stage beside compact metadata/player controls and reader/subtitle context.
- Compact width / portrait: single-column visual stage above metadata and scrubber.
- Keep text readable and avoid fixed viewport-scaled fonts.
- Preserve the existing top header and bottom dock safe areas.

- [ ] **Step 2: macOS stage**

Create `MacVisualStageView` backed by the same shared resolver semantics and Mac image loading.

Mount it in `MacTriPaneView`'s center column above or beside `MacReaderFeedView` without removing the existing reader or bottom player bar. The Mac experience should feel richer than iPhone: persistent reader context, visual stage, and playback controls in one workspace.

- [ ] **Step 3: Verify builds**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
```

- [ ] **Step 4: Commit**

```bash
git add "Echo macOS/Views/MacVisualStageView.swift" "Echo macOS/Views/MacTriPaneView.swift" EchoCore/Views/NowPlayingTab.swift
git commit -m "feat: adapt visual listening for iPad and Mac"
```

---

## Task 5: Docs, Verification, PR

**Files:**
- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`
- Update KB only if implementation decisions add durable operating context beyond the existing `Echo Slideshow Listening Mode` topic.

- [ ] **Step 1: Document the shipped slice**

Mention:

- V1 derives visual cues from EPUB images plus existing alignment/timeline data.
- Authored visual tracks remain future work.
- Subtitles are required, with word-level highlighting when `word_timing` exists.
- Begin-vs-midpoint timing exists in the shared resolver.
- iPad is explicitly treated as its own layout shape.

- [ ] **Step 2: Full local verification**

```bash
git diff --check
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests SIM_DEST='platform=iOS Simulator,name=iPhone 17'
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test SIM_DEST='platform=iOS Simulator,name=iPhone 17'
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme echo-cli -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
```

If SwiftLint is installed/configured, run it before the final commit.

- [ ] **Step 3: Push, PR, and CI**

```bash
git fetch origin
git rebase origin/nightly
git push --force-with-lease -u origin codex/echo-slideshow-listening-mode
gh pr create --base nightly --head codex/echo-slideshow-listening-mode --title "Add Echo slideshow listening mode" --body-file <prepared-body>
gh pr checks <pr-url> --watch
```

Hosted CI status must be reported as passing, failing, pending, or blocked. If it fails, inspect logs and fix concrete blockers.
