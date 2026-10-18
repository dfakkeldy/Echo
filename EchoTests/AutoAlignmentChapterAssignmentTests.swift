// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct AutoAlignmentChapterAssignmentTests {
    @Test func missingChapterRepairDoesNotCountCodeListingWords() {
        let blocks = [
            block("heading", kind: .heading, text: "Chapter One", words: 2),
            block("intro", text: "Brief spoken introduction", words: 3),
            block("listing", kind: .code, text: "raw code", words: 1_000),
            block("target", text: "Spoken prose follows listing", words: 4),
            block("tail", text: "A deliberately much longer spoken tail", words: 20),
        ]
        let chapters = [
            Chapter(index: 0, title: "First", startSeconds: 0, endSeconds: 80),
            Chapter(index: 1, title: "Second", startSeconds: 80, endSeconds: 100),
        ]

        let repaired = AutoAlignmentService.assignMissingChapterIndicesForCommercialAudio(
            blocks: blocks,
            chapters: chapters
        )

        #expect(repaired.first { $0.id == "target" }?.chapterIndex == 0)
    }

    private func block(
        _ id: String,
        kind: EPubBlockRecord.Kind = .paragraph,
        text: String,
        words: Int
    ) -> EPubBlockRecord {
        var block = EPubBlockRecord(
            id: id,
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: kind.rawValue,
            text: text,
            chapterIndex: nil,
            isHidden: false
        )
        block.wordCount = words
        return block
    }
}
