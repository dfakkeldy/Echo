// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

struct ChapterAudioStatusResolverTests {
    /// `book-1`: chapter 0 = heading `ch0-head` + paragraph `ch0-para`;
    /// chapter 1 = heading `ch1-head` only. No anchors seeded here.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1','Test',3600)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                    VALUES ('ch0-head', 'book-1', 'c1.xhtml', 0, 0, 0, 'heading', 0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                    VALUES ('ch0-para', 'book-1', 'c1.xhtml', 0, 1, 1, 'paragraph', 0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                    VALUES ('ch1-head', 'book-1', 'c2.xhtml', 1, 0, 2, 'heading', 1)
                    """)
        }
        return db
    }

    private func insertAnchor(_ db: DatabaseService, block: String) throws {
        try AlignmentAnchorDAO(db: db.writer).insert(
            AlignmentAnchorRecord(
                id: "a-\(block)", audiobookID: "book-1", epubBlockID: block,
                audioTime: 30, audioEndTime: nil, anchorKind: "point",
                source: "autoAlignment", note: nil, createdAt: nil, modifiedAt: nil
            )
        )
    }

    /// The honesty test: the anchor is on the CONTENT block (`ch0-para`), not the
    /// heading. hasAudio for chapter 0 must STILL be true.
    @Test func hasAudioTrueWhenAnchorOnContentBlockNotHeading() throws {
        let db = try seed()
        try insertAnchor(db, block: "ch0-para")
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 0) == true)
    }

    @Test func hasAudioFalseWhenChapterHasNoAnchors() throws {
        let db = try seed()
        try insertAnchor(db, block: "ch0-para")  // chapter 0 only; chapter 1 has none
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 1) == false)
    }

    @Test func hasAudioFalseWhenChapterHasNoBlocks() throws {
        let db = try seed()
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 99) == false)
    }
}
