# Slideshow Video Export with SRT — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export a whole book's Visual Listening slideshow as `<Title>.mp4` + `<Title>.srt` + `<Title>.chapters.txt` from iOS, macOS, and echo-cli.

**Architecture:** A pure `SlideshowExportPlanner` (Shared) turns DB rows into a deterministic timed frame/SRT plan by calling `VisualListeningCueResolver` per track with player-identical scoping; a CoreGraphics/CoreText `SlideshowFrameRenderer` (EchoCore, UIKit-free) rasterizes frames; a `VideoExportService` actor (sibling of `AudioExportService`) assembles audio from the existing `ExportSource` spine and writes H.264+AAC via `AVAssetWriter` with variable frame durations. Spec: `docs/superpowers/specs/2026-07-18-slideshow-video-export-design.md`.

**Tech Stack:** Swift 6.0, AVFoundation, CoreGraphics/CoreText/ImageIO, GRDB, Swift Testing, ArgumentParser (echo-cli), Xcode 26.

## Global Constraints

- Branch: PR 1 on `claude/echo-slideshow-video-export-srt-837616` (already based on `origin/nightly`); PR 2 branch `claude/slideshow-video-export-ui` cut from PR 1's branch. Both PRs target `nightly`.
- Every new Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on line 1 (the SwiftFormat edit hook reflows files — re-check line 1 after every edit).
- No UIKit/AppKit imports in any new `Shared/` or `EchoCore/Services/Export/` file (they compile into iOS + macOS + echo-cli). New `Shared/` files must not reference EchoCore types.
- No new third-party dependencies. No deployment-floor changes (iOS 18 / macOS 15 / watchOS 11). No schema migration.
- All builds/tests through the gate: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && …`. Never uncapped parallel testing.
- Focused test loop: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>` per iteration.
- echo-cli is built ONLY via `make echo-cli` (Release + incremental; see CLAUDE.md for why).
- Conventional Commits. Commit at the end of every task.
- TDD: each task writes its failing tests before implementation.

## Deviations from spec (agreed refinements, spec stays authoritative otherwise)

1. Chapter marks are computed by `VideoExportService` in its audio-assembly loop (the accumulation `AudioExportService.exportM4B` already proves), not by the planner. `SRTFormatter` still formats them; the `SlideshowChapterMark` type lives with `SRTFormatter` in Shared.
2. Progress is a `@Sendable (Double) -> Void` callback instead of `AsyncStream` — same information, less stream-lifecycle risk; UI wraps it in `@State`.
3. Track scoping (`segmentKey`, `chapterIndices`) is derived in EchoCore (which can see `NarrationFileNaming` + `ReaderActiveBlockResolver.trackChapterScope`) and passed INTO the pure planner via `SlideshowTrackContext`, keeping `Shared/` free of EchoCore references (watch/widget targets compile `Shared/`).
4. The spec's "CLI argument-parsing test" is satisfied by the `--help` smoke check plus `ValidationError` paths in Task 7 — echo-cli sources are not members of `EchoTests`, so a unit test cannot reach the command type; the size/range validation logic is 6 lines exercised at every CLI run.

## Task Map

| Task | PR | Deliverable |
|------|----|-------------|
| 1 | 1 | Resolver visibility (`imageCues`, `rowIsInScope` internal) + `SlideshowExportPlanner` + tests |
| 2 | 1 | `SRTFormatter` + `SlideshowChapterMark` + tests |
| 3 | 1 | `VisualListeningImageLocator` extraction + stage-view refactor |
| 4 | 1 | `TimelineRowLoader` extraction + `VisualListeningViewModel` refactor |
| 5 | 1 | `SlideshowFrameRenderer` + tests |
| 6 | 1 | `VideoExportService` + track-context derivation + integration test |
| 7 | 1 | `echo-cli export-video` subcommand |
| 8 | 1 | PR 1: full verification, push, PR into `nightly`, CI |
| 9 | 2 | iOS `VideoExportProgressView` + dock/menu wiring |
| 10 | 2 | macOS `MacVideoExportView` + app wiring |
| 11 | 2 | Docs (`ARCHITECTURE.md`, `CHANGELOG.md`), full verification, PR 2 |

Implementation order is 1→11. Tasks 2, 3, 4 are independent of each other but all precede 5/6.

---

## Task 1: SlideshowExportPlanner (pure, Shared)

**Files:**
- Modify: `Shared/VisualListeningCueResolver.swift` (two `private` → internal)
- Create: `Shared/SlideshowExportPlanner.swift`
- Test: `EchoTests/SlideshowExportPlannerTests.swift`

**Interfaces:**
- Consumes: `VisualListeningCueResolver.snapshot(...)` (existing), `VisualListeningCueResolver.imageCues(...)` and `.rowIsInScope(...)` (made internal here), `ReaderActiveBlockResolver.TimelineRow`/`WordRow`, `EPubBlockRecord`, `WordTokenizer.wordRanges(in:)`.
- Produces (used by Tasks 2, 5, 6, 7):

```swift
nonisolated struct SlideshowTrackContext: Equatable, Sendable {
    let title: String
    let duration: TimeInterval
    let segmentKey: String?
    let chapterIndices: Set<Int>?
}
nonisolated enum SlideshowExportMode: String, Sendable { case karaoke, simple }
nonisolated struct SlideshowFramePlan: Equatable, Sendable {
    let startTime: TimeInterval      // global video time
    let duration: TimeInterval
    let imagePath: String?           // nil → renderer uses cover art
    let caption: String?
    let subtitleText: String?
    let activeWordIndex: Int?        // display-token ordinal in subtitleText
    let alreadyHeardWordCount: Int
}
nonisolated struct SlideshowSRTCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
nonisolated struct SlideshowExportPlan: Equatable, Sendable {
    let frames: [SlideshowFramePlan]
    let srtCues: [SlideshowSRTCue]
    let totalDuration: TimeInterval
}
nonisolated enum SlideshowExportPlanner {
    static func plan(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        tracks: [SlideshowTrackContext],
        mode: SlideshowExportMode,
        syncPoint: VisualListeningSyncPoint,
        range: Range<TimeInterval>? = nil
    ) -> SlideshowExportPlan
}
```

- [x] **Step 1: Make two resolver helpers internal**

In `Shared/VisualListeningCueResolver.swift` change exactly two declarations (no body changes):

```swift
    // was: private static func imageCues(
    static func imageCues(
```

```swift
    // was: private static func rowIsInScope(
    static func rowIsInScope(
```

The planner needs exact image display windows (for frame boundaries) and scope filtering (for SRT rows) without duplicating either policy.

- [x] **Step 2: Write failing planner tests**

Create `EchoTests/SlideshowExportPlannerTests.swift`. Reuse the fixture style of `VisualListeningCueResolverTests` (same `block`/`timeline` helpers, copied here because test files don't share helpers):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct SlideshowExportPlannerTests {
    // MARK: - Fixtures

    private func block(
        _ id: String, sequence: Int, kind: EPubBlockRecord.Kind,
        text: String? = nil, imagePath: String? = nil,
        chapter: Int? = 0, hidden: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "spine", spineIndex: 0,
            blockIndex: sequence, sequenceIndex: sequence, blockKind: kind.rawValue,
            text: text, htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: imagePath, chapterIndex: chapter, isHidden: hidden,
            hiddenReason: nil, isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, narrationText: nil, createdAt: nil, modifiedAt: nil)
    }

    private func timeline(
        _ start: TimeInterval, _ end: TimeInterval, blockID: String,
        chapter: Int? = 0, segmentKey: String? = nil
    ) -> ReaderActiveBlockResolver.TimelineRow {
        (start: start, end: end, blockID: blockID, chapterIndex: chapter, segmentKey: segmentKey)
    }

    private var chapterOneFixture:
        (blocks: [EPubBlockRecord], timeline: [ReaderActiveBlockResolver.TimelineRow])
    {
        let blocks = [
            block("p1", sequence: 0, kind: .paragraph, text: "First sentence here."),
            block("fig", sequence: 1, kind: .image, imagePath: "figures/one.jpg"),
            block("p2", sequence: 2, kind: .paragraph, text: "Second sentence follows."),
        ]
        let rows = [
            timeline(0, 4, blockID: "p1"),
            timeline(4, 8, blockID: "p2"),
        ]
        return (blocks, rows)
    }

    // MARK: - Frames

    @Test func simpleModeEmitsOneFramePerVisualChangeWithGlobalTimes() {
        let fx = chapterOneFixture
        let plan = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: [],
            tracks: [SlideshowTrackContext(
                title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)],
            mode: .simple, syncPoint: .begin)

        // begin-sync: figure derives its window from the following text row (p2: 4-8).
        #expect(plan.totalDuration == 8)
        #expect(plan.frames.first?.startTime == 0)
        #expect(plan.frames.first?.subtitleText == "First sentence here.")
        let figureFrame = plan.frames.first { $0.imagePath == "figures/one.jpg" }
        #expect(figureFrame?.startTime == 4)
        #expect(figureFrame?.subtitleText == "Second sentence follows.")
        // Frames tile [0, totalDuration) with no gaps or overlaps.
        var cursor: TimeInterval = 0
        for frame in plan.frames {
            #expect(frame.startTime == cursor)
            cursor += frame.duration
        }
        #expect(cursor == 8)
    }

    @Test func secondTrackFramesAreOffsetByFirstTrackDuration() {
        let blocks = [
            block("c1", sequence: 0, kind: .paragraph, text: "Chapter one text.", chapter: 0),
            block("c2", sequence: 1, kind: .paragraph, text: "Chapter two text.", chapter: 1),
        ]
        let rows = [
            timeline(0, 5, blockID: "c1", chapter: 0, segmentKey: "0-0"),
            timeline(0, 6, blockID: "c2", chapter: 1, segmentKey: "1-0"),
        ]
        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: [],
            tracks: [
                SlideshowTrackContext(
                    title: "One", duration: 5, segmentKey: "0-0", chapterIndices: [0]),
                SlideshowTrackContext(
                    title: "Two", duration: 6, segmentKey: "1-0", chapterIndices: [1]),
            ],
            mode: .simple, syncPoint: .begin)

        #expect(plan.totalDuration == 11)
        let secondChapterFrame = plan.frames.first { $0.subtitleText == "Chapter two text." }
        #expect(secondChapterFrame?.startTime == 5)  // 0 (track-local) + 5 (offset)
        // Track 1's per-track time 0-5 must NOT leak chapter-two text.
        let leaked = plan.frames.contains {
            $0.startTime < 5 && $0.subtitleText == "Chapter two text."
        }
        #expect(!leaked)
    }

    @Test func karaokeModeSplitsFramesAtWordBoundaries() {
        let fx = chapterOneFixture
        let words: [ReaderActiveBlockResolver.WordRow] = [
            (start: 0.0, end: 1.0, blockID: "p1", wordIndex: 0),
            (start: 1.0, end: 2.5, blockID: "p1", wordIndex: 1),
            (start: 2.5, end: 4.0, blockID: "p1", wordIndex: 2),
        ]
        let plan = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: words,
            tracks: [SlideshowTrackContext(
                title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)],
            mode: .karaoke, syncPoint: .begin)

        let p1Frames = plan.frames.filter { $0.subtitleText == "First sentence here." }
        #expect(p1Frames.count == 3)
        #expect(p1Frames.map(\.activeWordIndex) == [0, 1, 2])
        #expect(p1Frames.map(\.alreadyHeardWordCount) == [0, 1, 2])
    }

    @Test func simpleModeIgnoresWordTimings() {
        let fx = chapterOneFixture
        let words: [ReaderActiveBlockResolver.WordRow] = [
            (start: 0.0, end: 1.0, blockID: "p1", wordIndex: 0),
            (start: 1.0, end: 4.0, blockID: "p1", wordIndex: 1),
        ]
        let plan = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: words,
            tracks: [SlideshowTrackContext(
                title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)],
            mode: .simple, syncPoint: .begin)

        #expect(plan.frames.allSatisfy { $0.activeWordIndex == nil })
        #expect(plan.frames.filter { $0.subtitleText == "First sentence here." }.count == 1)
    }

    // MARK: - SRT cues

    @Test func srtCuesComeFromScopedTextRowsWithGlobalTimes() {
        let fx = chapterOneFixture
        let plan = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: [],
            tracks: [SlideshowTrackContext(
                title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)],
            mode: .simple, syncPoint: .begin)

        #expect(plan.srtCues.count == 2)
        #expect(plan.srtCues[0].text == "First sentence here.")
        #expect(plan.srtCues[0].startTime == 0)
        #expect(plan.srtCues[0].endTime == 4)
        #expect(plan.srtCues[1].startTime == 4)
    }

    @Test func longBlockTextSplitsIntoMultipleCuesProportionally() {
        let longText = Array(repeating: "word", count: 60).joined(separator: " ")  // 299 chars
        let blocks = [block("long", sequence: 0, kind: .paragraph, text: longText)]
        let rows = [timeline(0, 30, blockID: "long")]
        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: [],
            tracks: [SlideshowTrackContext(
                title: "Ch 1", duration: 30, segmentKey: nil, chapterIndices: nil)],
            mode: .simple, syncPoint: .begin)

        #expect(plan.srtCues.count > 1)
        #expect(plan.srtCues.allSatisfy { $0.text.count <= 84 })
        #expect(plan.srtCues.first?.startTime == 0)
        #expect(plan.srtCues.last?.endTime == 30)
        // Contiguous, monotonic, non-overlapping.
        for (a, b) in zip(plan.srtCues, plan.srtCues.dropFirst()) {
            #expect(a.endTime == b.startTime)
        }
    }

    // MARK: - Range

    @Test func rangeClampsAndRebasesFramesAndCues() {
        let fx = chapterOneFixture
        let plan = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: [],
            tracks: [SlideshowTrackContext(
                title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)],
            mode: .simple, syncPoint: .begin,
            range: 2.0..<6.0)

        #expect(plan.totalDuration == 4)
        #expect(plan.frames.first?.startTime == 0)
        #expect(plan.srtCues.allSatisfy { $0.startTime >= 0 && $0.endTime <= 4 })
        #expect(plan.srtCues.contains { $0.text == "Second sentence follows." })
    }
}
```

- [x] **Step 3: Run tests to verify they fail**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile FAILURE — `SlideshowExportPlanner` not defined. (A compile failure at this stage is the "failing test".)

- [x] **Step 4: Implement the planner**

Create `Shared/SlideshowExportPlanner.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One audio track's contribution to the export timeline. `segmentKey` /
/// `chapterIndices` must carry the same scoping the live player derives for the
/// track (see `PlayerModel+VisualListeningScope`); the caller derives them so
/// this file stays free of EchoCore naming helpers and compiles for every
/// target that consumes `Shared/`.
nonisolated struct SlideshowTrackContext: Equatable, Sendable {
    let title: String
    let duration: TimeInterval
    let segmentKey: String?
    let chapterIndices: Set<Int>?
}

nonisolated enum SlideshowExportMode: String, Sendable {
    case karaoke
    case simple
}

nonisolated struct SlideshowFramePlan: Equatable, Sendable {
    let startTime: TimeInterval
    let duration: TimeInterval
    let imagePath: String?
    let caption: String?
    let subtitleText: String?
    let activeWordIndex: Int?
    let alreadyHeardWordCount: Int
}

nonisolated struct SlideshowSRTCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

nonisolated struct SlideshowExportPlan: Equatable, Sendable {
    let frames: [SlideshowFramePlan]
    let srtCues: [SlideshowSRTCue]
    let totalDuration: TimeInterval
}

/// Turns aligned book data into a deterministic whole-book slideshow plan.
/// Every visual decision is delegated to `VisualListeningCueResolver`, sampled
/// once per boundary event, so the export cannot drift from the live stage.
nonisolated enum SlideshowExportPlanner {
    /// Maximum characters per SRT cue (two standard 42-char subtitle lines).
    static let maxCueLength = 84

    static func plan(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        tracks: [SlideshowTrackContext],
        mode: SlideshowExportMode,
        syncPoint: VisualListeningSyncPoint,
        range: Range<TimeInterval>? = nil
    ) -> SlideshowExportPlan {
        let orderedBlocks = blocks.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        let blocksByID = Dictionary(uniqueKeysWithValues: orderedBlocks.map { ($0.id, $0) })

        var frames: [SlideshowFramePlan] = []
        var srtCues: [SlideshowSRTCue] = []
        var offset: TimeInterval = 0

        for track in tracks {
            let scopedRows = timeline.filter {
                VisualListeningCueResolver.rowIsInScope(
                    $0,
                    currentTrackSegmentKey: track.segmentKey,
                    currentTrackChapterIndices: track.chapterIndices)
            }
            let boundaries = trackBoundaries(
                orderedBlocks: orderedBlocks, blocksByID: blocksByID,
                timeline: timeline, scopedRows: scopedRows, words: words,
                track: track, mode: mode, syncPoint: syncPoint)

            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let snapshot = VisualListeningCueResolver.snapshot(
                    blocks: orderedBlocks, timeline: timeline,
                    words: mode == .karaoke ? words : [],
                    time: start,
                    currentTrackSegmentKey: track.segmentKey,
                    currentTrackChapterIndices: track.chapterIndices,
                    syncPoint: syncPoint)
                let frame = SlideshowFramePlan(
                    startTime: offset + start,
                    duration: end - start,
                    imagePath: snapshot.imageCue?.imagePath,
                    caption: snapshot.imageCue?.caption,
                    subtitleText: snapshot.subtitleCue?.text,
                    activeWordIndex: mode == .karaoke
                        ? snapshot.subtitleCue?.activeWordIndex : nil,
                    alreadyHeardWordCount: mode == .karaoke
                        ? (snapshot.subtitleCue?.alreadyHeardWordCount ?? 0) : 0)
                appendMerging(frame, to: &frames)
            }

            let textRows = scopedRows
                .filter { row in
                    row.end > row.start
                        && (blocksByID[row.blockID]?.text?.isEmpty == false)
                }
                .sorted { $0.start < $1.start }
            for row in textRows {
                srtCues.append(
                    contentsOf: splitCues(
                        forRow: row, blocksByID: blocksByID, words: words, offset: offset))
            }

            offset += track.duration
        }

        let total = offset
        guard let range else {
            return SlideshowExportPlan(frames: frames, srtCues: srtCues, totalDuration: total)
        }
        return clamp(
            SlideshowExportPlan(frames: frames, srtCues: srtCues, totalDuration: total),
            to: range.lowerBound..<min(range.upperBound, total))
    }

    // MARK: - Boundaries

    private static func trackBoundaries(
        orderedBlocks: [EPubBlockRecord],
        blocksByID: [String: EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        scopedRows: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        track: SlideshowTrackContext,
        mode: SlideshowExportMode,
        syncPoint: VisualListeningSyncPoint
    ) -> [TimeInterval] {
        var times: Set<TimeInterval> = [0, track.duration]
        for row in scopedRows {
            times.insert(row.start)
            times.insert(row.end)
        }
        let cues = VisualListeningCueResolver.imageCues(
            blocks: orderedBlocks, blocksByID: blocksByID, timeline: timeline,
            currentTrackSegmentKey: track.segmentKey,
            currentTrackChapterIndices: track.chapterIndices,
            syncPoint: syncPoint)
        for cue in cues {
            times.insert(cue.displayStartTime)
            times.insert(cue.displayEndTime)
        }
        if mode == .karaoke {
            let scopedBlockIDs = Set(scopedRows.map(\.blockID))
            for word in words where scopedBlockIDs.contains(word.blockID) {
                times.insert(word.start)
                times.insert(word.end)
            }
        }
        return times.filter { $0 >= 0 && $0 <= track.duration }.sorted()
    }

    /// Appends a frame, extending the previous frame instead when nothing
    /// visible changed (turns dense boundary sampling into sparse output).
    private static func appendMerging(
        _ frame: SlideshowFramePlan, to frames: inout [SlideshowFramePlan]
    ) {
        if let last = frames.last,
            last.imagePath == frame.imagePath,
            last.caption == frame.caption,
            last.subtitleText == frame.subtitleText,
            last.activeWordIndex == frame.activeWordIndex,
            last.alreadyHeardWordCount == frame.alreadyHeardWordCount,
            abs(last.startTime + last.duration - frame.startTime) < 0.001
        {
            frames[frames.count - 1] = SlideshowFramePlan(
                startTime: last.startTime,
                duration: last.duration + frame.duration,
                imagePath: last.imagePath, caption: last.caption,
                subtitleText: last.subtitleText,
                activeWordIndex: last.activeWordIndex,
                alreadyHeardWordCount: last.alreadyHeardWordCount)
            return
        }
        frames.append(frame)
    }

    // MARK: - SRT

    /// Splits one timeline row's block text into cues of at most
    /// `maxCueLength` characters. Cue windows come from word timings when the
    /// block's sorted word rows match its display tokens 1:1 (the same
    /// positional mapping `VisualListeningCueResolver.subtitleCue` uses);
    /// otherwise the row window is divided proportionally by character count.
    private static func splitCues(
        forRow row: ReaderActiveBlockResolver.TimelineRow,
        blocksByID: [String: EPubBlockRecord],
        words: [ReaderActiveBlockResolver.WordRow],
        offset: TimeInterval
    ) -> [SlideshowSRTCue] {
        guard let text = blocksByID[row.blockID]?.text, !text.isEmpty else { return [] }
        let tokenRanges = WordTokenizer.wordRanges(in: text)
        guard !tokenRanges.isEmpty else {
            return [SlideshowSRTCue(
                startTime: offset + row.start, endTime: offset + row.end, text: text)]
        }

        // Greedily pack whole words into ≤ maxCueLength chunks.
        var chunks: [(tokens: Range<Int>, text: String)] = []
        var chunkStart = 0
        for index in tokenRanges.indices {
            let candidate = String(
                text[tokenRanges[chunkStart].lowerBound..<tokenRanges[index].upperBound])
            if candidate.count > maxCueLength, index > chunkStart {
                let chunkText = String(
                    text[tokenRanges[chunkStart].lowerBound..<tokenRanges[index - 1].upperBound])
                chunks.append((tokens: chunkStart..<index, text: chunkText))
                chunkStart = index
            }
        }
        let tailText = String(
            text[tokenRanges[chunkStart].lowerBound..<tokenRanges[tokenRanges.count - 1].upperBound])
        chunks.append((tokens: chunkStart..<tokenRanges.count, text: tailText))

        let blockWords = words
            .filter { $0.blockID == row.blockID }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.wordIndex < rhs.wordIndex }
                return lhs.start < rhs.start
            }
        let wordsMatchTokens = blockWords.count == tokenRanges.count

        var cues: [SlideshowSRTCue] = []
        var cursor = row.start
        let totalCharacters = chunks.reduce(0) { $0 + $1.text.count }
        for (index, chunk) in chunks.enumerated() {
            let end: TimeInterval
            if index == chunks.count - 1 {
                end = row.end
            } else if wordsMatchTokens {
                end = min(row.end, blockWords[chunk.tokens.upperBound - 1].end)
            } else {
                let fraction = Double(chunk.text.count) / Double(max(1, totalCharacters))
                end = min(row.end, cursor + (row.end - row.start) * fraction)
            }
            cues.append(SlideshowSRTCue(
                startTime: offset + cursor, endTime: offset + max(cursor, end),
                text: chunk.text))
            cursor = max(cursor, end)
        }
        return cues
    }

    // MARK: - Range clamping

    private static func clamp(
        _ plan: SlideshowExportPlan, to range: Range<TimeInterval>
    ) -> SlideshowExportPlan {
        let frames = plan.frames.compactMap { frame -> SlideshowFramePlan? in
            let start = max(frame.startTime, range.lowerBound)
            let end = min(frame.startTime + frame.duration, range.upperBound)
            guard end > start else { return nil }
            return SlideshowFramePlan(
                startTime: start - range.lowerBound, duration: end - start,
                imagePath: frame.imagePath, caption: frame.caption,
                subtitleText: frame.subtitleText,
                activeWordIndex: frame.activeWordIndex,
                alreadyHeardWordCount: frame.alreadyHeardWordCount)
        }
        let cues = plan.srtCues.compactMap { cue -> SlideshowSRTCue? in
            let start = max(cue.startTime, range.lowerBound)
            let end = min(cue.endTime, range.upperBound)
            guard end > start else { return nil }
            return SlideshowSRTCue(
                startTime: start - range.lowerBound, endTime: end - range.lowerBound,
                text: cue.text)
        }
        return SlideshowExportPlan(
            frames: frames, srtCues: cues,
            totalDuration: range.upperBound - range.lowerBound)
    }
}
```

- [x] **Step 5: Run focused tests until green**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/SlideshowExportPlannerTests
```

Expected: all `SlideshowExportPlannerTests` PASS. Also run the resolver suite (visibility change must not regress it):

```bash
make test-only FILTER=EchoTests/VisualListeningCueResolverTests
```

- [x] **Step 6: Commit**

```bash
git add Shared/VisualListeningCueResolver.swift Shared/SlideshowExportPlanner.swift EchoTests/SlideshowExportPlannerTests.swift
git commit -m "feat(shared): plan slideshow export frames and SRT cues"
```

---

## Task 2: SRTFormatter + SlideshowChapterMark (pure, Shared)

**Files:**
- Create: `Shared/SRTFormatter.swift`
- Test: `EchoTests/SRTFormatterTests.swift`

**Interfaces:**
- Consumes: `SlideshowSRTCue` (Task 1).
- Produces (used by Tasks 6, 7):

```swift
nonisolated struct SlideshowChapterMark: Equatable, Sendable {
    let startTime: TimeInterval
    let title: String
}
nonisolated enum SRTFormatter {
    static func timestamp(_ time: TimeInterval) -> String            // "01:02:03,456"
    static func srtDocument(cues: [SlideshowSRTCue]) -> String
    static func chapterTimestamp(_ time: TimeInterval) -> String     // "01:02:03"
    static func chaptersDocument(marks: [SlideshowChapterMark]) -> String
}
```

- [x] **Step 1: Write failing tests**

Create `EchoTests/SRTFormatterTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct SRTFormatterTests {
    @Test func timestampFormatsHoursMinutesSecondsMilliseconds() {
        #expect(SRTFormatter.timestamp(0) == "00:00:00,000")
        #expect(SRTFormatter.timestamp(3723.456) == "01:02:03,456")
        #expect(SRTFormatter.timestamp(59.9999) == "00:00:59,999")  // never rounds into 60
    }

    @Test func srtDocumentNumbersAndSeparatesCues() {
        let cues = [
            SlideshowSRTCue(startTime: 0, endTime: 2.5, text: "First line."),
            SlideshowSRTCue(startTime: 2.5, endTime: 5, text: "Second line."),
        ]
        let expected = """
            1
            00:00:00,000 --> 00:00:02,500
            First line.

            2
            00:00:02,500 --> 00:00:05,000
            Second line.
            """ + "\n"
        #expect(SRTFormatter.srtDocument(cues: cues) == expected)
    }

    @Test func srtDocumentIsEmptyForNoCues() {
        #expect(SRTFormatter.srtDocument(cues: []) == "")
    }

    @Test func chaptersDocumentUsesYouTubeTimestampLines() {
        let marks = [
            SlideshowChapterMark(startTime: 0, title: "Opening"),
            SlideshowChapterMark(startTime: 3723, title: "The Middle"),
        ]
        let expected = """
            00:00:00 Opening
            01:02:03 The Middle
            """ + "\n"
        #expect(SRTFormatter.chaptersDocument(marks: marks) == expected)
    }
}
```

- [x] **Step 2: Run to verify failure**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile FAILURE — `SRTFormatter` not defined.

- [x] **Step 3: Implement**

Create `Shared/SRTFormatter.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One chapter boundary in the exported video's global timeline. Produced by
/// `VideoExportService`'s audio-assembly loop; formatted here.
nonisolated struct SlideshowChapterMark: Equatable, Sendable {
    let startTime: TimeInterval
    let title: String
}

/// Pure text formatting for the sidecar `.srt` and `.chapters.txt` outputs.
/// SRT timestamps are `HH:MM:SS,mmm`; chapters lines use the YouTube
/// description convention (`HH:MM:SS Title`).
nonisolated enum SRTFormatter {
    static func timestamp(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let totalMilliseconds = Int((clamped * 1000).rounded(.down))
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        return String(
            format: "%02d:%02d:%02d,%03d",
            totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, milliseconds)
    }

    static func chapterTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(0, time).rounded(.down))
        return String(
            format: "%02d:%02d:%02d",
            totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }

    static func srtDocument(cues: [SlideshowSRTCue]) -> String {
        guard !cues.isEmpty else { return "" }
        return cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(timestamp(cue.startTime)) --> \(timestamp(cue.endTime))
            \(cue.text)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    static func chaptersDocument(marks: [SlideshowChapterMark]) -> String {
        guard !marks.isEmpty else { return "" }
        return marks.map { "\(chapterTimestamp($0.startTime)) \($0.title)" }
            .joined(separator: "\n") + "\n"
    }
}
```

Note: `String(format:)` is acceptable here — these are wire-format timestamps with locale-independent fixed layouts, not user-facing numerals, so `FormatStyle` (locale-aware) would be wrong.

- [x] **Step 4: Run focused tests until green**

```bash
make test-only FILTER=EchoTests/SRTFormatterTests
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add Shared/SRTFormatter.swift EchoTests/SRTFormatterTests.swift
git commit -m "feat(shared): format SRT and chapters.txt documents"
```

---

## Task 3: VisualListeningImageLocator extraction

**Files:**
- Create: `Shared/VisualListeningImageLocator.swift`
- Modify: `EchoCore/Views/VisualListeningStageView.swift` (`visualListeningImage(at:)`, ~line 85)
- Test: `EchoTests/VisualListeningImageLocatorTests.swift`

**Interfaces:**
- Produces (used by Task 5's renderer and the live stage):

```swift
nonisolated enum VisualListeningImageLocator {
    /// Resolves a stored (possibly stale-absolute) EPUB asset path to an
    /// existing file URL: the path itself, else the same dir/filename tail
    /// under the current EPUBAssets container. `nil` when neither exists.
    static func resolvedURL(forStoredPath imagePath: String) -> URL?
}
```

- [x] **Step 1: Write failing tests**

Create `EchoTests/VisualListeningImageLocatorTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct VisualListeningImageLocatorTests {
    @Test func returnsStoredPathWhenFileExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("figure.jpg")
        try Data([0xFF]).write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(VisualListeningImageLocator.resolvedURL(forStoredPath: file.path) == file)
    }

    @Test func fallsBackToEPUBAssetsContainerForStalePath() throws {
        let assetsDir = FileLocations.applicationSupportDirectory
            .appendingPathComponent("EPUBAssets")
            .appendingPathComponent("locator-test-book")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let real = assetsDir.appendingPathComponent("figure.jpg")
        try Data([0xFF]).write(to: real)
        defer { try? FileManager.default.removeItem(at: assetsDir) }

        let stale = "/old/container/locator-test-book/figure.jpg"
        #expect(
            VisualListeningImageLocator.resolvedURL(forStoredPath: stale)?.lastPathComponent
                == "figure.jpg")
    }

    @Test func returnsNilWhenNothingExists() {
        #expect(
            VisualListeningImageLocator.resolvedURL(
                forStoredPath: "/nowhere/never-book/missing.jpg") == nil)
    }
}
```

- [x] **Step 2: Run to verify failure**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile FAILURE — `VisualListeningImageLocator` not defined.

- [x] **Step 3: Implement, moving the stage view's logic**

Create `Shared/VisualListeningImageLocator.swift` (this is the exact fallback logic currently inlined in `VisualListeningStageView.visualListeningImage(at:)`, made shared so export and playback resolve images identically):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves stored EPUB image asset paths. Paths are persisted absolute at
/// import time, so a moved/reinstalled app container leaves stale prefixes;
/// the fallback re-roots `<dir>/<filename>` under the current EPUBAssets
/// container — the same recovery the live stage has always used.
nonisolated enum VisualListeningImageLocator {
    static func resolvedURL(forStoredPath imagePath: String) -> URL? {
        let stored = URL(fileURLWithPath: imagePath)
        if FileManager.default.fileExists(atPath: stored.path) { return stored }

        let filename = stored.lastPathComponent
        let dirName = stored.deletingLastPathComponent().lastPathComponent
        let fallback = FileLocations.applicationSupportDirectory
            .appendingPathComponent("EPUBAssets")
            .appendingPathComponent(dirName)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
```

In `EchoCore/Views/VisualListeningStageView.swift`, replace the body of `visualListeningImage(at:)`:

```swift
    private func visualListeningImage(at imagePath: String) -> UIImage? {
        guard let url = VisualListeningImageLocator.resolvedURL(forStoredPath: imagePath)
        else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
```

Behavioral note: the old code passed the (possibly nonexistent) fallback path to `UIImage(contentsOfFile:)` and got `nil`; the locator returns `nil` explicitly — same observable behavior, now testable.

- [x] **Step 4: Run focused tests until green**

```bash
make test-only FILTER=EchoTests/VisualListeningImageLocatorTests
make test-only FILTER=EchoTests/NowPlayingLayoutTests
```

Expected: both PASS (`NowPlayingLayoutTests` guards the stage view wiring).

- [x] **Step 5: Commit**

```bash
git add Shared/VisualListeningImageLocator.swift EchoCore/Views/VisualListeningStageView.swift EchoTests/VisualListeningImageLocatorTests.swift
git commit -m "refactor(shared): extract visual listening image path resolution"
```

---

## Task 4: TimelineRowLoader extraction

**Files:**
- Create: `Shared/Database/TimelineRowLoader.swift`
- Modify: `EchoCore/ViewModels/VisualListeningViewModel.swift` (delete its private `loadTimelineRows`, call the loader)
- Test: covered by the existing `EchoTests/VisualListeningViewModelTests` (behavior must not change) plus one direct test

**Interfaces:**
- Produces (used by Task 6):

```swift
nonisolated enum TimelineRowLoader {
    static func rows(
        audiobookID: String, db: DatabaseWriter
    ) throws -> [ReaderActiveBlockResolver.TimelineRow]
}
```

- [x] **Step 1: Write the direct test**

Create/extend `EchoTests/TimelineRowLoaderTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct TimelineRowLoaderTests {
    @Test func loadsRowsWithDerivedEndTimesAndChapterIndex() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES ('b1', 'book', 's', 0, 0, 0, 'paragraph', 'Hello', 2, 0)
                    """)
            try database.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, epub_block_id, audio_start_time, audio_end_time, segment_key)
                    VALUES ('t1', 'book', 'b1', 1.0, NULL, '2-0')
                    """)
        }

        let rows = try TimelineRowLoader.rows(audiobookID: "book", db: db.writer)
        #expect(rows.count == 1)
        #expect(rows[0].start == 1.0)
        #expect(rows[0].end == 3601.0)  // NULL end, no next row → start + 3600 fallback
        #expect(rows[0].blockID == "b1")
        #expect(rows[0].chapterIndex == 2)
        #expect(rows[0].segmentKey == "2-0")
    }
}
```

If the `timeline_item` insert fails on missing NOT NULL columns, copy the exact insert helper used by `EchoTests/VisualListeningViewModelTests` (same table, proven columns) instead of the SQL above — the assertion block stays identical.

- [x] **Step 2: Run to verify failure**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile FAILURE — `TimelineRowLoader` not defined.

- [x] **Step 3: Implement by moving code**

Create `Shared/Database/TimelineRowLoader.swift` containing the exact query + row-mapping currently in `VisualListeningViewModel.loadTimelineRows` (`EchoCore/ViewModels/VisualListeningViewModel.swift:91`-ish), wrapped as:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Loads reader timeline rows (audio ranges → EPUB blocks) for one book.
/// Extracted from `VisualListeningViewModel` so the video exporter and the
/// live stage run the identical query, including the derived-end policy:
/// NULL `audio_end_time` closes at the next row's start, else +3600s.
nonisolated enum TimelineRowLoader {
    static func rows(
        audiobookID: String, db: DatabaseWriter
    ) throws -> [ReaderActiveBlockResolver.TimelineRow] {
        // (body: verbatim move of VisualListeningViewModel.loadTimelineRows)
    }
}
```

Then in `VisualListeningViewModel.reload()` replace `try Self.loadTimelineRows(audiobookID: audiobookID, db: db)` with `try TimelineRowLoader.rows(audiobookID: audiobookID, db: db)` and delete the private method.

- [x] **Step 4: Run focused tests until green**

```bash
make test-only FILTER=EchoTests/TimelineRowLoaderTests
make test-only FILTER=EchoTests/VisualListeningViewModelTests
```

Expected: both PASS (the VM suite proves the move changed nothing).

- [x] **Step 5: Commit**

```bash
git add Shared/Database/TimelineRowLoader.swift EchoCore/ViewModels/VisualListeningViewModel.swift EchoTests/TimelineRowLoaderTests.swift
git commit -m "refactor(shared): extract timeline row loading for reuse"
```

---

## Task 5: SlideshowFrameRenderer (CoreGraphics, EchoCore)

**Files:**
- Create: `EchoCore/Services/Export/SlideshowFrameRenderer.swift`
- Test: `EchoTests/SlideshowFrameRendererTests.swift`

**Interfaces:**
- Consumes: `SlideshowFramePlan` (Task 1), `VisualListeningImageLocator` (Task 3), `WordTokenizer.wordRanges(in:)`.
- Produces (used by Task 6):

```swift
nonisolated final class SlideshowFrameRenderer {
    init(width: Int, height: Int, coverArt: CGImage?)
    func render(_ frame: SlideshowFramePlan) -> CGImage?
}
```

**Import rules:** `import CoreGraphics`, `import CoreText`, `import Foundation`, `import ImageIO` only. NO UIKit/AppKit/SwiftUI — this file compiles into iOS, macOS, and echo-cli targets.

- [x] **Step 1: Write failing smoke tests**

Create `EchoTests/SlideshowFrameRendererTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Testing

@testable import Echo

struct SlideshowFrameRendererTests {
    private func frame(
        subtitle: String? = "Hello world of tests",
        activeWord: Int? = nil, heard: Int = 0, imagePath: String? = nil
    ) -> SlideshowFramePlan {
        SlideshowFramePlan(
            startTime: 0, duration: 1, imagePath: imagePath, caption: "A caption",
            subtitleText: subtitle, activeWordIndex: activeWord,
            alreadyHeardWordCount: heard)
    }

    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.height * context.bytesPerRow)
    }

    @Test func rendersFrameAtRequestedSize() {
        let renderer = SlideshowFrameRenderer(width: 640, height: 360, coverArt: nil)
        let image = renderer.render(frame())
        #expect(image?.width == 640)
        #expect(image?.height == 360)
    }

    @Test func renderedFrameIsNotBlank() throws {
        let renderer = SlideshowFrameRenderer(width: 320, height: 180, coverArt: nil)
        let image = try #require(renderer.render(frame()))
        let distinct = Set(pixels(image))
        #expect(distinct.count > 2)  // background + at least one text shade
    }

    @Test func activeWordChangesThePixels() throws {
        let renderer = SlideshowFrameRenderer(width: 320, height: 180, coverArt: nil)
        let a = try #require(renderer.render(frame(activeWord: 0, heard: 0)))
        let b = try #require(renderer.render(frame(activeWord: 2, heard: 2)))
        #expect(pixels(a) != pixels(b))
    }

    @Test func missingImagePathFallsBackToCoverArtWithoutFailing() throws {
        let cover = try #require(Self.solidImage(width: 4, height: 4))
        let renderer = SlideshowFrameRenderer(width: 320, height: 180, coverArt: cover)
        let withMissing = renderer.render(frame(imagePath: "/nowhere/gone-book/x.jpg"))
        #expect(withMissing != nil)
    }

    private static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.2, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}
```

- [x] **Step 2: Run to verify failure**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile FAILURE — `SlideshowFrameRenderer` not defined.

- [x] **Step 3: Implement**

Create `EchoCore/Services/Export/SlideshowFrameRenderer.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Rasterizes one `SlideshowFramePlan` into a `CGImage` matching the Visual
/// Listening stage's structure: dark background, aspect-fit figure (cover art
/// when the plan has no figure), caption beneath it, subtitle band at the
/// bottom with heard-wash / active-word emphasis.
///
/// CoreGraphics/CoreText only — compiles for iOS, macOS, and echo-cli.
/// Performance contract: the composed base (background + figure + caption) is
/// cached per (imagePath, caption) pair; only the subtitle band is redrawn per
/// frame, which is what keeps ~160k-frame karaoke renders tractable.
nonisolated final class SlideshowFrameRenderer {
    private let width: Int
    private let height: Int
    private let coverArt: CGImage?
    private var cachedBase: (key: String, image: CGImage)?

    init(width: Int, height: Int, coverArt: CGImage?) {
        self.width = width
        self.height = height
        self.coverArt = coverArt
    }

    func render(_ frame: SlideshowFramePlan) -> CGImage? {
        guard let context = makeContext() else { return nil }
        let baseKey = "\(frame.imagePath ?? "<cover>")|\(frame.caption ?? "")"
        let base: CGImage?
        if let cachedBase, cachedBase.key == baseKey {
            base = cachedBase.image
        } else {
            base = renderBase(imagePath: frame.imagePath, caption: frame.caption)
            if let base { cachedBase = (key: baseKey, image: base) }
        }
        if let base {
            context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        drawSubtitle(frame, in: context)
        return context.makeImage()
    }

    // MARK: - Base layer

    private func makeContext() -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func renderBase(imagePath: String?, caption: String?) -> CGImage? {
        guard let context = makeContext() else { return nil }
        context.setFillColor(CGColor(red: 0.063, green: 0.063, blue: 0.078, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let figure = imagePath.flatMap(Self.loadImage(storedPath:)) ?? coverArt
        // Figure area: horizontally centered, between the caption band and the
        // top margin. Subtitle band ≈ bottom 18%, caption band ≈ next 8%.
        let margin = CGFloat(height) * 0.05
        let figureRect = CGRect(
            x: margin, y: CGFloat(height) * 0.26 + margin,
            width: CGFloat(width) - margin * 2,
            height: CGFloat(height) * 0.74 - margin * 2)
        if let figure {
            context.draw(figure, in: Self.aspectFit(size: figure, into: figureRect))
        }
        if let caption, !caption.isEmpty {
            Self.drawText(
                caption, in: context,
                rect: CGRect(
                    x: margin, y: CGFloat(height) * 0.18,
                    width: CGFloat(width) - margin * 2, height: CGFloat(height) * 0.08),
                fontSize: CGFloat(height) * 0.024, weightBold: false,
                color: CGColor(gray: 1, alpha: 0.7), centered: true)
        }
        return context.makeImage()
    }

    private static func loadImage(storedPath: String) -> CGImage? {
        guard let url = VisualListeningImageLocator.resolvedURL(forStoredPath: storedPath),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func aspectFit(size image: CGImage, into rect: CGRect) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
    }

    // MARK: - Subtitle band

    private func drawSubtitle(_ frame: SlideshowFramePlan, in context: CGContext) {
        guard let text = frame.subtitleText, !text.isEmpty else { return }
        let margin = CGFloat(height) * 0.05
        let band = CGRect(
            x: margin, y: margin,
            width: CGFloat(width) - margin * 2, height: CGFloat(height) * 0.18 - margin)
        let fontSize = CGFloat(height) * 0.030
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil),
                .foregroundColor: CGColor(gray: 1, alpha: 0.38),
            ])
        let bold = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let ranges = WordTokenizer.wordRanges(in: text)
        for (index, range) in ranges.enumerated() {
            let nsRange = NSRange(range, in: text)
            if index < frame.alreadyHeardWordCount {
                attributed.addAttribute(
                    .foregroundColor, value: CGColor(gray: 1, alpha: 0.65), range: nsRange)
            }
            if index == frame.activeWordIndex {
                attributed.addAttributes(
                    [.font: bold, .foregroundColor: CGColor(gray: 1, alpha: 1)],
                    range: nsRange)
            }
        }
        Self.draw(attributed, in: context, rect: band, centered: true)
    }

    // MARK: - CoreText plumbing

    private static func drawText(
        _ text: String, in context: CGContext, rect: CGRect,
        fontSize: CGFloat, weightBold: Bool, color: CGColor, centered: Bool
    ) {
        let fontName = weightBold ? "HelveticaNeue-Bold" : "HelveticaNeue"
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName(fontName as CFString, fontSize, nil),
                .foregroundColor: color,
            ])
        draw(attributed, in: context, rect: rect, centered: centered)
    }

    private static func draw(
        _ attributed: NSAttributedString, in context: CGContext,
        rect: CGRect, centered: Bool
    ) {
        let styled = NSMutableAttributedString(attributedString: attributed)
        if centered {
            var alignment = CTTextAlignment.center
            var setting = CTParagraphStyleSetting(
                spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                value: &alignment)
            let paragraph = CTParagraphStyleCreate(&setting, 1)
            styled.addAttribute(
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String),
                value: paragraph, range: NSRange(location: 0, length: styled.length))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(styled)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: styled.length), path, nil)
        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
```

Note on `NSAttributedString` + `.font`/`.foregroundColor` keys with CoreText: use `kCTFontAttributeName`/`kCTForegroundColorAttributeName` casts if the Foundation keys don't carry through `CTFramesetter` on a non-UIKit target — this is the one spot where the implementer may need to swap `NSAttributedString.Key.font` → `NSAttributedString.Key(kCTFontAttributeName as String)` (same structure, different key constant). The tests catch it: text that doesn't render leaves the frame blank and `renderedFrameIsNotBlank` fails.

- [x] **Step 4: Run focused tests until green**

```bash
make test-only FILTER=EchoTests/SlideshowFrameRendererTests
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add EchoCore/Services/Export/SlideshowFrameRenderer.swift EchoTests/SlideshowFrameRendererTests.swift
git commit -m "feat(export): render slideshow frames with CoreGraphics"
```

---

## Task 6: VideoExportService (actor, EchoCore)

**Files:**
- Create: `EchoCore/Services/Export/VideoExportService.swift`
- Test: `EchoTests/VideoExportServiceTests.swift`

**Interfaces:**
- Consumes: `ExportSourceResolver.resolve(audiobookID:databaseWriter:cacheDirectory:)`, `ExportSource.items()` → `[ExportItem]` (`title`, `url`, `timeRange`, `emitsChapterMarker`), `ExportMetadataResolver.resolve(audiobookID:fallbackTitle:firstSourceURL:databaseWriter:)` → `ExportMetadata` (`title`, `author`, `coverArt: Data?`), `TimelineRowLoader.rows(audiobookID:db:)` (Task 4), `EPubBlockDAO(db:).visibleBlocks(for:)`, `WordTimingDAO(db:).words(forAudiobook:)` (fields `audioStartTime`, `audioEndTime`, `epubBlockID`, `wordIndex`), `SlideshowExportPlanner.plan(...)` (Task 1), `SlideshowFrameRenderer` (Task 5), `SRTFormatter` + `SlideshowChapterMark` (Task 2), `ChapterMarkerWriter().writeChapters(_:to:outputURL:metadata:replaceExistingBookMetadata:)`, `NarrationFileNaming.chapterIndex(fromFileName:)` / `.segmentLocation(fromFileName:)`, `ReaderActiveBlockResolver.trackChapterScope(trackCount:isMultiM4B:currentIndex:playingChapterIndex:)` / `.segmentKey(forChapter:segment:)`.
- Produces (used by Tasks 7, 9, 10):

```swift
actor VideoExportService {
    enum ExportError: Error { case noAudio, noAlignment, writerFailed }
    struct Output: Sendable {
        let videoURL: URL
        let srtURL: URL
        let chaptersURL: URL
    }
    func exportVideo(
        audiobookID: String,
        bookTitle: String,
        databaseWriter: DatabaseWriter,
        cacheDirectory: URL,
        outputDirectory: URL,
        mode: SlideshowExportMode = .karaoke,
        syncPoint: VisualListeningSyncPoint = .midpoint,
        width: Int = 1920,
        height: Int = 1080,
        range: Range<TimeInterval>? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output
    // Pure, unit-tested helper:
    static func trackContexts(
        items: [ExportItem], measuredDurations: [TimeInterval]
    ) -> [SlideshowTrackContext]
}
```

- [x] **Step 1: Write failing tests**

Create `EchoTests/VideoExportServiceTests.swift`. Two layers: pure `trackContexts` tests, and one end-to-end integration test with a synthesized fixture.

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
import Testing

@testable import Echo

struct VideoExportServiceTests {
    // MARK: - trackContexts (pure)

    @Test func narratedChapterFilesBecomeOneContextEachWithScope() {
        let items = [
            ExportItem(
                title: "Chapter 1",
                url: URL(fileURLWithPath: "/cache/book_ch1_v3_af.m4a"), timeRange: nil),
            ExportItem(
                title: "Chapter 2",
                url: URL(fileURLWithPath: "/cache/book_ch2_v3_af.m4a"), timeRange: nil),
        ]
        let contexts = VideoExportService.trackContexts(
            items: items, measuredDurations: [10, 20])
        #expect(contexts.count == 2)
        #expect(contexts[0].duration == 10)
        #expect(contexts[1].duration == 20)
        // Scope must match what the live player derives for these filenames:
        // chapterIndex parsed from the narration filename scopes the track.
        let expected0 = NarrationFileNaming.chapterIndex(fromFileName: "book_ch1_v3_af.m4a")
        if let expected0 { #expect(contexts[0].chapterIndices == [expected0]) }
    }

    @Test func singleFileM4BSlicesCollapseToOneWholeFileContext() {
        let url = URL(fileURLWithPath: "/books/whole.m4b")
        let items = [
            ExportItem(
                title: "One", url: url,
                timeRange: CMTimeRange(
                    start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600))),
            ExportItem(
                title: "Two", url: url,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 30, preferredTimescale: 600),
                    duration: CMTime(seconds: 45, preferredTimescale: 600))),
        ]
        let contexts = VideoExportService.trackContexts(
            items: items, measuredDurations: [30, 45])
        #expect(contexts.count == 1)
        #expect(contexts[0].duration == 75)  // slices sum into whole-file time
        #expect(contexts[0].segmentKey == nil)
        #expect(contexts[0].chapterIndices == nil)  // whole-book scope, like 1-track playback
    }

    // MARK: - Integration

    @Test func exportsVideoSRTAndChaptersFromSeededFixture() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // 1. Synthesize 4 seconds of audio (real, decodable file).
        let audioURL = workDir.appendingPathComponent("track1.m4a")
        try await Self.writeToneFile(to: audioURL, seconds: 4)

        // 2. Seed the database: one track, two text blocks, timeline rows.
        let db = try DatabaseService(inMemory: ())
        let bookID = "video-test-book"
        try db.writer.write { database in
            var track = TrackRecord(
                id: "t1", audiobookID: bookID, title: "Chapter 1", duration: 4,
                filePath: audioURL.absoluteString, isEnabled: true, sortOrder: 0,
                playlistPosition: nil)
            try track.insert(database)
            try database.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES
                      ('b1', ?, 's', 0, 0, 0, 'paragraph', 'Opening words spoken aloud.', 0, 0),
                      ('b2', ?, 's', 0, 1, 1, 'paragraph', 'Closing words follow after.', 0, 0)
                    """, arguments: [bookID, bookID])
            try database.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, epub_block_id, audio_start_time, audio_end_time)
                    VALUES
                      ('ti1', ?, 'b1', 0.0, 2.0),
                      ('ti2', ?, 'b2', 2.0, 4.0)
                    """, arguments: [bookID, bookID])
        }
        // (If either insert trips a NOT NULL constraint, mirror the proven insert
        // helpers in VisualListeningViewModelTests — same tables — and keep the
        // values above.)

        // 3. Export.
        let output = try await VideoExportService().exportVideo(
            audiobookID: bookID,
            bookTitle: "Video Test Book",
            databaseWriter: db.writer,
            cacheDirectory: workDir.appendingPathComponent("no-cache"),
            outputDirectory: workDir,
            mode: .simple,
            syncPoint: .begin,
            width: 320, height: 180)

        // 4. Assert the bundle.
        #expect(FileManager.default.fileExists(atPath: output.videoURL.path))
        let asset = AVURLAsset(url: output.videoURL)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 4) < 0.5)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(!videoTracks.isEmpty)
        #expect(!audioTracks.isEmpty)

        let srt = try String(contentsOf: output.srtURL, encoding: .utf8)
        #expect(srt.contains("Opening words spoken aloud."))
        #expect(srt.contains("00:00:02,000 --> 00:00:04,000"))

        let chapters = try String(contentsOf: output.chaptersURL, encoding: .utf8)
        #expect(chapters.contains("00:00:00 Chapter 1"))
    }

    /// Writes a real AAC audio file of `seconds` silence-with-tone so
    /// AVAssetReader has something to decode.
    private static func writeToneFile(to url: URL, seconds: Double) async throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] =
                sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate)) * 0.2
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ])
        try file.write(from: buffer)
    }
}
```

- [x] **Step 2: Run to verify failure**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile FAILURE — `VideoExportService` not defined.

- [x] **Step 3: Implement the service**

Create `EchoCore/Services/Export/VideoExportService.swift`. Full structure (the pump section is the only genuinely tricky part — it is written out completely):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import os.log

/// Whole-book slideshow video exporter: mp4 (H.264 + AAC) with sparse,
/// variable-duration frames from `SlideshowExportPlanner`, plus sidecar `.srt`
/// and `.chapters.txt`. Sibling of `AudioExportService` — audio comes from the
/// same `ExportSource` spine, chapter marks from the same accumulation loop.
actor VideoExportService {
    enum ExportError: Error {
        case noAudio          // no local source files (e.g. ABS-only book)
        case noAlignment      // no timeline rows — book needs alignment/narration
        case writerFailed
    }

    struct Output: Sendable {
        let videoURL: URL
        let srtURL: URL
        let chaptersURL: URL
    }

    private let logger = Logger(category: "VideoExport")

    func exportVideo(
        audiobookID: String,
        bookTitle: String,
        databaseWriter: DatabaseWriter,
        cacheDirectory: URL,
        outputDirectory: URL,
        mode: SlideshowExportMode = .karaoke,
        syncPoint: VisualListeningSyncPoint = .midpoint,
        width: Int = 1920,
        height: Int = 1080,
        range: Range<TimeInterval>? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Output {
        // ---- 1. Gather inputs (fail fast, before any rendering). ----
        let source = ExportSourceResolver.resolve(
            audiobookID: audiobookID, databaseWriter: databaseWriter,
            cacheDirectory: cacheDirectory)
        let items: [ExportItem]
        do { items = try await source.items() } catch { throw ExportError.noAudio }
        guard !items.isEmpty else { throw ExportError.noAudio }

        let timeline = try TimelineRowLoader.rows(audiobookID: audiobookID, db: databaseWriter)
        guard !timeline.isEmpty else { throw ExportError.noAlignment }
        let blocks = try EPubBlockDAO(db: databaseWriter).visibleBlocks(for: audiobookID)
        let words: [ReaderActiveBlockResolver.WordRow] =
            (try? WordTimingDAO(db: databaseWriter).words(forAudiobook: audiobookID))?
            .map {
                (start: $0.audioStartTime, end: $0.audioEndTime,
                 blockID: $0.epubBlockID, wordIndex: $0.wordIndex)
            } ?? []

        // Security-scope every distinct source URL for the whole export
        // (same pattern + rationale as AudioExportService.exportM4B).
        let urls = Set(items.map(\.url))
        var scoped: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() { scoped.append(url) }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        // ---- 2. Audio composition + measured durations + chapter marks. ----
        let composition = AVMutableComposition()
        guard
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.writerFailed }
        var position = CMTime.zero
        var measuredDurations: [TimeInterval] = []
        var chapterMarks: [SlideshowChapterMark] = []
        for item in items {
            let asset = AVURLAsset(url: item.url)
            let full = try await asset.load(.duration)
            let itemRange = item.timeRange ?? CMTimeRange(start: .zero, duration: full)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            try audioTrack.insertTimeRange(itemRange, of: sourceTrack, at: position)
            if item.emitsChapterMarker {
                chapterMarks.append(
                    SlideshowChapterMark(startTime: position.seconds, title: item.title))
            }
            measuredDurations.append(itemRange.duration.seconds)
            position = CMTimeAdd(position, itemRange.duration)
        }
        if let range {
            let end = CMTime(seconds: range.upperBound, preferredTimescale: 600)
            if end < position {
                composition.removeTimeRange(
                    CMTimeRange(start: end, duration: CMTimeSubtract(position, end)))
            }
            let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600)
            if start > .zero {
                composition.removeTimeRange(CMTimeRange(start: .zero, duration: start))
            }
            chapterMarks = chapterMarks.compactMap { mark in
                let shifted = mark.startTime - range.lowerBound
                guard shifted >= 0, shifted < range.upperBound - range.lowerBound
                else { return nil }
                return SlideshowChapterMark(startTime: shifted, title: mark.title)
            }
        }

        // ---- 3. Plan. ----
        let contexts = Self.trackContexts(items: items, measuredDurations: measuredDurations)
        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: timeline, words: words, tracks: contexts,
            mode: mode, syncPoint: syncPoint, range: range)
        guard !plan.frames.isEmpty, plan.totalDuration > 0 else { throw ExportError.noAlignment }

        // ---- 4. Cover art + renderer. ----
        let metadata = await ExportMetadataResolver.resolve(
            audiobookID: audiobookID, fallbackTitle: bookTitle,
            firstSourceURL: items.first?.url, databaseWriter: databaseWriter)
        let cover = metadata.coverArt.flatMap { data -> CGImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        let renderer = SlideshowFrameRenderer(width: width, height: height, coverArt: cover)

        // ---- 5. Write video+audio with AVAssetWriter. ----
        let safeTitle = SafeFileName.sanitizeForFilename(bookTitle)
        let tempMP4 = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: tempMP4) }
        try await writeMovie(
            plan: plan, renderer: renderer, audioComposition: composition,
            to: tempMP4, width: width, height: height, onProgress: onProgress)

        // ---- 6. Chapter atoms: attempt-and-verify, degrade silently. ----
        let videoURL = outputDirectory.appendingPathComponent("\(safeTitle).mp4")
        try? FileManager.default.removeItem(at: videoURL)
        var stamped = false
        if !chapterMarks.isEmpty {
            let atoms = chapterMarks.map { ChapterAtom(startTime: $0.startTime, title: $0.title) }
            do {
                try await ChapterMarkerWriter().writeChapters(
                    atoms, to: tempMP4, outputURL: videoURL, metadata: metadata)
                let groups = try await AVURLAsset(url: videoURL)
                    .loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"])
                stamped = !groups.isEmpty
            } catch {
                logger.info("mp4 chapter atoms unavailable: \(error.localizedDescription)")
                stamped = false
            }
        }
        if !stamped {
            try? FileManager.default.removeItem(at: videoURL)
            try FileManager.default.copyItem(at: tempMP4, to: videoURL)
        }

        // ---- 7. Sidecars. ----
        let srtURL = outputDirectory.appendingPathComponent("\(safeTitle).srt")
        try SRTFormatter.srtDocument(cues: plan.srtCues)
            .write(to: srtURL, atomically: true, encoding: .utf8)
        let chaptersURL = outputDirectory.appendingPathComponent("\(safeTitle).chapters.txt")
        try SRTFormatter.chaptersDocument(marks: chapterMarks)
            .write(to: chaptersURL, atomically: true, encoding: .utf8)

        onProgress(1.0)
        return Output(videoURL: videoURL, srtURL: srtURL, chaptersURL: chaptersURL)
    }

    // MARK: - Track contexts (pure)

    /// Groups consecutive `ExportItem`s by source URL into one timeline track
    /// each (narrated chapter files and multi-file imports are 1 item = 1
    /// track; a single-file m4b's chapter slices collapse into ONE whole-file
    /// track so per-track cue times keep matching the live player's), then
    /// derives the same scoping `PlayerModel+VisualListeningScope` computes.
    static func trackContexts(
        items: [ExportItem], measuredDurations: [TimeInterval]
    ) -> [SlideshowTrackContext] {
        struct Group { var title: String; var url: URL; var duration: TimeInterval }
        var groups: [Group] = []
        for (index, item) in items.enumerated() {
            let duration = index < measuredDurations.count ? measuredDurations[index] : 0
            if var last = groups.last, last.url == item.url {
                last.duration += duration
                groups[groups.count - 1] = last
            } else {
                groups.append(Group(title: item.title, url: item.url, duration: duration))
            }
        }
        let isMultiM4B =
            groups.count >= 2
            && groups.allSatisfy { $0.url.pathExtension.lowercased() == "m4b" }
        return groups.enumerated().map { index, group in
            let fileName = group.url.lastPathComponent
            let location = NarrationFileNaming.segmentLocation(fromFileName: fileName)
            let playingChapter =
                location?.chapterIndex ?? NarrationFileNaming.chapterIndex(fromFileName: fileName)
            let segmentKey = location.map {
                ReaderActiveBlockResolver.segmentKey(
                    forChapter: $0.chapterIndex, segment: $0.segmentIndex)
            }
            let chapterIndices = ReaderActiveBlockResolver.trackChapterScope(
                trackCount: groups.count, isMultiM4B: isMultiM4B,
                currentIndex: index, playingChapterIndex: playingChapter)
            return SlideshowTrackContext(
                title: group.title, duration: group.duration,
                segmentKey: segmentKey, chapterIndices: chapterIndices)
        }
    }

    // MARK: - Writer

    private func writeMovie(
        plan: SlideshowExportPlan,
        renderer: SlideshowFrameRenderer,
        audioComposition: AVComposition,
        to outputURL: URL,
        width: Int,
        height: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        writer.add(audioInput)

        let reader = try AVAssetReader(asset: audioComposition)
        let audioTracks = try await audioComposition.loadTracks(withMediaType: .audio)
        let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(readerOutput)

        guard writer.startWriting(), reader.startReading() else {
            throw ExportError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)

        // Pump both inputs concurrently; AVAssetWriter's readiness flags apply
        // interleaving backpressure, so neither task runs unboundedly ahead.
        // AVAssetWriterInput isn't Sendable, but appending to DIFFERENT inputs
        // from different tasks is AVFoundation's documented usage; the boxes
        // below scope that exception narrowly.
        nonisolated(unsafe) let videoBox = (input: videoInput, adaptor: adaptor)
        nonisolated(unsafe) let audioBox = (input: audioInput, output: readerOutput)
        let frames = plan.frames
        let total = plan.totalDuration

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for (index, frame) in frames.enumerated() {
                    try Task.checkCancellation()
                    guard let image = renderer.render(frame),
                        let buffer = Self.pixelBuffer(
                            from: image, pool: videoBox.adaptor.pixelBufferPool,
                            width: width, height: height)
                    else { throw ExportError.writerFailed }
                    while !videoBox.input.isReadyForMoreMediaData {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    videoBox.adaptor.append(
                        buffer,
                        withPresentationTime: CMTime(
                            seconds: frame.startTime, preferredTimescale: 600))
                    onProgress(0.05 + 0.9 * Double(index + 1) / Double(frames.count))
                }
                videoBox.input.markAsFinished()
            }
            group.addTask {
                while let sample = audioBox.output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    while !audioBox.input.isReadyForMoreMediaData {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    audioBox.input.append(sample)
                }
                audioBox.input.markAsFinished()
            }
            try await group.waitForAll()
        }

        writer.endSession(atSourceTime: CMTime(seconds: total, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.writerFailed
        }
    }

    private static func pixelBuffer(
        from image: CGImage, pool: CVPixelBufferPool?, width: Int, height: Int
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
```

Implementation notes:
- `SafeFileName.sanitizeForFilename(_:)` is the existing sanitizer in `Shared/SafeFileName.swift` — do not invent a new one.
- On cancellation (`Task.checkCancellation` throws), `writer` is abandoned and the `defer` removes `tempMP4`; the caller sees `CancellationError`. Partial named outputs are never created because naming happens after the writer succeeds.
- If `renderer` capture in the task group trips strict-concurrency (it's a non-Sendable class), render frames on the actor by hoisting `renderer.render(frame)` into a preceding `for` loop that yields `(CMTime, CVPixelBuffer)` through an `AsyncStream` consumed by the video task — but try the direct form first; `SlideshowFrameRenderer` is only touched from the single video task, so `nonisolated(unsafe) let rendererBox = renderer` with a comment is acceptable and simpler.

- [x] **Step 4: Run focused tests until green**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/VideoExportServiceTests
```

Expected: PASS (integration test included). If the integration test is flaky in the iOS simulator for AVFoundation-environment reasons (see `sim-keychain` precedent), it must still pass on the macOS test run in Task 8 — do not delete it, gate it with the same environment-guard pattern other AV-touching tests in the suite use, if any exists.

- [x] **Step 5: Commit**

```bash
git add EchoCore/Services/Export/VideoExportService.swift EchoTests/VideoExportServiceTests.swift
git commit -m "feat(export): whole-book slideshow video export service"
```

---

## Task 7: echo-cli export-video subcommand

**Files:**
- Create: `Tools/echo-cli/ExportVideoCommand.swift`
- Modify: `Tools/echo-cli/EchoCLI.swift` (register subcommand)

**Interfaces:**
- Consumes: `VideoExportService.exportVideo(...)` (Task 6), `DatabaseService(databaseURL:)`, `ExportSourceResolver.isNarrated(audiobookID:databaseWriter:)`.

- [x] **Step 1: Implement the command**

Create `Tools/echo-cli/ExportVideoCommand.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// Export a book's Visual Listening slideshow as `<Title>.mp4` +
/// `<Title>.srt` + `<Title>.chapters.txt`.
struct ExportVideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-video",
        abstract: "Export a book's slideshow as mp4 + srt + chapters.txt.")

    @Option(help: "Path to the Echo SQLite database.")
    var db: String
    @Option(name: .customLong("audiobook-id"), help: "Audiobook id in the database.")
    var audiobookID: String
    @Option(help: "Book title used for output filenames and metadata fallback.")
    var title: String
    @Option(help: "Output directory for the three files.")
    var out: String
    @Option(
        name: .customLong("cache-dir"),
        help: "Narration cache directory (required for narrated books).")
    var cacheDir: String?
    @Flag(help: "Per-sentence frames instead of word karaoke (faster, smaller).")
    var simple = false
    @Option(help: "Output size as WxH.")
    var size: String = "1920x1080"
    @Option(help: "Optional clip range in seconds, as start-end (e.g. 60-120).")
    var range: String?

    @MainActor func run() async throws {
        let database = try DatabaseService(databaseURL: URL(fileURLWithPath: db))

        let narrated = ExportSourceResolver.isNarrated(
            audiobookID: audiobookID, databaseWriter: database.writer)
        guard !narrated || cacheDir != nil else {
            throw ValidationError("This book is narrated; pass --cache-dir <narration cache>.")
        }

        let dimensions = size.split(separator: "x").compactMap { Int($0) }
        guard dimensions.count == 2 else {
            throw ValidationError("--size must look like 1920x1080")
        }
        var clip: Range<TimeInterval>?
        if let range {
            let parts = range.split(separator: "-").compactMap { TimeInterval($0) }
            guard parts.count == 2, parts[1] > parts[0] else {
                throw ValidationError("--range must look like start-end with end > start")
            }
            clip = parts[0]..<parts[1]
        }

        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let output = try await VideoExportService().exportVideo(
            audiobookID: audiobookID,
            bookTitle: title,
            databaseWriter: database.writer,
            cacheDirectory: URL(fileURLWithPath: cacheDir ?? "/nonexistent-cache"),
            outputDirectory: outDir,
            mode: simple ? .simple : .karaoke,
            width: dimensions[0], height: dimensions[1],
            range: clip,
            onProgress: { fraction in
                FileHandle.standardError.write(
                    Data(String(format: "\rprogress %3.0f%%", fraction * 100).utf8))
            })
        print("\nVIDEO_DONE \(output.videoURL.path)")
        print("SRT \(output.srtURL.path)")
        print("CHAPTERS \(output.chaptersURL.path)")
    }
}
```

- [x] **Step 2: Register the subcommand**

In `Tools/echo-cli/EchoCLI.swift`, add to the `subcommands:` array after `ExportBlocksCommand.self`:

```swift
            ExportBlocksCommand.self,
            ExportVideoCommand.self,
```

- [x] **Step 3: Build the CLI (only via make echo-cli) and smoke-check help**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
.build/cli/Build/Products/Release/echo-cli export-video --help
```

Expected: BUILD SUCCEEDED; help text lists `--db`, `--audiobook-id`, `--title`, `--out`, `--cache-dir`, `--simple`, `--size`, `--range`. If the new file isn't picked up by the `echo-cli` target (older non-synchronized pbxproj group), follow the existing `Tools/echo-cli/add-target.rb` pattern to add it — check `git log --follow Tools/echo-cli/SidecarCommands.swift` for how the last-added command file was registered.

- [x] **Step 4: Commit**

```bash
git add Tools/echo-cli/ExportVideoCommand.swift Tools/echo-cli/EchoCLI.swift
git commit -m "feat(cli): export-video subcommand"
```

---

## Task 8: PR 1 — verification, push, PR, CI

- [x] **Step 1: Full local verification**

```bash
git diff --check
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
```

All must pass. Run SwiftLint if installed (`swiftlint --strict` from repo root).

- [x] **Step 2: Optional but recommended real-book smoke test**

If a narrated or aligned book DB is available locally (see `~/Developer/echo-overnight` scratch), run `export-video --simple` against it and open the mp4 + srt in QuickTime/VLC. Record whether mp4 chapter atoms surfaced (spec's attempt-and-verify risk).

- [x] **Step 3: Rebase, push, open PR into nightly**

```bash
git fetch origin && git rebase origin/nightly
git push --force-with-lease -u origin claude/echo-slideshow-video-export-srt-837616
gh pr create --base nightly --title "feat(export): slideshow video export pipeline + echo-cli (mp4 + SRT + chapters.txt)" --body "$(cat <<'EOF'
## Summary
- Pure `SlideshowExportPlanner` (Shared) turns aligned book data into a deterministic whole-book frame/SRT plan via `VisualListeningCueResolver` — per-track scoping identical to live playback, offset into a global timeline
- `SRTFormatter` + `SlideshowChapterMark`: sidecar `.srt` and YouTube-style `.chapters.txt`
- `SlideshowFrameRenderer` (CoreGraphics/CoreText, UIKit-free) with per-image base-frame caching
- `VideoExportService` actor: `ExportSource` audio spine + `AVAssetWriter` H.264/AAC with variable frame durations; mp4 chapter atoms attempt-and-verify with `chapters.txt` fallback
- `echo-cli export-video` subcommand (`--simple`, `--size`, `--range`)
- Extractions: `VisualListeningImageLocator`, `TimelineRowLoader` (stage + export share one policy)

Spec: docs/superpowers/specs/2026-07-18-slideshow-video-export-design.md (PR 2 adds iOS/macOS UI)

## Test plan
- [x] `make test` (planner, SRT, locator, loader, renderer, service integration suites)
- [x] macOS + echo-cli builds
- [x] CLI smoke on a real aligned book

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr checks --watch
```

Expected: `Build gate + tests` green. If CI fails, read the failing job log, fix, push, re-watch.

---

## Task 9 (PR 2): iOS entry point

**Branch first:**

```bash
git checkout -b claude/slideshow-video-export-ui
```

**Files:**
- Create: `EchoCore/Views/VideoExportProgressView.swift`
- Modify: `EchoCore/Views/UnifiedBottomDock.swift` (add `onVideoExport` action)
- Modify: `EchoCore/Views/RootTabView.swift` (state + sheet + dock wiring, near `showingExport` at lines ~139/287/402)
- Test: `EchoTests/VideoExportUIWiringTests.swift` (source-inspection, like `NowPlayingLayoutTests`)

**Interfaces:**
- Consumes: `VideoExportService.exportVideo(...)` (Task 6), `PlayerModel.narrationCacheDirectory()` (existing — same value `ExportProgressView` receives), `model.folderURL?.absoluteString` as `audiobookID` (established convention).

- [x] **Step 1: Write the failing source-inspection tests**

Create `EchoTests/VideoExportUIWiringTests.swift` following the pattern in `NowPlayingLayoutTests` (read that file first for the source-loading helper it uses, and reuse its approach):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct VideoExportUIWiringTests {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func rootTabViewPresentsVideoExportSheet() throws {
        let text = try source("EchoCore/Views/RootTabView.swift")
        #expect(text.contains("showingVideoExport"))
        #expect(text.contains("VideoExportProgressView("))
    }

    @Test func bottomDockExposesVideoExportAction() throws {
        let text = try source("EchoCore/Views/UnifiedBottomDock.swift")
        #expect(text.contains("onVideoExport"))
    }

    @Test func progressViewSupportsCancelAndShare() throws {
        let text = try source("EchoCore/Views/VideoExportProgressView.swift")
        #expect(text.contains("ShareLink") || text.contains("ActivityView"))
        #expect(text.contains("cancel") || text.contains("Cancel"))
    }
}
```

- [x] **Step 2: Run to verify failure**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/VideoExportUIWiringTests
```

Expected: FAIL (file missing / strings absent).

- [x] **Step 3: Build `VideoExportProgressView`**

Model directly on `EchoCore/Views/ExportProgressView.swift` (read it first; keep the same structural skeleton, state names, and error presentation so the two export sheets stay siblings). Shape:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI

/// Runs the slideshow video export with progress + cancel, then offers the
/// resulting files through a share sheet. Mirrors `ExportProgressView`.
struct VideoExportProgressView: View {
    let audiobookID: String
    let bookTitle: String
    let cacheDirectory: URL
    let databaseWriter: DatabaseWriter

    @Environment(\.dismiss) private var dismiss
    @State private var fraction = 0.0
    @State private var output: VideoExportService.Output?
    @State private var errorText: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var mode: SlideshowExportMode = .karaoke

    var body: some View {
        NavigationStack {
            Form {
                if let output {
                    Section("Done") {
                        ShareLink(
                            "Share Video", items: [output.videoURL, output.srtURL, output.chaptersURL])
                    }
                } else if let errorText {
                    Section("Export Failed") { Text(errorText) }
                } else {
                    Section("Exporting Video") {
                        ProgressView(value: fraction)
                        Text("Rendering the slideshow — this can take a while for long books.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export Video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        exportTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onDisappear { exportTask?.cancel() }
            .task { await runExport() }
        }
    }

    private func runExport() async {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            let result = try await VideoExportService().exportVideo(
                audiobookID: audiobookID,
                bookTitle: bookTitle,
                databaseWriter: databaseWriter,
                cacheDirectory: cacheDirectory,
                outputDirectory: outputDirectory,
                mode: mode,
                onProgress: { value in
                    Task { @MainActor in fraction = value }
                })
            output = result
        } catch is CancellationError {
            // dismissed — nothing to show
        } catch {
            errorText = String(describing: error)
        }
    }
}
```

Adjust to match `ExportProgressView`'s actual conventions where they differ (error copy, `UIBackgroundTask` extension if it takes one, section styling). If `ExportProgressView` requests background-task time, mirror that here — a long render must survive a brief screen lock.

- [x] **Step 4: Add the dock action and sheet**

In `EchoCore/Views/UnifiedBottomDock.swift`: add a parameter `onVideoExport: (() -> Void)? = nil` alongside the existing `onExport`, and render its menu row immediately after the existing Export row, matching its style exactly (same Button/Label idiom the dock already uses), e.g. `Button("Export Video", systemImage: "film", action: onVideoExport)` guarded on non-nil like `onExport` is.

In `EchoCore/Views/RootTabView.swift`:

1. Near line 139: `@State private var showingVideoExport = false`
2. In the `UnifiedBottomDock(...)` call (line ~287), after the `onExport:` argument:

```swift
                        onVideoExport: (model.folderURL != nil
                            && !model.narrationPlaybackState.isRunning)
                            ? { showingVideoExport = true } : nil,
```

3. After the `showingExport` sheet (line ~402):

```swift
        .sheet(isPresented: $showingVideoExport) {
            if let id = model.folderURL?.absoluteString, let writer = model.databaseService?.writer
            {
                VideoExportProgressView(
                    audiobookID: id,
                    bookTitle: model.currentTitle,
                    cacheDirectory: PlayerModel.narrationCacheDirectory(),
                    databaseWriter: writer)
            }
        }
```

- [x] **Step 5: Run tests + build**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
make test-only FILTER=EchoTests/VideoExportUIWiringTests
make test-only FILTER=EchoTests/NowPlayingLayoutTests
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add EchoCore/Views/VideoExportProgressView.swift EchoCore/Views/UnifiedBottomDock.swift EchoCore/Views/RootTabView.swift EchoTests/VideoExportUIWiringTests.swift
git commit -m "feat(ios): video export entry with progress and share"
```

---

## Task 10 (PR 2): macOS entry point

**Files:**
- Create: `Echo macOS/Views/MacVideoExportView.swift`
- Modify: `Echo macOS/Echo_macOSApp.swift` (state + sheet + menu trigger, next to `showAudioExport` at ~line 106)

**Interfaces:**
- Consumes: `VideoExportService.exportVideo(...)`, `player.audiobookID`, `player.dbService?.writer`, `player.currentTitle` (same values `MacAudioExportView` receives).

- [x] **Step 1: Build `MacVideoExportView`**

Model directly on `Echo macOS/Views/MacAudioExportView.swift` (read it first — reuse its `NSSavePanel` sequencing comment/pattern, which exists to avoid presenting sheets from inside the panel callback). Differences from the audio view:

- `NSSavePanel` collects the `.mp4` destination; `nameFieldStringValue = "\(bookTitle).mp4"`.
- Pass the panel URL's `deletingLastPathComponent()` as `outputDirectory` and the panel's chosen basename as `bookTitle` so `.srt`/`.chapters.txt` land beside the movie with the user's chosen name.
- A `Picker("Mode", selection: $mode)` with `.karaoke` / `.simple` (`SlideshowExportMode`), default `.karaoke`.
- Progress bar bound to the `onProgress` callback; "Reveal in Finder" (`NSWorkspace.shared.activateFileViewerSelecting`) on success.

- [x] **Step 2: Wire into the app**

In `Echo macOS/Echo_macOSApp.swift`, next to the existing `showAudioExport` sheet (~line 106): add `@State private var showVideoExport = false`, an identical `.sheet(isPresented: $showVideoExport)` presenting `MacVideoExportView(audiobookID:bookTitle:databaseWriter:)` under the same `player.audiobookID`/`player.dbService?.writer` guard, and a menu item next to wherever `showAudioExport` is toggled (search `showAudioExport = true` in the same file — likely the File/Export command group): `Button("Export Video…") { showVideoExport = true }` with the same enabled-state condition.

- [x] **Step 3: Build macOS**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
```

Expected: BUILD SUCCEEDED.

- [x] **Step 4: Commit**

```bash
git add "Echo macOS/Views/MacVideoExportView.swift" "Echo macOS/Echo_macOSApp.swift"
git commit -m "feat(macos): video export entry with save panel"
```

---

## Task 11 (PR 2): Docs, verification, PR

**Files:**
- Modify: `ARCHITECTURE.md` (Export section: add the video pipeline beside the m4b spine)
- Modify: `CHANGELOG.md` (new entry)

- [x] **Step 1: Document**

`CHANGELOG.md` entry (match the file's existing style):

```markdown
- **Slideshow video export (iOS, macOS, echo-cli):** Books with alignment or narration can export the Visual Listening slideshow as a standard video bundle — `<Title>.mp4` (1080p H.264 with sparse variable-duration frames: figure, caption, subtitle with karaoke word emphasis), `<Title>.srt` (sentence-level sidecar subtitles), and `<Title>.chapters.txt` (YouTube-style chapter list; mp4 chapter atoms are stamped when verified). A pure `SlideshowExportPlanner` samples `VisualListeningCueResolver` per track with player-identical scoping so the export cannot drift from the live stage; `VideoExportService` reuses the m4b export's `ExportSource` audio spine. iOS exports from the dock overflow (progress + share sheet), macOS from the export menu (save panel + Reveal in Finder), and headless via `echo-cli export-video` (`--simple`, `--size`, `--range`).
```

`ARCHITECTURE.md`: in the export/Release-adjacent section describing `AudioExportService`, add a short sibling paragraph naming `SlideshowExportPlanner` → `SlideshowFrameRenderer` → `VideoExportService`, the global-timeline offset rule, and the chapter-atom attempt-and-verify policy. Keep it under ~15 lines, matching surrounding density.

- [x] **Step 2: Full verification (same gate list as Task 8 Step 1)**

```bash
git diff --check
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make echo-cli
```

- [ ] **Step 3: Commit, push, PR (stacked on PR 1)**

```bash
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs: slideshow video export architecture + changelog"
git push -u origin claude/slideshow-video-export-ui
gh pr create --base nightly --head claude/slideshow-video-export-ui --title "feat(export): iOS + macOS UI for slideshow video export" --body "$(cat <<'EOF'
## Summary
Stacked on the pipeline PR. Adds the user-facing entry points for slideshow video export:
- iOS: dock overflow "Export Video" → progress sheet with cancel → share sheet (mp4 + srt + chapters.txt)
- macOS: Export menu → save panel (mode picker: Karaoke/Simple) → Reveal in Finder
- ARCHITECTURE.md + CHANGELOG.md

## Test plan
- [ ] `make test` (UI wiring suite)
- [ ] macOS build
- [ ] Device QA: short-book export on iPhone (gates whether iOS default stays Karaoke — spec risk item)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr checks --watch
```

If PR 1 merges first, rebase this branch onto `origin/nightly` before the PR (`git fetch origin && git rebase origin/nightly && git push --force-with-lease`). Report hosted CI status (passing/failing/pending/blocked) for both PRs.

- [ ] **Step 4: Post-merge reminders (report, don't act)**

- Device QA note: whole-book Karaoke render time on iPhone decides the iOS default mode (spec Risk 1).
- The `Welcome to Echo` manual EPUB and marketing docs mention export features — flag that the `echo-manual-epub` skill should re-run after this ships.
