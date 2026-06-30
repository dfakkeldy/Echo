// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct PronunciationRepairServiceTests {

    /// Seed one audiobook + block so the resolver has a real FK row.
    private func seedBlock(
        audiobookID: String, blockID: String, chapterIndex: Int, db: DatabaseService
    ) throws {
        try db.writer.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, ?, 0, '2026-01-01T00:00:00Z')",
                arguments: [audiobookID, "Book"])
        }
        var block = EPubBlockRecord(
            id: blockID, audiobookID: audiobookID, spineHref: "ch.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Hello Arrakis.", htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: chapterIndex,
            isHidden: false, hiddenReason: nil, isFrontMatter: false,
            wordCount: 2, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insert(block)
        _ = block  // silence unused-var if insert copies
    }

    @Test func resolvesChapterIndexForBlock() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "file:///Books/Dune/"
        try seedBlock(audiobookID: bookID, blockID: "epub-\(bookID)-s0-b0", chapterIndex: 7, db: db)

        let idx = try PronunciationRepairService.chapterIndex(
            forBlockID: "epub-\(bookID)-s0-b0", audiobookID: bookID, db: db.writer)
        #expect(idx == 7)
    }

    @Test func returnsNilForUnknownBlock() throws {
        let db = try DatabaseService(inMemory: ())
        let idx = try PronunciationRepairService.chapterIndex(
            forBlockID: "nope", audiobookID: "file:///Books/Dune/", db: db.writer)
        #expect(idx == nil)
    }
}
