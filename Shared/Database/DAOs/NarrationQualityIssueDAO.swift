// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct NarrationQualityIssueDAO {
    let db: DatabaseWriter

    func insert(_ records: [NarrationQualityIssueRecord]) throws {
        guard !records.isEmpty else { return }
        try db.write { db in
            for var r in records { try r.insert(db) }
        }
    }

    func issues(for audiobookID: String) throws -> [NarrationQualityIssueRecord] {
        try db.read { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_start_time"))
                .fetchAll(db)
        }
    }

    func issues(for audiobookID: String, status: String) throws -> [NarrationQualityIssueRecord] {
        try db.read { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("status") == status)
                .order(Column("audio_start_time"))
                .fetchAll(db)
        }
    }

    func updateStatus(id: String, status: String, resolvedAt: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE narration_quality_issue SET status = ?, resolved_at = ? WHERE id = ?",
                arguments: [status, resolvedAt, id])
        }
    }

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    func deleteAll(for audiobookID: String, blockIDs: [String]) throws {
        guard !blockIDs.isEmpty else { return }
        _ = try db.write { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("source_block_id")))
                .deleteAll(db)
        }
    }

    /// Deletes only the OPEN issues for the given blocks, preserving the user's
    /// resolved/ignored verdicts. Used before a re-QA pass so re-running QA
    /// converges on the open queue without destroying triaged audit history.
    func deleteOpen(for audiobookID: String, blockIDs: [String]) throws {
        guard !blockIDs.isEmpty else { return }
        _ = try db.write { db in
            try NarrationQualityIssueRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("source_block_id")))
                .filter(Column("status") == NarrationQAIssueStatus.open.rawValue)
                .deleteAll(db)
        }
    }
}
