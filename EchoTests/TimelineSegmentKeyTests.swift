// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct TimelineSegmentKeyTests {
    @Test func setSegmentKeyStampsOnlyRequestedBlocks() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBookAndTimeline(db)

        try TimelineDAO(db: db.writer).setSegmentKey(
            audiobookID: "book-1",
            blockIDs: ["b0", "b1"],
            segmentKey: "0-0")

        let keys = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT epub_block_id, segment_key
                    FROM timeline_item
                    WHERE audiobook_id = 'book-1'
                    ORDER BY epub_block_id
                    """)
                .map { row -> (String, String?) in
                    (row["epub_block_id"], row["segment_key"])
                }
        }

        #expect(keys.map(\.0) == ["b0", "b1", "b2"])
        #expect(keys.map(\.1) == ["0-0", "0-0", nil])
    }

    @Test func setSegmentKeyWithNoBlocksIsNoOp() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBookAndTimeline(db)

        try TimelineDAO(db: db.writer).setSegmentKey(
            audiobookID: "book-1",
            blockIDs: [],
            segmentKey: "0-0")

        let stampedCount = try db.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM timeline_item
                    WHERE audiobook_id = 'book-1' AND segment_key IS NOT NULL
                    """)
        }

        #expect(stampedCount == 0)
    }

    private func seedBookAndTimeline(_ service: DatabaseService) throws {
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Book', 3600)")
            for (index, blockID) in ["b0", "b1", "b2"].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO timeline_item (
                            id,
                            audiobook_id,
                            item_type,
                            title,
                            audio_start_time,
                            audio_end_time,
                            granularity_level,
                            is_enabled,
                            epub_block_id
                        )
                        VALUES (?, 'book-1', 'textSegment', ?, ?, ?, 1, 1, ?)
                        """,
                    arguments: [
                        "ti-\(blockID)",
                        "Block \(index)",
                        Double(index * 5),
                        Double(index * 5 + 5),
                        blockID,
                    ])
            }
        }
    }
}
