// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationOutlineBuilderTests {
    private func block(
        _ id: String, ch: Int, seq: Int, kind: String = "paragraph",
        text: String?, hidden: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "bk", spineHref: "c.xhtml", spineIndex: 0,
            blockIndex: seq, sequenceIndex: seq, blockKind: kind, text: text,
            htmlContent: nil, cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: ch, isHidden: hidden, hiddenReason: hidden ? "skip" : nil,
            isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
    }

    @Test func buildsRowsWithTitleStateAndStableNumbering() {
        let blocks = [
            block("h1", ch: 1, seq: 0, kind: "heading", text: "Beginnings"),
            block("p1", ch: 1, seq: 1, text: "once upon a time"),
            block("p2", ch: 2, seq: 2, text: "second chapter", hidden: true),  // excluded
            block("h3", ch: 3, seq: 3, kind: "heading", text: "The End"),
            block("p3", ch: 3, seq: 4, text: "final chapter"),
        ]
        // Chapter 1 is rendered, others not.
        let rows = NarrationOutlineBuilder.build(allBlocks: blocks, isRendered: { $0 == 1 })

        #expect(rows.map(\.chapterIndex) == [1, 2, 3])
        #expect(rows.map(\.displayNumber) == [1, 2, 3])  // stable, excluded NOT skipped
        #expect(rows[0].title == "ch. 1: Beginnings")  // first meaningful heading wins
        #expect(rows[2].title == "ch. 3: The End")
        #expect(rows.map(\.isExcluded) == [false, true, false])
        #expect(rows.map(\.isRendered) == [true, false, false])
    }

    @Test func titleFallsBackToChapterNumber() {
        let rows = NarrationOutlineBuilder.build(
            allBlocks: [block("p1", ch: 5, seq: 0, text: "no heading here")],
            isRendered: { _ in false })
        #expect(rows.count == 1)
        #expect(rows[0].title == "Chapter 1")
    }

    @Test func exactPlaybackPlanReadinessDoesNotHideExcludedChapterRows() {
        let blocks = [
            block("p0", ch: 0, seq: 0, text: "rendered chapter"),
            block("p1", ch: 1, seq: 1, text: "excluded chapter", hidden: true),
            block("p2", ch: 2, seq: 2, text: "not rendered"),
        ]
        let exactlyRenderedChapterIndices: Set<Int> = [0]

        let rows = NarrationOutlineBuilder.build(allBlocks: blocks) {
            exactlyRenderedChapterIndices.contains($0)
        }

        #expect(rows.map(\.chapterIndex) == [0, 1, 2])
        #expect(rows.map(\.isRendered) == [true, false, false])
        #expect(rows.map(\.isExcluded) == [false, true, false])
    }

    @Test func readinessRecomputesFromEveryExactFilenameAfterRendering() {
        let expectedByChapter: [Int: Set<String>] = [
            0: ["chapter-0-segment-0.m4a", "chapter-0-segment-1.m4a"],
            1: ["chapter-1-segment-0.m4a"],
        ]

        let initiallyRendered = NarrationOutlineReadiness.renderedChapterIndices(
            expectedFileNamesByChapter: expectedByChapter,
            existingFileNames: ["chapter-0-segment-0.m4a"])
        let afterRendering = NarrationOutlineReadiness.renderedChapterIndices(
            expectedFileNamesByChapter: expectedByChapter,
            existingFileNames: [
                "chapter-0-segment-0.m4a", "chapter-0-segment-1.m4a",
                "chapter-1-segment-0.m4a",
            ])

        #expect(initiallyRendered.isEmpty)
        #expect(afterRendering == [0, 1])
    }

    @Test func queueExclusionRemovesStablePlanFilesAndPreservesCurrentTrack() {
        let entryKey = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let exact = NarrationFileNaming.segmentFileName(
            audiobookID: "book", chapterIndex: 7, sourceChapterKey: entryKey,
            segmentIndex: 0, voice: VoiceID("bf_emma"), contentSignature: "current")
        let second = NarrationFileNaming.segmentFileName(
            audiobookID: "book", chapterIndex: 7, sourceChapterKey: entryKey,
            segmentIndex: 1, voice: VoiceID("bf_emma"), contentSignature: "current")
        let unrelated = NarrationFileNaming.segmentFileName(
            audiobookID: "book", chapterIndex: 0, sourceChapterKey: nil,
            segmentIndex: 0, voice: VoiceID("af_heart"), contentSignature: "other")

        let removable = NarrationOutlineReadiness.removableQueueIndices(
            fileNames: [exact, unrelated, second],
            currentIndex: 2,
            expectedFileNames: [exact, second])

        #expect(removable == [0])
        #expect(NarrationFileNaming.chapterIndex(fromFileName: exact) == nil)
    }

    @Test func titlePreservesClosingParenthesisAfterDuplicateChapterPrefixCleanup() {
        var blocks: [EPubBlockRecord] = []
        for chapter in 0..<7 {
            blocks.append(
                block("p\(chapter)", ch: chapter, seq: chapter, text: "Earlier chapter"))
        }
        blocks.append(
            block(
                "h8", ch: 7, seq: 7, kind: "heading",
                text: "Chapter 8 - The Long Game (and the Honest One)"))
        blocks.append(block("p8", ch: 7, seq: 8, text: "The paragraph."))

        let rows = NarrationOutlineBuilder.build(allBlocks: blocks, isRendered: { _ in false })

        #expect(rows.last?.title == "ch. 8: The Long Game (and the Honest One)")
    }
}
