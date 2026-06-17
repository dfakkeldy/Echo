// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct WordTimingMaterializerTests {
    /// Seeds two aligned blocks in timeline_item and expects word rows spanning
    /// each block's [start, nextStart).
    @Test func materializesWordsBetweenBlockAnchors() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            // audiobook row (FK target for epub_block / timeline_item)
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration)
                    VALUES ('bk', 'Book', 100.0)
                    """)
            // epub_block rows so block text is available
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph','one two', 0),
                           ('b1','bk','c.xhtml',0,1,1,'paragraph','three', 0)
                    """)
            // timeline_item block-level rows with real start times
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                       granularity_level, is_enabled, epub_block_id)
                    VALUES ('t0','bk','textSegment','', 0.0, 10.0, 1, 1, 'b0'),
                           ('t1','bk','textSegment','', 10.0, 14.0, 1, 1, 'b1')
                    """)
        }
        try WordTimingMaterializer.materialize(audiobookID: "bk", writer: db.writer)

        let dao = WordTimingDAO(db: db.writer)
        let b0 = try dao.words(forAudiobook: "bk", blockID: "b0")
        #expect(b0.map(\.word) == ["one", "two"])
        #expect(abs(b0[0].audioStartTime - 0.0) < 0.01)
        #expect(b0.last!.audioEndTime <= 10.01)

        let b1 = try dao.words(forAudiobook: "bk", blockID: "b1")
        #expect(b1.map(\.word) == ["three"])
        #expect(b1[0].audioStartTime >= 10.0)
    }

    @Test func reRunClearsPriorRows() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration)
                    VALUES ('bk', 'Book', 100.0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph','hello world', 0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                       granularity_level, is_enabled, epub_block_id)
                    VALUES ('t0','bk','textSegment','', 0.0, 4.0, 1, 1, 'b0')
                    """)
        }
        try WordTimingMaterializer.materialize(audiobookID: "bk", writer: db.writer)
        try WordTimingMaterializer.materialize(audiobookID: "bk", writer: db.writer)
        #expect(try WordTimingDAO(db: db.writer).words(forAudiobook: "bk").count == 2)
    }
}
