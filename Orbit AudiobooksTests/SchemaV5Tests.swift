import Testing
import Foundation
import GRDB
@testable import Orbit_Audiobooks

@MainActor
struct SchemaV5Tests {

    // MARK: - Schema_V5 table creation

    @Test func v5MigrationCreatesEPubBlockTable() throws {
        let db = try DatabaseService(inMemory: ())

        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name='epub_block'
                """)
        }
        #expect(tables.count == 1)
    }

    @Test func v5MigrationCreatesAlignmentAnchorTable() throws {
        let db = try DatabaseService(inMemory: ())

        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name='alignment_anchor'
                """)
        }
        #expect(tables.count == 1)
    }

    @Test func v5MigrationAddsTimelineAlignmentColumns() throws {
        let db = try DatabaseService(inMemory: ())

        let columnNames = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(timeline_item)")
                .map { $0["name"] as? String ?? "" }
        }
        let nameSet = Set(columnNames)
        #expect(nameSet.contains("epub_block_id"))
        #expect(nameSet.contains("timestamp_source"))
        #expect(nameSet.contains("alignment_status"))
        #expect(nameSet.contains("alignment_confidence"))
    }

    @Test func v5EPubBlockIndexesExist() throws {
        let db = try DatabaseService(inMemory: ())

        let indexes = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_epub_block%'
                """)
        }
        #expect(indexes.contains("idx_epub_block_sequence"))
        #expect(indexes.contains("idx_epub_block_chapter"))
        #expect(indexes.contains("idx_epub_block_hidden"))
    }

    @Test func v5AlignmentAnchorIndexesExist() throws {
        let db = try DatabaseService(inMemory: ())

        let indexes = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_alignment_anchor%'
                """)
        }
        #expect(indexes.contains("idx_alignment_anchor_time"))
        #expect(indexes.contains("idx_alignment_anchor_block"))
    }

    // MARK: - EPubBlockRecord persistence

    @Test func epubBlockInsertAndRead() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = EPubBlockDAO(db: db.writer)

        // Insert an audiobook for FK constraint.
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let block = EPubBlockRecord(
            id: "block-1",
            audiobookID: "book-1",
            spineHref: "chapter1.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: "paragraph",
            text: "It was a dark and stormy night.",
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            createdAt: nil,
            modifiedAt: nil
        )
        try dao.insert(block)

        let blocks = try dao.blocks(for: "book-1")
        #expect(blocks.count == 1)
        #expect(blocks.first?.spineHref == "chapter1.xhtml")
        #expect(blocks.first?.blockKind == "paragraph")
    }

    @Test func epubBlockHideUnhide() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = EPubBlockDAO(db: db.writer)

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let block = EPubBlockRecord(
            id: "block-1", audiobookID: "book-1",
            spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: "paragraph", text: "Test", chapterIndex: 0,
            isHidden: false
        )
        try dao.insert(block)

        try dao.hideBlock(id: "block-1", reason: "omitted from audio")
        let hiddenBlocks = try dao.blocks(for: "book-1")
        #expect(hiddenBlocks.first?.isHidden == true)
        #expect(hiddenBlocks.first?.hiddenReason == "omitted from audio")

        try dao.unhideBlock(id: "block-1")
        let visibleBlocks = try dao.visibleBlocks(for: "book-1")
        #expect(visibleBlocks.count == 1)
        #expect(visibleBlocks.first?.isHidden == false)
    }

    @Test func epubBlockVisibleExcludesHidden() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = EPubBlockDAO(db: db.writer)

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let b1 = EPubBlockRecord(
            id: "b1", audiobookID: "book-1",
            spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: "paragraph", text: "Visible", chapterIndex: 0,
            isHidden: false
        )
        let b2 = EPubBlockRecord(
            id: "b2", audiobookID: "book-1",
            spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 1, sequenceIndex: 1,
            blockKind: "paragraph", text: "Hidden", chapterIndex: 0,
            isHidden: true
        )
        try dao.insertAll([b1, b2])

        let all = try dao.blocks(for: "book-1")
        #expect(all.count == 2)

        let visible = try dao.visibleBlocks(for: "book-1")
        #expect(visible.count == 1)
        #expect(visible.first?.text == "Visible")
    }

    // MARK: - AlignmentAnchorRecord persistence

    @Test func alignmentAnchorInsertAndRead() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AlignmentAnchorDAO(db: db.writer)

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind)
                VALUES ('block-1', 'book-1', 'ch1.xhtml', 0, 0, 0, 'paragraph')
                """)
        }

        let anchor = AlignmentAnchorRecord(
            id: "anchor-1",
            audiobookID: "book-1",
            epubBlockID: "block-1",
            audioTime: 42.0,
            audioEndTime: nil,
            anchorKind: "point",
            source: "moveToNow",
            note: nil,
            createdAt: nil,
            modifiedAt: nil
        )
        try dao.insert(anchor)

        let anchors = try dao.anchors(for: "book-1")
        #expect(anchors.count == 1)
        #expect(anchors.first?.audioTime == 42.0)
        #expect(anchors.first?.anchorKind == "point")
    }

    @Test func alignmentAnchorBracketingQuery() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AlignmentAnchorDAO(db: db.writer)

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            for i in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind)
                    VALUES ('block-\(i)', 'book-1', 'ch1.xhtml', 0, \(i), \(i), 'paragraph')
                    """)
            }
        }

        let a1 = AlignmentAnchorRecord(
            id: "a1", audiobookID: "book-1", epubBlockID: "block-0",
            audioTime: 10.0, anchorKind: "point", source: "moveToNow"
        )
        let a2 = AlignmentAnchorRecord(
            id: "a2", audiobookID: "book-1", epubBlockID: "block-2",
            audioTime: 30.0, anchorKind: "point", source: "moveToNow"
        )
        try dao.insert(a1)
        try dao.insert(a2)

        let (before, after) = try dao.bracketingAnchors(for: "book-1", around: 20.0)
        #expect(before?.audioTime == 10.0)
        #expect(after?.audioTime == 30.0)
    }

    @Test func alignmentAnchorTimeRangeQuery() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AlignmentAnchorDAO(db: db.writer)

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            for i in 0..<5 {
                try db.execute(sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind)
                    VALUES ('block-\(i)', 'book-1', 'ch1.xhtml', 0, \(i), \(i), 'paragraph')
                    """)
            }
        }

        for (i, time) in [10.0, 20.0, 30.0, 40.0, 50.0].enumerated() {
            try dao.insert(AlignmentAnchorRecord(
                id: "a\(i)", audiobookID: "book-1", epubBlockID: "block-\(i)",
                audioTime: time, anchorKind: "point", source: "moveToNow"
            ))
        }

        let mid = try dao.anchors(for: "book-1", in: 25...45)
        #expect(mid.count == 2)  // anchors at times 30 and 40
    }
}
