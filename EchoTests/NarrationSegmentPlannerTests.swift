// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationSegmentPlannerTests {
    private func block(
        _ id: String,
        chars: Int,
        chapter: Int,
        seq: Int,
        kind: String = "paragraph",
        text: String? = nil,
        narrationText: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "b1", spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: seq, sequenceIndex: seq,
            blockKind: kind, text: text ?? String(repeating: "a", count: chars),
            htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: chapter,
            isHidden: false, hiddenReason: nil, isFrontMatter: false,
            wordCount: nil, markers: nil, textFormats: nil,
            narrationText: narrationText,
            createdAt: nil, modifiedAt: nil)
    }

    @Test func firstChapterFirstSegmentIsSmall() {
        let blocks = (0..<5).map { block("x\($0)", chars: 150, chapter: 0, seq: $0) }
        let chapter = renderPlan(
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
        let chapter = renderPlan(
            index: 2, displayNumber: 3, blocks: blocks)

        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: false)

        #expect(segments.count == 1)
        #expect(segments[0].blocks.count == 3)
    }

    @Test func stableKeyChapterAlwaysUsesSmallStreamingFirstSegment() {
        let blocks = (0..<4).map { block("stable-\($0)", chars: 150, chapter: 2, seq: $0) }
        let chapter = renderPlan(
            index: 2, displayNumber: 3, blocks: blocks,
            sourceChapterKey: "stable-entry")

        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: false)

        #expect(
            segments.map { $0.blocks.map(\.id) } == [
                ["stable-0"], ["stable-1", "stable-2", "stable-3"],
            ])
    }

    @Test func everySegmentHasAtLeastOneBlockAndNoneAreLost() {
        let blocks = (0..<7).map { block("z\($0)", chars: 800, chapter: 1, seq: $0) }
        let chapter = renderPlan(
            index: 1, displayNumber: 2, blocks: blocks)

        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: false)

        #expect(segments.allSatisfy { !$0.blocks.isEmpty })
        #expect(segments.flatMap { $0.blocks.map(\.id) } == blocks.map(\.id))
    }

    @Test func planMarksOnlyTheFirstChapterAsBookStart() {
        let first = renderPlan(
            index: 0, displayNumber: 1,
            blocks: [block("a", chars: 150, chapter: 0, seq: 0)])
        let second = renderPlan(
            index: 1, displayNumber: 2,
            blocks: (0..<4).map { block("b\($0)", chars: 150, chapter: 1, seq: $0) })

        let segments = NarrationSegmentPlanner.plan([first, second])

        #expect(segments.filter { $0.chapterIndex == 0 }.count == 1)
        #expect(segments.filter { $0.chapterIndex == 1 }.count == 1)
    }

    @Test func segmentsCarryChapterTitleFromPlan() {
        let blocks = [
            block(
                "h", chars: 0, chapter: 0, seq: 0, kind: "heading",
                text: "Chapter 1: Opening"),
            block("p", chars: 150, chapter: 0, seq: 1),
        ]
        let chapter = renderPlan(
            index: 0, displayNumber: 1, blocks: blocks)

        let segments = NarrationSegmentPlanner.plan([chapter])

        #expect(segments.map(\.chapterTitle) == ["ch. 1: Opening"])
    }

    @Test func codeListingDurationUsesItsSpokenCueInsteadOfRawSource() {
        let blocks = [
            block(
                "code", chars: 0, chapter: 1, seq: 0, kind: "code",
                text: String(repeating: "let value = answer + 42\n", count: 100),
                narrationText: "Code listing."
            ),
            block("prose", chars: 150, chapter: 1, seq: 1),
        ]
        let chapter = renderPlan(
            index: 1, displayNumber: 2, blocks: blocks)

        let segments = NarrationSegmentPlanner.segments(
            for: chapter, isFirstChapterOfBook: false)

        #expect(segments.count == 1)
        #expect(segments[0].blocks.map(\.id) == ["code", "prose"])
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

    @Test func stableKeyResumeUsesTheReorderedPlanInsteadOfChapterPositions() {
        let plans = [
            renderPlan(index: 8, displayNumber: 2, segmentCount: 1, sourceChapterKey: "beta"),
            renderPlan(index: 3, displayNumber: 1, segmentCount: 2, sourceChapterKey: "alpha"),
        ]
        let segments = NarrationSegmentPlanner.plan(plans)

        #expect(
            NarrationSegmentPlanner.resume(segments, startingAtSourceChapterKey: "alpha")
                .map(location) == ["3-0", "3-1"])
        #expect(
            NarrationSegmentPlanner.beforeResume(segments, startingAtSourceChapterKey: "alpha")
                .map(location) == ["8-0"])
    }

    @Test func segmentsPreserveTheRenderPlanSourceKeyAndVoice() {
        let plan = renderPlan(
            index: 3,
            displayNumber: 1,
            segmentCount: 2,
            sourceChapterKey: "stable-entry",
            voice: VoiceID("bf_emma"))

        let segments = NarrationSegmentPlanner.plan([plan])

        #expect(segments.map(\.sourceChapterKey) == ["stable-entry", "stable-entry"])
        #expect(segments.map(\.voice) == [VoiceID("bf_emma"), VoiceID("bf_emma")])
    }

    private func chapter(
        index: Int,
        displayNumber: Int,
        segmentCount: Int
    ) -> NarrationChapterRenderPlan {
        renderPlan(index: index, displayNumber: displayNumber, segmentCount: segmentCount)
    }

    private func renderPlan(
        index: Int,
        displayNumber: Int,
        blocks: [EPubBlockRecord]? = nil,
        segmentCount: Int = 1,
        sourceChapterKey: String? = nil,
        voice: VoiceID = VoiceID("af_heart")
    ) -> NarrationChapterRenderPlan {
        let chapterBlocks =
            blocks
            ?? (0..<segmentCount).map { offset in
                block("c\(index)-b\(offset)", chars: 800, chapter: index, seq: offset)
            }
        return NarrationChapterRenderPlan(
            chapterIndex: index,
            displayNumber: displayNumber,
            sourceChapterKey: sourceChapterKey,
            title: NarrationChapterPlanner.title(
                displayNumber: displayNumber, blocks: chapterBlocks),
            blocks: chapterBlocks,
            voice: voice)
    }

    private func location(_ segment: NarrationSegmentPlanner.PlannedSegment) -> String {
        "\(segment.chapterIndex)-\(segment.segmentIndex)"
    }
}
