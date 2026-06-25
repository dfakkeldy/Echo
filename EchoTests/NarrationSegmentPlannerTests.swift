// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationSegmentPlannerTests {
    private func block(_ id: String, chars: Int, chapter: Int, seq: Int) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "b1", spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: seq, sequenceIndex: seq,
            blockKind: "paragraph", text: String(repeating: "a", count: chars),
            htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: chapter,
            isHidden: false, hiddenReason: nil, isFrontMatter: false,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
    }

    @Test func firstChapterFirstSegmentIsSmall() {
        let blocks = (0..<5).map { block("x\($0)", chars: 150, chapter: 0, seq: $0) }
        let chapter = NarrationChapterPlanner.PlannedChapter(
            index: 0, displayNumber: 1, blocks: blocks)

        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: true)

        #expect(segments.first?.blocks.count == 1)
        #expect(segments.first?.segmentIndex == 0)
        #expect(segments.allSatisfy { $0.chapterIndex == 0 && $0.chapterDisplayNumber == 1 })
        #expect(segments.map(\.segmentIndex) == Array(0..<segments.count))
    }

    @Test func laterChapterFirstSegmentUsesLargeTarget() {
        let blocks = (0..<3).map { block("y\($0)", chars: 150, chapter: 2, seq: $0) }
        let chapter = NarrationChapterPlanner.PlannedChapter(
            index: 2, displayNumber: 3, blocks: blocks)

        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: false)

        #expect(segments.count == 1)
        #expect(segments[0].blocks.count == 3)
    }

    @Test func everySegmentHasAtLeastOneBlockAndNoneAreLost() {
        let blocks = (0..<7).map { block("z\($0)", chars: 800, chapter: 1, seq: $0) }
        let chapter = NarrationChapterPlanner.PlannedChapter(
            index: 1, displayNumber: 2, blocks: blocks)

        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: false)

        #expect(segments.allSatisfy { !$0.blocks.isEmpty })
        #expect(segments.flatMap { $0.blocks.map(\.id) } == blocks.map(\.id))
    }

    @Test func planMarksOnlyTheFirstChapterAsBookStart() {
        let first = NarrationChapterPlanner.PlannedChapter(
            index: 0, displayNumber: 1,
            blocks: [block("a", chars: 150, chapter: 0, seq: 0)])
        let second = NarrationChapterPlanner.PlannedChapter(
            index: 1, displayNumber: 2,
            blocks: (0..<4).map { block("b\($0)", chars: 150, chapter: 1, seq: $0) })

        let segments = NarrationSegmentPlanner.plan([first, second])

        #expect(segments.filter { $0.chapterIndex == 0 }.count == 1)
        #expect(segments.filter { $0.chapterIndex == 1 }.count == 1)
    }

    @Test func resumeStartsAtFirstSegmentOfResumeChapter() {
        let chapters = [
            chapter(index: 0, displayNumber: 1, segmentCount: 2),
            chapter(index: 1, displayNumber: 2, segmentCount: 1),
            chapter(index: 2, displayNumber: 3, segmentCount: 2),
        ]
        let segments = NarrationSegmentPlanner.plan(chapters)

        #expect(
            NarrationSegmentPlanner.resume(segments, startingAtChapterIndex: 1)
                .map(location) == ["1-0", "2-0", "2-1"])
        #expect(
            NarrationSegmentPlanner.resume(segments, startingAtChapterIndex: 99)
                .map(location) == segments.map(location))
    }

    @Test func beforeResumeReturnsEarlierSegmentsInPrependOrder() {
        let chapters = [
            chapter(index: 0, displayNumber: 1, segmentCount: 2),
            chapter(index: 1, displayNumber: 2, segmentCount: 2),
            chapter(index: 2, displayNumber: 3, segmentCount: 1),
        ]
        let segments = NarrationSegmentPlanner.plan(chapters)

        #expect(
            NarrationSegmentPlanner.beforeResume(segments, startingAtChapterIndex: 2)
                .map(location) == ["1-1", "1-0", "0-1", "0-0"])
        #expect(
            NarrationSegmentPlanner.beforeResume(segments, startingAtChapterIndex: 0).isEmpty)
        #expect(
            NarrationSegmentPlanner.beforeResume(segments, startingAtChapterIndex: 99).isEmpty)
    }

    private func chapter(
        index: Int,
        displayNumber: Int,
        segmentCount: Int
    ) -> NarrationChapterPlanner.PlannedChapter {
        NarrationChapterPlanner.PlannedChapter(
            index: index,
            displayNumber: displayNumber,
            blocks: (0..<segmentCount).map { offset in
                block("c\(index)-b\(offset)", chars: 800, chapter: index, seq: offset)
            })
    }

    private func location(_ segment: NarrationSegmentPlanner.PlannedSegment) -> String {
        "\(segment.chapterIndex)-\(segment.segmentIndex)"
    }
}
