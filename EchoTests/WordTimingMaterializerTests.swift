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

    /// The per-chapter materialize must rebuild ONLY its chapter's word rows and
    /// leave other chapters' rows intact — the property that turns the render
    /// run's word-timing work from O(chapters²) (whole-book rebuild per chapter)
    /// into O(chapters). If `materializeChapter` wiped book-wide, rendering
    /// chapter 1 would erase chapter 0's already-materialized words.
    @Test func materializeChapterLeavesOtherChaptersUntouched() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',100.0)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('c0b0','bk','c0.xhtml',0,0,0,'paragraph','alpha beta', 0),
                           ('c1b0','bk','c1.xhtml',1,0,1,'paragraph','gamma delta', 0)
                    """)
            // Each chapter is its own audio file → 0-based start times.
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                       granularity_level, is_enabled, epub_block_id)
                    VALUES ('t0','bk','textSegment','', 0.0, 6.0, 1, 1, 'c0b0'),
                           ('t1','bk','textSegment','', 0.0, 6.0, 1, 1, 'c1b0')
                    """)
        }
        let dao = WordTimingDAO(db: db.writer)

        // Render chapter 0, then chapter 1 — mirroring the per-chapter loop.
        try WordTimingMaterializer.materializeChapter(
            audiobookID: "bk", blockIDs: ["c0b0"], writer: db.writer)
        #expect(
            try dao.words(forAudiobook: "bk", blockID: "c0b0").map(\.word) == ["alpha", "beta"])

        try WordTimingMaterializer.materializeChapter(
            audiobookID: "bk", blockIDs: ["c1b0"], writer: db.writer)
        // Chapter 1's words landed…
        #expect(
            try dao.words(forAudiobook: "bk", blockID: "c1b0").map(\.word) == ["gamma", "delta"])
        // …and chapter 0's were NOT wiped by chapter 1's render.
        #expect(
            try dao.words(forAudiobook: "bk", blockID: "c0b0").map(\.word) == ["alpha", "beta"])
    }

    /// The block-scoped delete underpinning the per-chapter materialize removes
    /// only the named blocks' rows.
    @Test func blockScopedDeleteRemovesOnlyNamedBlocks() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',1.0)")
        }
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b0", wordIndex: 0, word: "a",
                audioStartTime: 0, audioEndTime: 1, confidence: 0.5, source: "interpolated"),
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b1", wordIndex: 0, word: "b",
                audioStartTime: 1, audioEndTime: 2, confidence: 0.5, source: "interpolated"),
        ])
        let removed = try dao.deleteAll(forAudiobook: "bk", blockIDs: ["b0"])
        #expect(removed == 1)
        #expect(try dao.words(forAudiobook: "bk").map(\.epubBlockID) == ["b1"])
    }
}
