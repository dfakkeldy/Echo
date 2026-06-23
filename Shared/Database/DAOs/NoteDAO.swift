// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct NoteDAO {
    let db: DatabaseWriter

    func notes(for audiobookID: String) throws -> [NoteRecord] {
        try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("media_timestamp"))
                .fetchAll(db)
        }
    }

    /// Notes whose `epub_block_id` is one of `blockIDs`, for feed injection.
    /// Note: the VM feeds `FeedItemInjector` via `notes(for:)` + in-memory
    /// grouping; this query is tested and available for future callers (e.g.
    /// per-chapter loading), but is not called in the current shipping path.
    func notes(withEpubBlockIDsIn blockIDs: [String], audiobookID: String) throws -> [NoteRecord] {
        guard !blockIDs.isEmpty else { return [] }
        return try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("epub_block_id")))
                .order(Column("media_timestamp"), Column("created_at"))
                .fetchAll(db)
        }
    }

    func notes(in timeRange: ClosedRange<TimeInterval>, audiobookID: String) throws -> [NoteRecord]
    {
        try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(
                    Column("media_timestamp") >= timeRange.lowerBound
                        && Column("media_timestamp") <= timeRange.upperBound
                )
                .order(Column("media_timestamp"))
                .fetchAll(db)
        }
    }

    func note(id: String) throws -> NoteRecord? {
        try db.read { db in try NoteRecord.fetchOne(db, key: id) }
    }

    func insert(_ note: NoteRecord) throws {
        var copy = note
        try db.write { db in try copy.insert(db) }
    }

    func update(_ note: NoteRecord) throws {
        var copy = note
        try db.write { db in try copy.save(db) }
    }

    func delete(id: String) throws {
        _ = try db.write { db in try NoteRecord.deleteOne(db, key: id) }
    }

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    func count(for audiobookID: String) throws -> Int {
        try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .fetchCount(db)
        }
    }
}
