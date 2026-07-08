// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct PDFFigureImporterTests {
    // NOTE: adapted from the brief — `epub_block.audiobook_id` carries a
    // `references("audiobook", onDelete: .cascade)` FK (Shared/Database/Schema_V1.swift),
    // so seeding a text block requires its parent `audiobook` row to exist first
    // (mirrors the pattern in PDFBlockPageCaptureTests). Uses `INSERT OR IGNORE`
    // so it's safe to call once per test even though both tests seed one block.
    private func seedTextBlock(
        _ db: DatabaseService, audiobookID: String, id: String, spine: Int, block: Int,
        chapter: Int
    ) throws {
        try db.writer.write { d in
            try d.execute(
                sql:
                    "INSERT OR IGNORE INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 120)",
                arguments: [audiobookID])
            try d.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                       block_kind, text, chapter_index, is_hidden, is_front_matter)
                    VALUES (?, ?, 'pdf', ?, ?, ?, 'paragraph', 'hello', ?, 0, 0)
                    """,
                arguments: [id, audiobookID, spine, block, block, chapter])
        }
    }

    @Test func insertsFigureBlockWithImagePathAndReturnsAnchor() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-F"
        try seedTextBlock(
            db, audiobookID: book, id: "epub-\(book)-s0-b0", spine: 0, block: 0, chapter: 3)
        let figures = [
            ExtractedFigure(pageIndex: 0, order: 0, pngData: Data([0x89, 0x50, 0x4E, 0x47]))
        ]
        let manifest = PDFFigureImporter.importFigures(
            figures, audiobookID: book,
            textBlocks: try db.writer.read { try EPubBlockRecord.fetchAll($0) },
            pageMapping: [(blockID: "epub-\(book)-s0-b0", pageIndex: 0)],
            databaseService: db)

        #expect(manifest.count == 1)
        let entry = try #require(manifest.first)
        #expect(
            entry.portableAnchor.range(of: #"^s[0-9]+-b[0-9]+$"#, options: .regularExpression)
                != nil)
        #expect(FileManager.default.fileExists(atPath: entry.imagePath))

        let row = try db.writer.read { d in
            try EPubBlockRecord.filter(Column("block_kind") == "image").fetchOne(d)
        }
        let fig = try #require(row)
        #expect(fig.text == nil)
        #expect(fig.imagePath == entry.imagePath)
        #expect(fig.chapterIndex == 3)  // inherited from the page's text block
    }

    @Test func figureBlockIsExcludedFromNarrationCandidates() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-G"
        try seedTextBlock(
            db, audiobookID: book, id: "epub-\(book)-s0-b0", spine: 0, block: 0, chapter: 0)
        _ = PDFFigureImporter.importFigures(
            [ExtractedFigure(pageIndex: 0, order: 0, pngData: Data([0x1]))],
            audiobookID: book,
            textBlocks: try db.writer.read { try EPubBlockRecord.fetchAll($0) },
            pageMapping: [(blockID: "epub-\(book)-s0-b0", pageIndex: 0)],
            databaseService: db)
        let all = try db.writer.read { try EPubBlockRecord.fetchAll($0) }
        // The render planner keeps only text?.isEmpty == false && !isHidden.
        let candidates = all.filter { ($0.text?.isEmpty == false) && !$0.isHidden }
        #expect(candidates.allSatisfy { $0.blockKind != "image" })
        #expect(candidates.count == 1)  // just the text block
    }
}
