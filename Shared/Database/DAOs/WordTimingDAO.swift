// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// DAO for per-word read-along timings.
nonisolated struct WordTimingDAO {
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

    /// Replaces a book (nil blockIDs) or explicit block set atomically. Empty
    /// records deliberately clear the requested scope; an empty block set is a no-op.
    func replace(
        _ records: [WordTimingRecord], forAudiobook audiobookID: String,
        blockIDs: [String]? = nil
    ) throws {
        try db.write { db in
            try Self.replace(records, forAudiobook: audiobookID, blockIDs: blockIDs, in: db)
        }
    }

    /// Composes with an existing writer transaction; never opens a nested write.
    static func replace(
        _ records: [WordTimingRecord], forAudiobook audiobookID: String,
        blockIDs: [String]? = nil, in db: Database,
        checkCancellation: () throws -> Void = {}
    ) throws {
        if let blockIDs, blockIDs.isEmpty { return }
        precondition(records.allSatisfy {
            $0.audiobookID == audiobookID && (blockIDs?.contains($0.epubBlockID) ?? true)
        }, "Replacement records must belong to the requested scope")
        var query = WordTimingRecord.filter(Column("audiobook_id") == audiobookID)
        if let blockIDs { query = query.filter(blockIDs.contains(Column("epub_block_id"))) }
        try checkCancellation()
        try query.deleteAll(db)
        for var record in records {
            try checkCancellation()
            try record.insert(db)
        }
        try checkCancellation()
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

    /// Whether the book has *any* word-timing rows — the same condition the
    /// reader keys on to decide word-level vs block-level highlighting. Used by
    /// Book Settings to describe read-along for books imported before a sidecar
    /// summary was recorded. Counts rather than fetching all rows.
    func hasWordTimings(forAudiobook audiobookID: String) throws -> Bool {
        try db.read { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .fetchCount(db) > 0
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

    /// Deletes only the rows belonging to `blockIDs`, leaving the rest of the
    /// book's word rows intact. Lets the narration render loop rebuild one
    /// chapter's words without the whole-book wipe (which, run per chapter, made
    /// a render run O(N²)).
    @discardableResult
    func deleteAll(forAudiobook audiobookID: String, blockIDs: [String]) throws -> Int {
        guard !blockIDs.isEmpty else { return 0 }
        return try db.write { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("epub_block_id")))
                .deleteAll(db)
        }
    }
}
