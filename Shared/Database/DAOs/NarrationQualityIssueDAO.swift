// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

enum NarrationQualityIssueDAOError: Error, Equatable {
    case replacementOriginMismatch
    case replacementAudiobookMismatch
    case replacementBlockMismatch
    case replacementStatusMismatch
    case emptyReplacementBlockIDs
    case duplicateReplacementOrigin
}

struct NarrationQualityIssueDAO {
    struct OpenReplacement: Sendable {
        let origin: NarrationQualityIssueOrigin
        let records: [NarrationQualityIssueRecord]
    }
    let db: DatabaseWriter

    func insert(_ records: [NarrationQualityIssueRecord]) throws {
        guard !records.isEmpty else { return }
        try db.write { db in
            for var r in records { try r.insert(db) }
        }
    }

    /// Atomically replaces the current OPEN issues for a chapter/block set.
    /// Resolved and ignored rows survive as audit history.
    func replaceOpen(
        for audiobookID: String,
        blockIDs: [String],
        origin: NarrationQualityIssueOrigin,
        with records: [NarrationQualityIssueRecord]
    ) throws {
        try replaceOpen(for: audiobookID, blockIDs: blockIDs, replacements: [
            OpenReplacement(origin: origin, records: records)
        ])
    }

    /// Replaces multiple lanes atomically. Every batch is fully validated
    /// before any deletion, so one bad lane cannot leave a partial report.
    func replaceOpen(
        for audiobookID: String,
        blockIDs: [String],
        replacements: [OpenReplacement]
    ) throws {
        if blockIDs.isEmpty {
            guard replacements.contains(where: { !$0.records.isEmpty }) else { return }
            throw NarrationQualityIssueDAOError.emptyReplacementBlockIDs
        }
        var origins: Set<NarrationQualityIssueOrigin> = []
        for replacement in replacements {
            guard origins.insert(replacement.origin).inserted else {
                throw NarrationQualityIssueDAOError.duplicateReplacementOrigin
            }
            guard replacement.records.allSatisfy({ $0.origin == replacement.origin.rawValue }) else {
                throw NarrationQualityIssueDAOError.replacementOriginMismatch
            }
            guard replacement.records.allSatisfy({ $0.audiobookID == audiobookID }) else {
                throw NarrationQualityIssueDAOError.replacementAudiobookMismatch
            }
            guard replacement.records.allSatisfy({
                $0.sourceBlockID.map(blockIDs.contains) ?? false
            }) else { throw NarrationQualityIssueDAOError.replacementBlockMismatch }
            guard replacement.records.allSatisfy({ $0.status == NarrationQAIssueStatus.open.rawValue }) else {
                throw NarrationQualityIssueDAOError.replacementStatusMismatch
            }
        }
        try db.write { db in
            for replacement in replacements {
                let preservedIDs = Set(try NarrationQualityIssueRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .filter(blockIDs.contains(Column("source_block_id")))
                    .filter(Column("origin") == replacement.origin.rawValue)
                    .filter(Column("status") != NarrationQAIssueStatus.open.rawValue)
                    .fetchAll(db)
                    .map(\.id))
                _ = try NarrationQualityIssueRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .filter(blockIDs.contains(Column("source_block_id")))
                    .filter(Column("status") == NarrationQAIssueStatus.open.rawValue)
                    .filter(Column("origin") == replacement.origin.rawValue)
                    .deleteAll(db)
                for var record in replacement.records where !preservedIDs.contains(record.id) {
                    try record.insert(db)
                }
            }
        }
    }

    /// Saves the accepted issue as resolved after repair + re-QA succeed. Re-QA
    /// may delete the original open row first, so this intentionally upserts the
    /// audit record instead of assuming the row still exists.
    func saveResolvedAudit(_ record: NarrationQualityIssueRecord, resolvedAt: String) throws {
        try db.write { db in
            var resolved = record
            resolved.status = NarrationQAIssueStatus.resolved.rawValue
            resolved.resolvedAt = resolvedAt
            try resolved.save(db)
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
