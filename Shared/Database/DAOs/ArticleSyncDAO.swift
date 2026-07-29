// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import CryptoKit
import Foundation
import GRDB

nonisolated enum ArticleCloudRecordType: String, Codable, CaseIterable, Sendable {
    case capture = "EchoArticleCapture"
    case revision = "EchoArticleRevision"
    case anthology = "EchoAnthology"

    var recordNamePrefix: String {
        switch self {
        case .capture: "capture"
        case .revision: "revision"
        case .anthology: "anthology"
        }
    }
}

nonisolated enum ArticleSyncOperation: String, Codable, Sendable {
    case save
    case delete
}

nonisolated enum ArticleSyncAccountStatus: String, Codable, Sendable {
    case unknown
    case available
    case signedOut
    case switchedAccount
    case restricted
    case temporarilyUnavailable
}

nonisolated struct ArticlePendingCloudChange: Codable, Equatable, Hashable, Sendable {
    var recordName: String
    var recordType: ArticleCloudRecordType
    var entityID: String
    var operation: ArticleSyncOperation
    var queuedAt: String
}

nonisolated struct ArticleSyncStateSnapshot: Equatable, Sendable {
    let engineState: Data?
    let accountStatus: ArticleSyncAccountStatus
    let lastErrorCode: String?
    let updatedAt: String
}

nonisolated struct ArticleCloudAnthologyManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var anthology: AnthologyRecord
    var entries: [AnthologyEntryRecord]

    init(
        schemaVersion: Int,
        anthology: AnthologyRecord,
        entries: [AnthologyEntryRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.anthology = anthology
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case anthology
        case entries
    }

    private struct CloudAnthology: Codable {
        let id: String
        let title: String
        let subtitle: String?
        let creator: String?
        let nextStableSlot: Int
        let createdAt: String
        let modifiedAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case subtitle
            case creator
            case nextStableSlot = "next_stable_slot"
            case createdAt = "created_at"
            case modifiedAt = "modified_at"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let cloud = try container.decode(CloudAnthology.self, forKey: .anthology)
        anthology = AnthologyRecord(
            id: cloud.id,
            title: cloud.title,
            subtitle: cloud.subtitle,
            creator: cloud.creator,
            coverPath: nil,
            nextStableSlot: cloud.nextStableSlot,
            latestBuildRevision: 0,
            createdAt: cloud.createdAt,
            modifiedAt: cloud.modifiedAt)
        entries = try container.decode([AnthologyEntryRecord].self, forKey: .entries)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            CloudAnthology(
                id: anthology.id,
                title: anthology.title,
                subtitle: anthology.subtitle,
                creator: anthology.creator,
                nextStableSlot: anthology.nextStableSlot,
                createdAt: anthology.createdAt,
                modifiedAt: anthology.modifiedAt),
            forKey: .anthology)
        try container.encode(entries, forKey: .entries)
    }
}

nonisolated enum ArticleFetchedDatabaseChange: Equatable, Sendable {
    case capture(ArticleCaptureRecord)
    case revision(ArticleRevisionRecord)
    case anthology(ArticleCloudAnthologyManifest)
    case delete(recordType: ArticleCloudRecordType, entityID: String)
}

nonisolated enum ArticleSyncConflictIdentity {
    static func recoveredAnthologyID(
        incoming: ArticleCloudAnthologyManifest,
        existing: ArticleCloudAnthologyManifest
    ) -> UUID {
        let incomingEntries = incoming.entries
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.id < rhs.id
            }
            .map {
                [
                    $0.id,
                    $0.captureID,
                    String($0.sortOrder),
                    String($0.stableSlot),
                    $0.chapterTitleOverride ?? "",
                    $0.narrationVoiceID ?? "",
                ].joined(separator: "\u{0}")
            }
            .joined(separator: "\u{1}")
        return deterministicUUID(
            seed: [
                "echo.article.anthology.recovered.v1",
                existing.anthology.id,
                existing.anthology.modifiedAt,
                incoming.anthology.id,
                incoming.anthology.modifiedAt,
                incoming.anthology.title,
                incomingEntries,
            ].joined(separator: "\u{2}"))
    }

    static func recoveredEntryID(recoveredAnthologyID: UUID, entryID: String) -> UUID {
        deterministicUUID(seed: "\(recoveredAnthologyID.uuidString)\u{0}\(entryID)")
    }

    private static func deterministicUUID(seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

nonisolated struct ArticleSyncDAO: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case invalidRecordType(String)
        case invalidOperation(String)
        case invalidAccountStatus(String)
        case invalidEngineState
    }

    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    func saveEngineState(
        _ serialization: CKSyncEngine.State.Serialization,
        accountStatus: ArticleSyncAccountStatus? = nil,
        lastErrorCode: String? = nil,
        updatedAt: String
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(serialization)
        try db.write { db in
            let storedStatus = try String.fetchOne(
                db,
                sql: "SELECT account_status FROM article_sync_state WHERE id = 'default'")
            let currentStatus =
                accountStatus?.rawValue
                ?? storedStatus
                ?? ArticleSyncAccountStatus.unknown.rawValue
            try db.execute(
                sql: """
                    INSERT INTO article_sync_state (
                        id, engine_state, account_status, last_error_code, updated_at
                    )
                    VALUES ('default', ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        engine_state = excluded.engine_state,
                        account_status = excluded.account_status,
                        last_error_code = excluded.last_error_code,
                        updated_at = excluded.updated_at
                    """,
                arguments: [data, currentStatus, lastErrorCode, updatedAt])
        }
    }

    func engineState() throws -> CKSyncEngine.State.Serialization? {
        guard
            let data = try db.read({ db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT engine_state FROM article_sync_state WHERE id = 'default'")
            })
        else {
            return nil
        }
        do {
            return try PropertyListDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: data)
        } catch {
            throw Error.invalidEngineState
        }
    }

    func updateStatus(
        _ accountStatus: ArticleSyncAccountStatus,
        lastErrorCode: String?,
        updatedAt: String
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article_sync_state (
                        id, engine_state, account_status, last_error_code, updated_at
                    )
                    VALUES ('default', NULL, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_status = excluded.account_status,
                        last_error_code = excluded.last_error_code,
                        updated_at = excluded.updated_at
                    """,
                arguments: [accountStatus.rawValue, lastErrorCode, updatedAt])
        }
    }

    func state() throws -> ArticleSyncStateSnapshot? {
        try db.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT engine_state, account_status, last_error_code, updated_at
                        FROM article_sync_state
                        WHERE id = 'default'
                        """)
            else {
                return nil
            }
            let rawStatus: String = row["account_status"]
            guard let accountStatus = ArticleSyncAccountStatus(rawValue: rawStatus) else {
                throw Error.invalidAccountStatus(rawStatus)
            }
            return ArticleSyncStateSnapshot(
                engineState: row["engine_state"],
                accountStatus: accountStatus,
                lastErrorCode: row["last_error_code"],
                updatedAt: row["updated_at"])
        }
    }

    func enqueue(_ change: ArticlePendingCloudChange) throws {
        try enqueue([change])
    }

    func enqueue(_ changes: [ArticlePendingCloudChange]) throws {
        guard changes.isEmpty == false else { return }
        try db.write { db in
            for change in changes {
                try db.execute(
                    sql: """
                        INSERT INTO article_sync_outbox (
                            record_name, record_type, entity_id, operation, queued_at
                        )
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(record_name) DO UPDATE SET
                            record_type = excluded.record_type,
                            entity_id = excluded.entity_id,
                            operation = excluded.operation,
                            queued_at = excluded.queued_at
                        """,
                    arguments: [
                        change.recordName,
                        change.recordType.rawValue,
                        change.entityID,
                        change.operation.rawValue,
                        change.queuedAt,
                    ])
            }
        }
    }

    func pendingChanges(limit: Int? = nil) throws -> [ArticlePendingCloudChange] {
        try db.read { db in
            let sql =
                """
                SELECT record_name, record_type, entity_id, operation, queued_at
                FROM article_sync_outbox
                ORDER BY queued_at, record_name
                """
                + (limit == nil ? "" : " LIMIT ?")
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: limit.map { StatementArguments([$0]) } ?? StatementArguments())
            return try rows.map { row in
                let rawType: String = row["record_type"]
                guard let recordType = ArticleCloudRecordType(rawValue: rawType) else {
                    throw Error.invalidRecordType(rawType)
                }
                let rawOperation: String = row["operation"]
                guard let operation = ArticleSyncOperation(rawValue: rawOperation) else {
                    throw Error.invalidOperation(rawOperation)
                }
                return ArticlePendingCloudChange(
                    recordName: row["record_name"],
                    recordType: recordType,
                    entityID: row["entity_id"],
                    operation: operation,
                    queuedAt: row["queued_at"])
            }
        }
    }

    func pendingChange(recordName: String) throws -> ArticlePendingCloudChange? {
        try pendingChanges().first { $0.recordName == recordName }
    }

    func acknowledgeSaved(recordNames: [String]) throws {
        try acknowledge(recordNames: recordNames, operation: .save)
    }

    func acknowledgeDeleted(recordNames: [String]) throws {
        try acknowledge(recordNames: recordNames, operation: .delete)
    }

    func capture(id: String) throws -> ArticleCaptureRecord? {
        try db.read { try ArticleCaptureRecord.fetchOne($0, key: id) }
    }

    func revision(id: String) throws -> ArticleRevisionRecord? {
        try db.read { try ArticleRevisionRecord.fetchOne($0, key: id) }
    }

    func revisions(captureID: String) throws -> [ArticleRevisionRecord] {
        try db.read {
            try ArticleRevisionRecord
                .filter(Column("capture_id") == captureID)
                .order(Column("created_at"), Column("id"))
                .fetchAll($0)
        }
    }

    func anthologyManifest(id: String) throws -> ArticleCloudAnthologyManifest? {
        try db.read { db in
            guard let anthology = try AnthologyRecord.fetchOne(db, key: id) else {
                return nil
            }
            let entries =
                try AnthologyEntryRecord
                .filter(Column("anthology_id") == id)
                .order(Column("sort_order"), Column("stable_slot"), Column("id"))
                .fetchAll(db)
            return ArticleCloudAnthologyManifest(
                schemaVersion: 1,
                anthology: anthology,
                entries: entries)
        }
    }

    /// Applies one fetched CloudKit event in a single SQLite transaction.
    /// Immutable revision siblings are retained, and concurrent anthology
    /// manifests produce a durable recovered copy instead of overwriting local work.
    func applyFetchedChanges(_ changes: [ArticleFetchedDatabaseChange]) throws {
        guard changes.isEmpty == false else { return }
        try db.write { db in
            for change in changes {
                guard case .capture(var capture) = change else { continue }
                guard try ArticleCaptureRecord.fetchOne(db, key: capture.id) == nil else {
                    continue
                }
                try capture.insert(db)
            }

            for change in changes {
                guard case .revision(var revision) = change else { continue }
                guard try ArticleRevisionRecord.fetchOne(db, key: revision.id) == nil else {
                    continue
                }
                try revision.insert(db)
                let currentRevisionID = try String.fetchOne(
                    db,
                    sql: "SELECT current_revision_id FROM article_capture WHERE id = ?",
                    arguments: [revision.captureID])
                if currentRevisionID == nil || currentRevisionID == revision.parentRevisionID {
                    try db.execute(
                        sql: """
                            UPDATE article_capture
                            SET current_revision_id = ?
                            WHERE id = ?
                            """,
                        arguments: [revision.id, revision.captureID])
                }
            }

            for change in changes {
                guard case .anthology(let manifest) = change else { continue }
                try applyFetchedAnthology(manifest, db: db)
            }

            for recordType in [
                ArticleCloudRecordType.anthology,
                .revision,
                .capture,
            ] {
                for change in changes {
                    guard
                        case .delete(let deletedType, let entityID) = change,
                        deletedType == recordType
                    else {
                        continue
                    }
                    try applyFetchedDeletion(
                        recordType: deletedType,
                        entityID: entityID,
                        db: db)
                }
            }
        }
    }

    private func acknowledge(
        recordNames: [String],
        operation: ArticleSyncOperation
    ) throws {
        guard recordNames.isEmpty == false else { return }
        try db.write { db in
            for recordName in Set(recordNames) {
                try db.execute(
                    sql: """
                        DELETE FROM article_sync_outbox
                        WHERE record_name = ? AND operation = ?
                        """,
                    arguments: [recordName, operation.rawValue])
            }
        }
    }

    private func applyFetchedAnthology(
        _ incoming: ArticleCloudAnthologyManifest,
        db: Database
    ) throws {
        guard let existingAnthology = try AnthologyRecord.fetchOne(db, key: incoming.anthology.id)
        else {
            try insertAnthologyManifest(incoming, db: db)
            return
        }
        let existingEntries =
            try AnthologyEntryRecord
            .filter(Column("anthology_id") == existingAnthology.id)
            .order(Column("sort_order"), Column("stable_slot"), Column("id"))
            .fetchAll(db)
        let existing = ArticleCloudAnthologyManifest(
            schemaVersion: incoming.schemaVersion,
            anthology: existingAnthology,
            entries: existingEntries)
        if cloudComparable(existing) == cloudComparable(incoming) {
            if existing.anthology.coverPath != incoming.anthology.coverPath {
                try db.execute(
                    sql: "UPDATE anthology SET cover_path = ? WHERE id = ?",
                    arguments: [
                        incoming.anthology.coverPath,
                        incoming.anthology.id,
                    ])
            }
            return
        }

        let recoveredID = ArticleSyncConflictIdentity.recoveredAnthologyID(
            incoming: incoming,
            existing: existing)
        guard try AnthologyRecord.fetchOne(db, key: recoveredID.uuidString) == nil else {
            return
        }
        var recoveredAnthology = incoming.anthology
        recoveredAnthology.id = recoveredID.uuidString
        if recoveredAnthology.title.hasSuffix(" (Recovered)") == false {
            recoveredAnthology.title += " (Recovered)"
        }
        recoveredAnthology.createdAt = incoming.anthology.modifiedAt
        let recoveredEntries = incoming.entries.map { entry in
            var copy = entry
            copy.id =
                ArticleSyncConflictIdentity.recoveredEntryID(
                    recoveredAnthologyID: recoveredID,
                    entryID: entry.id
                ).uuidString
            copy.anthologyID = recoveredID.uuidString
            return copy
        }
        try insertAnthologyManifest(
            ArticleCloudAnthologyManifest(
                schemaVersion: incoming.schemaVersion,
                anthology: recoveredAnthology,
                entries: recoveredEntries),
            db: db)
        let recordName =
            "\(ArticleCloudRecordType.anthology.recordNamePrefix).\(recoveredID.uuidString)"
        try db.execute(
            sql: """
                INSERT INTO article_sync_outbox (
                    record_name, record_type, entity_id, operation, queued_at
                )
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(record_name) DO NOTHING
                """,
            arguments: [
                recordName,
                ArticleCloudRecordType.anthology.rawValue,
                recoveredID.uuidString,
                ArticleSyncOperation.save.rawValue,
                incoming.anthology.modifiedAt,
            ])
    }

    private func cloudComparable(
        _ manifest: ArticleCloudAnthologyManifest
    ) -> ArticleCloudAnthologyManifest {
        var result = manifest
        result.anthology.coverPath = nil
        result.anthology.latestBuildRevision = 0
        return result
    }

    private func insertAnthologyManifest(
        _ manifest: ArticleCloudAnthologyManifest,
        db: Database
    ) throws {
        var anthology = manifest.anthology
        try anthology.insert(db)
        for entry in manifest.entries {
            var entry = entry
            try entry.insert(db)
        }
    }

    private func applyFetchedDeletion(
        recordType: ArticleCloudRecordType,
        entityID: String,
        db: Database
    ) throws {
        let recordName = "\(recordType.recordNamePrefix).\(entityID)"
        let hasPendingLocalChange =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM article_sync_outbox WHERE record_name = ?
                    )
                    """,
                arguments: [recordName]) ?? false
        guard hasPendingLocalChange == false else { return }

        switch recordType {
        case .capture:
            let isReferenced =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM anthology_entry WHERE capture_id = ?
                        )
                        """,
                    arguments: [entityID]) ?? false
            if isReferenced == false {
                _ = try ArticleCaptureRecord.deleteOne(db, key: entityID)
            }
        case .revision:
            if let revision = try ArticleRevisionRecord.fetchOne(db, key: entityID) {
                try db.execute(
                    sql: """
                        UPDATE article_capture
                        SET current_revision_id = ?
                        WHERE id = ? AND current_revision_id = ?
                        """,
                    arguments: [
                        revision.parentRevisionID,
                        revision.captureID,
                        revision.id,
                    ])
                _ = try ArticleRevisionRecord.deleteOne(db, key: entityID)
            }
        case .anthology:
            _ = try AnthologyRecord.deleteOne(db, key: entityID)
        }
    }
}
