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
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
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
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
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
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .simple, syncPoint: .begin)

        #expect(plan.frames.allSatisfy { $0.activeWordIndex == nil })
        #expect(plan.frames.filter { $0.subtitleText == "First sentence here." }.count == 1)
    }

    // MARK: - SRT cues

    @Test func srtCuesComeFromScopedTextRowsWithGlobalTimes() {
        let fx = chapterOneFixture
        let plan = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: [],
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
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
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 30, segmentKey: nil, chapterIndices: nil)
            ],
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
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .simple, syncPoint: .begin,
            range: 2.0..<6.0)

        #expect(plan.totalDuration == 4)
        #expect(plan.frames.first?.startTime == 0)
        #expect(plan.srtCues.allSatisfy { $0.startTime >= 0 && $0.endTime <= 4 })
        #expect(plan.srtCues.contains { $0.text == "Second sentence follows." })
    }
}
