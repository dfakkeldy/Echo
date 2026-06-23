// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

struct AlignmentAnchorExistsTests {
    /// Audiobook `book-1` with three paragraph blocks: b-head, b-para, b-other.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1','Test',3600)")
            for (i, id) in ["b-head", "b-para", "b-other"].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind)
                        VALUES (?, 'book-1', 'c1.xhtml', 0, ?, ?, 'paragraph')
                        """, arguments: [id, i, i])
            }
        }
        return db
    }

    private func anchor(_ id: String, block: String, time: Double) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id, audiobookID: "book-1", epubBlockID: block,
            audioTime: time, audioEndTime: nil, anchorKind: "point",
            source: "autoAlignment", note: nil, createdAt: nil, modifiedAt: nil
        )
    }

    @Test func returnsTrueWhenAnyGivenBlockHasAnchor() throws {
        let db = try seed()
        try AlignmentAnchorDAO(db: db.writer).insert(anchor("a1", block: "b-para", time: 12))
        let has = try AlignmentAnchorDAO(db: db.writer)
            .hasAnchor(for: "book-1", anyOf: ["b-head", "b-para"])
        #expect(has == true)
    }

    @Test func returnsFalseWhenNoGivenBlockHasAnchor() throws {
        let db = try seed()
        try AlignmentAnchorDAO(db: db.writer).insert(anchor("a1", block: "b-other", time: 5))
        let has = try AlignmentAnchorDAO(db: db.writer)
            .hasAnchor(for: "book-1", anyOf: ["b-head", "b-para"])
        #expect(has == false)
    }

    @Test func returnsFalseForEmptyBlockList() throws {
        let db = try seed()
        let has = try AlignmentAnchorDAO(db: db.writer)
            .hasAnchor(for: "book-1", anyOf: [])
        #expect(has == false)
    }
}
