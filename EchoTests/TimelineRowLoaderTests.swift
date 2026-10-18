// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct TimelineRowLoaderTests {
    @Test func loadsRowsWithDerivedEndTimesAndChapterIndex() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 60)"
            )
            try database.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES ('b1', 'book', 's', 0, 0, 0, 'paragraph', 'Hello', 2, 0)
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, item_type, title, audio_start_time,
                       audio_end_time, epub_block_id, segment_key, alignment_status)
                    VALUES ('t1', 'book', 'textSegment', 'x', 1.0, NULL, 'b1', '2-0', 'test')
                    """
            )
        }

        let rows = try TimelineRowLoader.rows(audiobookID: "book", db: db.writer)
        #expect(rows.count == 1)
        #expect(rows[0].start == 1.0)
        #expect(rows[0].end == 3601.0)
        #expect(rows[0].blockID == "b1")
        #expect(rows[0].chapterIndex == 2)
        #expect(rows[0].segmentKey == "2-0")
    }
}
