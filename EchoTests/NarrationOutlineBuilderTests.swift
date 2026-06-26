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
}
