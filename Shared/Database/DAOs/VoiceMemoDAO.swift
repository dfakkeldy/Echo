// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

struct VoiceMemoDAO {
    let db: DatabaseWriter

    func memos(for audiobookID: String) throws -> [VoiceMemoRecord] {
        try db.read { db in
            try VoiceMemoRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("media_timestamp"), Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Memos whose `epub_block_id` is one of `blockIDs`, for feed injection.
    /// Note: the VM feeds `FeedItemInjector` via `memos(for:)` + in-memory
    /// grouping; this query is tested and available for future callers (e.g.
    /// per-chapter loading), but is not called in the current shipping path.
    func memos(withEpubBlockIDsIn blockIDs: [String], audiobookID: String) throws
        -> [VoiceMemoRecord]
    {
        guard !blockIDs.isEmpty else { return [] }
        return try db.read { db in
            try VoiceMemoRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("epub_block_id")))
                .order(Column("media_timestamp"), Column("created_at"))
                .fetchAll(db)
        }
    }

    func memo(id: String) throws -> VoiceMemoRecord? {
        try db.read { db in try VoiceMemoRecord.fetchOne(db, key: id) }
    }

    func insert(_ memo: VoiceMemoRecord) throws {
        var copy = memo
        try db.write { db in try copy.insert(db) }
    }

    func delete(id: String) throws {
        _ = try db.write { db in try VoiceMemoRecord.deleteOne(db, key: id) }
    }
}
