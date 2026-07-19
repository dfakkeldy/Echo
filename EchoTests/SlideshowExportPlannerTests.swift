// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct SlideshowExportPlannerTests {
    // MARK: - Fixtures

    private func block(
        _ id: String, sequence: Int, kind: EPubBlockRecord.Kind,
        text: String? = nil, imagePath: String? = nil,
        narrationText: String? = nil, chapter: Int? = 0, hidden: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "spine", spineIndex: 0,
            blockIndex: sequence, sequenceIndex: sequence, blockKind: kind.rawValue,
            text: text, htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: imagePath, chapterIndex: chapter, isHidden: hidden,
            hiddenReason: nil, isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, narrationText: narrationText, createdAt: nil, modifiedAt: nil)
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

    @Test func boundedWordSentinelsPreserveKaraokeOrdinalsForPartialSlice() {
        let text = "zero one two three four"
        let blocks = [block("partial", sequence: 0, kind: .paragraph, text: text)]
        let rows = [timeline(0, 2, blockID: "partial")]
        let words: [ReaderActiveBlockResolver.WordRow] = [
            (start: 0, end: 0, blockID: "partial", wordIndex: 0),
            (start: 0, end: 0, blockID: "partial", wordIndex: 1),
            (start: 0, end: 1, blockID: "partial", wordIndex: 2),
            (start: 1, end: 2, blockID: "partial", wordIndex: 3),
            (start: 2, end: 2, blockID: "partial", wordIndex: 4),
        ]

        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: words,
            tracks: [
                SlideshowTrackContext(
                    title: "Partial", duration: 2, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .karaoke, syncPoint: .begin)

        let partialFrames = plan.frames.filter { $0.subtitleText == text }
        #expect(partialFrames.map(\.startTime) == [0, 1])
        #expect(partialFrames.map(\.duration) == [1, 1])
        #expect(partialFrames.map(\.activeWordIndex) == [2, 3])
        #expect(partialFrames.map(\.alreadyHeardWordCount) == [2, 3])
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

    @Test func openEndedFinalRowAndWordTimingsStopAtTrackDuration() {
        let tokens = (0..<20).map { "timedword\($0)" }
        let text = tokens.joined(separator: " ")
        let blocks = [block("final", sequence: 0, kind: .paragraph, text: text)]
        let rows = [timeline(0, 3_600, blockID: "final")]
        let words: [ReaderActiveBlockResolver.WordRow] = tokens.indices.map { index in
            (
                start: Double(index) * 0.25,
                end: index == tokens.indices.last ? 3_600 : Double(index + 1) * 0.25,
                blockID: "final",
                wordIndex: index
            )
        }

        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: words,
            tracks: [
                SlideshowTrackContext(
                    title: "Short track", duration: 6, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .karaoke, syncPoint: .begin)

        #expect(plan.totalDuration == 6)
        #expect(plan.frames.allSatisfy { $0.startTime + $0.duration <= 6 })
        #expect(plan.srtCues.count > 1)
        #expect(plan.srtCues.map(\.endTime) == [1.75, 3.5, 6])
        #expect(plan.srtCues.last?.endTime == 6)
        #expect(
            plan.srtCues.allSatisfy { cue in
                cue.startTime >= 0 && cue.endTime <= 6 && cue.endTime >= cue.startTime
            })
    }

    @Test func longBlockWithMatchingWordTimingsUsesOrderedBoundedCueWindows() {
        let tokens = (0..<20).map { index in
            "word" + (index < 10 ? "0\(index)" : "\(index)")
        }
        let text = tokens.joined(separator: " ")
        let blocks = [block("timed", sequence: 0, kind: .paragraph, text: text)]
        let rows = [timeline(1, 11, blockID: "timed")]
        let words: [ReaderActiveBlockResolver.WordRow] = tokens.indices.map { index in
            (
                start: 1 + Double(index) * 0.5,
                end: 1 + Double(index + 1) * 0.5,
                blockID: "timed",
                wordIndex: index
            )
        }

        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: words,
            tracks: [
                SlideshowTrackContext(
                    title: "Timed", duration: 12, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .karaoke, syncPoint: .begin)

        #expect(text.count > SlideshowExportPlanner.maxCueLength)
        #expect(plan.srtCues.count == 2)
        #expect(plan.srtCues.allSatisfy { $0.text.count <= SlideshowExportPlanner.maxCueLength })
        #expect(plan.srtCues.map(\.startTime) == [1, 7])
        #expect(plan.srtCues.map(\.endTime) == [7, 11])
        #expect(
            plan.srtCues.allSatisfy { cue in
                cue.startTime >= 1 && cue.endTime <= 11 && cue.endTime <= plan.totalDuration
            })
    }

    @Test func boundedWordSentinelsKeepLongPartialSliceSRTCuesWordTimed() {
        let tokens = (0..<20).map { index in
            "word" + (index < 10 ? "0\(index)" : "\(index)")
        }
        let text = tokens.joined(separator: " ")
        let blocks = [block("partial", sequence: 0, kind: .paragraph, text: text)]
        let rows = [timeline(0, 8, blockID: "partial")]
        let words: [ReaderActiveBlockResolver.WordRow] = tokens.indices.map { index in
            if index < 2 {
                return (start: 0, end: 0, blockID: "partial", wordIndex: index)
            }
            if index >= 18 {
                return (start: 8, end: 8, blockID: "partial", wordIndex: index)
            }
            return (
                start: Double(index - 2) * 0.5,
                end: Double(index - 1) * 0.5,
                blockID: "partial",
                wordIndex: index
            )
        }

        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: words,
            tracks: [
                SlideshowTrackContext(
                    title: "Partial", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .karaoke, syncPoint: .begin)

        #expect(text.count > SlideshowExportPlanner.maxCueLength)
        #expect(plan.srtCues.count == 2)
        #expect(plan.srtCues.allSatisfy { $0.text.count <= SlideshowExportPlanner.maxCueLength })
        #expect(plan.srtCues.map(\.startTime) == [0, 5])
        #expect(plan.srtCues.map(\.endTime) == [5, 8])
    }

    @Test func singleLongTokenSplitsWithinTheTokenToHonorCueLimit() {
        let longURL = "https://example.com/" + String(repeating: "a", count: 100)
        let blocks = [block("url", sequence: 0, kind: .paragraph, text: longURL)]
        let rows = [timeline(0, 12, blockID: "url")]
        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: [],
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 12, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .simple, syncPoint: .begin)

        #expect(plan.srtCues.count > 1)
        #expect(plan.srtCues.allSatisfy { $0.text.count <= SlideshowExportPlanner.maxCueLength })
        #expect(plan.srtCues.map(\.text).joined() == longURL)
        #expect(plan.srtCues.first?.startTime == 0)
        #expect(plan.srtCues.last?.endTime == 12)
    }

    @Test func whitespaceOnlyTextDoesNotProduceAnEmptySubtitleCue() {
        let blocks = [block("whitespace", sequence: 0, kind: .paragraph, text: " \n\t ")]
        let rows = [timeline(0, 4, blockID: "whitespace")]
        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: [],
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 4, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .simple, syncPoint: .begin)

        #expect(plan.srtCues.isEmpty)
    }

    @Test func codeFramesAndSRTCuesUseNarrationCueNeverRawSyntax() {
        let rawCode = "let secretSyntax = true"
        let blocks = [
            block(
                "code", sequence: 0, kind: .code, text: rawCode,
                narrationText: "Listing 1.")
        ]
        let rows = [timeline(0, 4, blockID: "code")]
        let plan = SlideshowExportPlanner.plan(
            blocks: blocks, timeline: rows, words: [],
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 4, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .simple, syncPoint: .begin)

        #expect(plan.frames.map(\.subtitleText) == ["Listing 1."])
        #expect(plan.srtCues.map(\.text) == ["Listing 1."])
        #expect(!plan.frames.contains { $0.subtitleText?.contains(rawCode) == true })
        #expect(!plan.srtCues.contains { $0.text.contains(rawCode) })
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

    @Test func outOfBoundsRangesClampWithoutConstructingInvalidRanges() {
        let fx = chapterOneFixture

        let negativeLowerBound = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: [],
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .simple, syncPoint: .begin,
            range: -2.0..<6.0)
        #expect(negativeLowerBound.totalDuration == 6)
        #expect(negativeLowerBound.frames.first?.startTime == 0)
        #expect(negativeLowerBound.srtCues.allSatisfy { $0.startTime >= 0 && $0.endTime <= 6 })

        let whollyAfterTotal = SlideshowExportPlanner.plan(
            blocks: fx.blocks, timeline: fx.timeline, words: [],
            tracks: [
                SlideshowTrackContext(
                    title: "Ch 1", duration: 8, segmentKey: nil, chapterIndices: nil)
            ],
            mode: .simple, syncPoint: .begin,
            range: 9.0..<12.0)
        #expect(whollyAfterTotal.totalDuration == 0)
        #expect(whollyAfterTotal.frames.isEmpty)
        #expect(whollyAfterTotal.srtCues.isEmpty)
    }
}
