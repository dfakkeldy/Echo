// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V19 — per-word read-along timings for karaoke highlighting.
enum Schema_V19 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "word_timing") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull().indexed()
            t.column("epub_block_id", .text).notNull()
            t.column("word_index", .integer).notNull()
            t.column("word", .text).notNull()
            t.column("audio_start_time", .double).notNull()
            t.column("audio_end_time", .double).notNull()
            t.column("confidence", .double).notNull().defaults(to: 0.5)
            t.column("source", .text).notNull().defaults(to: "interpolated")
        }
        // Reader loads the whole book ordered by time; per-block lookups during refine.
        try db.create(
            index: "idx_word_timing_book_block",
            on: "word_timing",
            columns: ["audiobook_id", "epub_block_id", "word_index"])
    }
}
