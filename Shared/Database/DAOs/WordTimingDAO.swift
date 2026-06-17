// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// DAO for per-word read-along timings.
struct WordTimingDAO {
    let db: DatabaseWriter

    func insert(_ records: [WordTimingRecord]) throws {
        guard !records.isEmpty else { return }
        try db.write { db in
            for record in records {
                var mutable = record
                try mutable.insert(db)
            }
        }
    }

    /// Updates existing rows in place (matched by primary key). Used by the
    /// DTW refinement pass to retime already-materialized interpolated words.
    func update(_ records: [WordTimingRecord]) throws {
        guard !records.isEmpty else { return }
        try db.write { db in
            for record in records {
                try record.update(db)
            }
        }
    }

    /// All words for a book, ordered by audio time (reader cache order).
    func words(forAudiobook audiobookID: String) throws -> [WordTimingRecord] {
        try db.read { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_start_time"))
                .fetchAll(db)
        }
    }

    /// Words for one block, ordered by word index.
    func words(forAudiobook audiobookID: String, blockID: String) throws -> [WordTimingRecord] {
        try db.read { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("epub_block_id") == blockID)
                .order(Column("word_index"))
                .fetchAll(db)
        }
    }

    @discardableResult
    func deleteAll(forAudiobook audiobookID: String) throws -> Int {
        try db.write { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
