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
    var generation: Int64
    var accountOwnerID: String?
    var queuedAt: String

    init(
        recordName: String,
        recordType: ArticleCloudRecordType,
        entityID: String,
        operation: ArticleSyncOperation,
        generation: Int64 = 1,
        accountOwnerID: String? = nil,
        queuedAt: String
    ) {
        self.recordName = recordName
        self.recordType = recordType
        self.entityID = entityID
        self.operation = operation
        self.generation = generation
        self.accountOwnerID = accountOwnerID
        self.queuedAt = queuedAt
    }
}

nonisolated struct ArticleSyncStateSnapshot: Equatable, Sendable {
    let engineState: Data?
    let accountOwnerID: String?
    let accountStatus: ArticleSyncAccountStatus
    let lastErrorCode: String?
    let updatedAt: String
}

nonisolated struct ArticleCloudRecordState: Equatable, Sendable {
    let recordName: String
    let recordType: ArticleCloudRecordType
    let entityID: String
    let systemFields: Data
    let contentFingerprint: String
    let acknowledgedGeneration: Int64
    let accountOwnerID: String
    let updatedAt: String
}

nonisolated struct ArticleCloudSaveAcknowledgement: Equatable, Sendable {
    let recordName: String
    let generation: Int64
    let systemFields: Data
    let contentFingerprint: String
}

nonisolated struct ArticleCloudDeleteAcknowledgement: Equatable, Sendable {
    let recordName: String
    let generation: Int64
}

nonisolated struct ArticleFetchedCloudRecordReceipt: Equatable, Sendable {
    let recordName: String
    let recordType: ArticleCloudRecordType
    let entityID: String
    let systemFields: Data
    let contentFingerprint: String
}

nonisolated enum ArticleSyncFingerprint {
    static func anthology(_ manifest: ArticleCloudAnthologyManifest) throws -> String {
        var cloud = manifest
        cloud.anthology.coverPath = nil
        cloud.anthology.latestBuildRevision = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(cloud))
            .map { String(format: "%02x", $0) }
            .joined()
    }
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
        case missingAccountOwner
        case invalidGeneration
    }

    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    func saveEngineState(
        _ serialization: CKSyncEngine.State.Serialization,
        accountStatus: ArticleSyncAccountStatus? = nil,
        lastErrorCode: String? = nil,
        clearLastError: Bool = false,
        updatedAt: String
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(serialization)
        try db.write { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_status, last_error_code
                    FROM article_sync_state WHERE id = 'default'
                    """)
            let storedStatus: String? = row?["account_status"]
            let storedError: String? = row?["last_error_code"]
            let currentStatus =
                accountStatus?.rawValue
                ?? storedStatus
                ?? ArticleSyncAccountStatus.unknown.rawValue
            let currentError =
                clearLastError ? nil : (lastErrorCode ?? storedError)
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
                arguments: [data, currentStatus, currentError, updatedAt])
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
        clearLastError: Bool = false,
        updatedAt: String
    ) throws {
        try db.write { db in
            let storedError = try String.fetchOne(
                db,
                sql: "SELECT last_error_code FROM article_sync_state WHERE id = 'default'")
            let currentError =
                clearLastError ? nil : (lastErrorCode ?? storedError)
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
                arguments: [accountStatus.rawValue, currentError, updatedAt])
        }
    }

    func clearLastError(updatedAt: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article_sync_state (
                        id, engine_state, account_owner_id, account_status,
                        last_error_code, updated_at
                    )
                    VALUES ('default', NULL, NULL, ?, NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        last_error_code = NULL,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    ArticleSyncAccountStatus.unknown.rawValue,
                    updatedAt,
                ])
        }
    }

    /// Selects the active private-sync lane without deleting local workshop
    /// data or pending rows owned by another iCloud account.
    func bindAccountOwner(_ ownerID: String, updatedAt: String) throws {
        guard ownerID.isEmpty == false else { throw Error.missingAccountOwner }
        try db.write { db in
            let previous = try String.fetchOne(
                db,
                sql: "SELECT account_owner_id FROM article_sync_state WHERE id = 'default'")
            let switched = previous != nil && previous != ownerID
            try db.execute(
                sql: """
                    INSERT INTO article_sync_state (
                        id, engine_state, account_owner_id, account_status,
                        last_error_code, updated_at
                    )
                    VALUES ('default', NULL, ?, ?, NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        engine_state = CASE
                            WHEN account_owner_id IS NULL OR account_owner_id = excluded.account_owner_id
                            THEN engine_state
                            ELSE NULL
                        END,
                        account_owner_id = excluded.account_owner_id,
                        account_status = excluded.account_status,
                        last_error_code = CASE
                            WHEN account_owner_id IS NULL OR account_owner_id = excluded.account_owner_id
                            THEN last_error_code
                            ELSE NULL
                        END,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    ownerID,
                    switched
                        ? ArticleSyncAccountStatus.switchedAccount.rawValue
                        : ArticleSyncAccountStatus.available.rawValue,
                    updatedAt,
                ])

            // Changes created before an account was known become owned by the
            // first account only. Rows from a previous owner remain quarantined.
            if previous == nil {
                try db.execute(
                    sql: """
                        UPDATE article_sync_outbox
                        SET account_owner_id = ?
                        WHERE account_owner_id = ''
                        """,
                    arguments: [ownerID])
            }
        }
    }

    func unbindAccountOwner(
        status: ArticleSyncAccountStatus,
        updatedAt: String
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE article_sync_state
                    SET engine_state = NULL,
                        account_owner_id = NULL,
                        account_status = ?,
                        updated_at = ?
                    WHERE id = 'default'
                    """,
                arguments: [status.rawValue, updatedAt])
        }
    }

    func state() throws -> ArticleSyncStateSnapshot? {
        try db.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT engine_state, account_owner_id, account_status,
                               last_error_code, updated_at
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
                accountOwnerID: row["account_owner_id"],
                accountStatus: accountStatus,
                lastErrorCode: row["last_error_code"],
                updatedAt: row["updated_at"])
        }
    }

    func enqueue(_ change: ArticlePendingCloudChange) throws {
        _ = try enqueueReturning(change)
    }

    func enqueue(_ changes: [ArticlePendingCloudChange]) throws {
        guard changes.isEmpty == false else { return }
        for change in changes {
            _ = try enqueueReturning(change)
        }
    }

    @discardableResult
    func enqueueReturning(_ change: ArticlePendingCloudChange) throws
        -> ArticlePendingCloudChange
    {
        try db.write { db in
            let activeOwner =
                try change.accountOwnerID
                ?? String.fetchOne(
                    db,
                    sql: """
                        SELECT account_owner_id
                        FROM article_sync_state WHERE id = 'default'
                        """)
            let ownerKey = activeOwner ?? ""
            let previousGeneration =
                try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT generation FROM article_sync_outbox
                        WHERE record_name = ? AND account_owner_id = ?
                        """,
                    arguments: [change.recordName, ownerKey]) ?? 0
            let generation = max(previousGeneration + 1, change.generation)
            guard generation > 0 else { throw Error.invalidGeneration }
            try db.execute(
                sql: """
                    INSERT INTO article_sync_outbox (
                        record_name, record_type, entity_id, operation,
                        generation, account_owner_id, queued_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(record_name, account_owner_id) DO UPDATE SET
                        record_type = excluded.record_type,
                        entity_id = excluded.entity_id,
                        operation = excluded.operation,
                        generation = excluded.generation,
                        queued_at = excluded.queued_at
                    """,
                arguments: [
                    change.recordName,
                    change.recordType.rawValue,
                    change.entityID,
                    change.operation.rawValue,
                    generation,
                    ownerKey,
                    change.queuedAt,
                ])
            return ArticlePendingCloudChange(
                recordName: change.recordName,
                recordType: change.recordType,
                entityID: change.entityID,
                operation: change.operation,
                generation: generation,
                accountOwnerID: activeOwner,
                queuedAt: change.queuedAt)
        }
    }

    func pendingChanges(
        limit: Int? = nil,
        accountOwnerID explicitOwner: String? = nil
    ) throws -> [ArticlePendingCloudChange] {
        try db.read { db in
            let stateOwner = try String.fetchOne(
                db,
                sql: "SELECT account_owner_id FROM article_sync_state WHERE id = 'default'")
            let owner = explicitOwner ?? stateOwner
            let ownerKey = owner ?? ""
            let sql =
                """
                SELECT record_name, record_type, entity_id, operation,
                       generation, account_owner_id, queued_at
                FROM article_sync_outbox
                WHERE account_owner_id = ?
                ORDER BY queued_at, record_name
                """
                + (limit == nil ? "" : " LIMIT ?")
            var arguments: [any DatabaseValueConvertible] = [ownerKey]
            if let limit { arguments.append(limit) }
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments))
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
                    generation: row["generation"],
                    accountOwnerID: {
                        let stored: String = row["account_owner_id"]
                        return stored.isEmpty ? nil : stored
                    }(),
                    queuedAt: row["queued_at"])
            }
        }
    }

    func pendingChange(recordName: String) throws -> ArticlePendingCloudChange? {
        try pendingChanges().first { $0.recordName == recordName }
    }

    func acknowledgeSaved(_ acknowledgements: [ArticleCloudSaveAcknowledgement]) throws {
        guard acknowledgements.isEmpty == false else { return }
        try db.write { db in
            let owner = try requireActiveOwner(db)
            for acknowledgement in acknowledgements {
                let pending = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT record_type, entity_id, generation
                        FROM article_sync_outbox
                        WHERE record_name = ? AND account_owner_id = ?
                              AND operation = ?
                        """,
                    arguments: [
                        acknowledgement.recordName,
                        owner,
                        ArticleSyncOperation.save.rawValue,
                    ])
                let pendingGeneration: Int64? = pending?["generation"]

                // A stale success is useful only as a server base for a newer
                // local generation. It must never clear or overwrite that row.
                if let pendingGeneration,
                    pendingGeneration == acknowledgement.generation
                {
                    try upsertCloudRecord(
                        acknowledgement,
                        recordTypeRaw: pending?["record_type"],
                        entityID: pending?["entity_id"],
                        owner: owner,
                        db: db)
                    try db.execute(
                        sql: """
                            DELETE FROM article_sync_outbox
                            WHERE record_name = ? AND account_owner_id = ?
                                  AND operation = ? AND generation = ?
                            """,
                        arguments: [
                            acknowledgement.recordName,
                            owner,
                            ArticleSyncOperation.save.rawValue,
                            acknowledgement.generation,
                        ])
                } else if pendingGeneration != nil {
                    try upsertCloudRecord(
                        acknowledgement,
                        recordTypeRaw: pending?["record_type"],
                        entityID: pending?["entity_id"],
                        owner: owner,
                        db: db)
                }
            }
        }
    }

    func acknowledgeDeleted(_ acknowledgements: [ArticleCloudDeleteAcknowledgement]) throws {
        guard acknowledgements.isEmpty == false else { return }
        try db.write { db in
            let owner = try requireActiveOwner(db)
            for acknowledgement in acknowledgements {
                try db.execute(
                    sql: """
                        DELETE FROM article_sync_outbox
                        WHERE record_name = ? AND account_owner_id = ?
                              AND operation = ? AND generation = ?
                        """,
                    arguments: [
                        acknowledgement.recordName,
                        owner,
                        ArticleSyncOperation.delete.rawValue,
                        acknowledgement.generation,
                    ])
                if db.changesCount > 0 {
                    try db.execute(
                        sql: """
                            DELETE FROM article_sync_record
                            WHERE record_name = ? AND account_owner_id = ?
                            """,
                        arguments: [acknowledgement.recordName, owner])
                }
            }
        }
    }

    func storeFetchedCloudRecord(
        recordName: String,
        recordType: ArticleCloudRecordType,
        entityID: String,
        systemFields: Data,
        contentFingerprint: String,
        updatedAt: String
    ) throws {
        try db.write { db in
            let owner = try requireActiveOwner(db)
            try db.execute(
                sql: """
                    INSERT INTO article_sync_record (
                        record_name, record_type, entity_id, system_fields,
                        content_fingerprint, acknowledged_generation,
                        account_owner_id, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                    ON CONFLICT(record_name, account_owner_id) DO UPDATE SET
                        record_type = excluded.record_type,
                        entity_id = excluded.entity_id,
                        system_fields = excluded.system_fields,
                        content_fingerprint = excluded.content_fingerprint,
                        acknowledged_generation = article_sync_record.acknowledged_generation,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    recordName,
                    recordType.rawValue,
                    entityID,
                    systemFields,
                    contentFingerprint,
                    owner,
                    updatedAt,
                ])
        }
    }

    func cloudRecord(recordName: String) throws -> ArticleCloudRecordState? {
        try db.read { db in
            guard
                let owner = try String.fetchOne(
                    db,
                    sql: """
                        SELECT account_owner_id FROM article_sync_state
                        WHERE id = 'default'
                        """),
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT record_name, record_type, entity_id, system_fields,
                        content_fingerprint, acknowledged_generation,
                        account_owner_id, updated_at
                        FROM article_sync_record
                        WHERE record_name = ? AND account_owner_id = ?
                        """,
                    arguments: [recordName, owner])
            else {
                return nil
            }
            return try cloudRecord(from: row)
        }
    }

    func allCloudRecords() throws -> [ArticleCloudRecordState] {
        try db.read { db in
            guard
                let owner = try String.fetchOne(
                    db,
                    sql: """
                        SELECT account_owner_id FROM article_sync_state
                        WHERE id = 'default'
                        """)
            else {
                return []
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT record_name, record_type, entity_id, system_fields,
                           content_fingerprint, acknowledged_generation,
                           account_owner_id, updated_at
                    FROM article_sync_record
                    WHERE account_owner_id = ?
                    ORDER BY record_name
                    """,
                arguments: [owner]
            ).map { try cloudRecord(from: $0) }
        }
    }

    /// Rebuilds the active account's private zone from its durable desired
    /// state. Prior-account receipts and all local workshop rows remain
    /// quarantined from this account's recovery.
    func recoverMissingZone(updatedAt: String) throws -> [ArticlePendingCloudChange] {
        try db.write { db in
            let owner = try requireActiveOwner(db)
            var identities:
                [String: (
                    recordType: ArticleCloudRecordType,
                    entityID: String,
                    baseGeneration: Int64
                )] = [:]
            let acknowledged = try Row.fetchAll(
                db,
                sql: """
                    SELECT record_name, record_type, entity_id, acknowledged_generation
                    FROM article_sync_record
                    WHERE account_owner_id = ?
                    """,
                arguments: [owner])
            for row in acknowledged {
                let rawType: String = row["record_type"]
                guard let recordType = ArticleCloudRecordType(rawValue: rawType) else {
                    throw Error.invalidRecordType(rawType)
                }
                let recordName: String = row["record_name"]
                identities[recordName] = (
                    recordType: recordType,
                    entityID: row["entity_id"],
                    baseGeneration: row["acknowledged_generation"]
                )
            }

            let pending = try Row.fetchAll(
                db,
                sql: """
                    SELECT record_name, record_type, entity_id, operation, generation
                    FROM article_sync_outbox
                    WHERE account_owner_id = ?
                    """,
                arguments: [owner])
            for row in pending {
                let recordName: String = row["record_name"]
                let rawOperation: String = row["operation"]
                guard let operation = ArticleSyncOperation(rawValue: rawOperation) else {
                    throw Error.invalidOperation(rawOperation)
                }
                switch operation {
                case .delete:
                    // The absent zone already satisfies this desired state.
                    identities.removeValue(forKey: recordName)
                case .save:
                    let rawType: String = row["record_type"]
                    guard let recordType = ArticleCloudRecordType(rawValue: rawType) else {
                        throw Error.invalidRecordType(rawType)
                    }
                    let generation: Int64 = row["generation"]
                    let acknowledgedGeneration =
                        identities[recordName]?.baseGeneration ?? 0
                    identities[recordName] = (
                        recordType: recordType,
                        entityID: row["entity_id"],
                        baseGeneration: max(generation, acknowledgedGeneration)
                    )
                }
            }

            try db.execute(
                sql: "DELETE FROM article_sync_record WHERE account_owner_id = ?",
                arguments: [owner])
            try db.execute(
                sql: "DELETE FROM article_sync_outbox WHERE account_owner_id = ?",
                arguments: [owner])

            var result: [ArticlePendingCloudChange] = []
            for recordName in identities.keys.sorted() {
                guard let identity = identities[recordName] else { continue }
                let generation = identity.baseGeneration + 1
                try db.execute(
                    sql: """
                        INSERT INTO article_sync_outbox (
                            record_name, record_type, entity_id, operation,
                            generation, account_owner_id, queued_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(record_name, account_owner_id) DO UPDATE SET
                            record_type = excluded.record_type,
                            entity_id = excluded.entity_id,
                            operation = excluded.operation,
                            generation = excluded.generation,
                            queued_at = excluded.queued_at
                        """,
                    arguments: [
                        recordName,
                        identity.recordType.rawValue,
                        identity.entityID,
                        ArticleSyncOperation.save.rawValue,
                        generation,
                        owner,
                        updatedAt,
                    ])
                result.append(
                    ArticlePendingCloudChange(
                        recordName: recordName,
                        recordType: identity.recordType,
                        entityID: identity.entityID,
                        operation: .save,
                        generation: generation,
                        accountOwnerID: owner,
                        queuedAt: updatedAt))
            }
            return result
        }
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
    func applyFetchedChanges(
        _ changes: [ArticleFetchedDatabaseChange],
        cloudRecords: [ArticleFetchedCloudRecordReceipt] = [],
        deletedRecordNames: [String] = []
    ) throws {
        guard
            changes.isEmpty == false
                || cloudRecords.isEmpty == false
                || deletedRecordNames.isEmpty == false
        else { return }
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

            if cloudRecords.isEmpty == false || deletedRecordNames.isEmpty == false {
                let owner = try requireActiveOwner(db)
                for receipt in cloudRecords {
                    try db.execute(
                        sql: """
                            INSERT INTO article_sync_record (
                                record_name, record_type, entity_id, system_fields,
                                content_fingerprint, acknowledged_generation,
                                account_owner_id, updated_at
                            )
                            VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                            ON CONFLICT(record_name, account_owner_id) DO UPDATE SET
                                record_type = excluded.record_type,
                                entity_id = excluded.entity_id,
                                system_fields = excluded.system_fields,
                                content_fingerprint = excluded.content_fingerprint,
                                acknowledged_generation =
                                    article_sync_record.acknowledged_generation,
                                updated_at = excluded.updated_at
                            """,
                        arguments: [
                            receipt.recordName,
                            receipt.recordType.rawValue,
                            receipt.entityID,
                            receipt.systemFields,
                            receipt.contentFingerprint,
                            owner,
                            Date().ISO8601Format(),
                        ])
                }
                for recordName in deletedRecordNames {
                    try db.execute(
                        sql: """
                            DELETE FROM article_sync_record
                            WHERE record_name = ? AND account_owner_id = ?
                            """,
                        arguments: [recordName, owner])
                }
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
        let existingComparable = cloudComparable(existing)
        let incomingComparable = cloudComparable(incoming)
        if existingComparable == incomingComparable {
            return
        }

        let owner =
            try String.fetchOne(
                db,
                sql: "SELECT account_owner_id FROM article_sync_state WHERE id = 'default'")
            ?? ""
        let recordName =
            "\(ArticleCloudRecordType.anthology.recordNamePrefix).\(incoming.anthology.id)"
        let hasPendingLocalChange =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM article_sync_outbox
                        WHERE record_name = ? AND account_owner_id = ?
                              AND operation = ?
                    )
                    """,
                arguments: [
                    recordName,
                    owner,
                    ArticleSyncOperation.save.rawValue,
                ]) ?? false
        let baseFingerprint = try String.fetchOne(
            db,
            sql: """
                SELECT content_fingerprint FROM article_sync_record
                WHERE record_name = ? AND account_owner_id = ?
                """,
            arguments: [recordName, owner])
        let existingFingerprint = try ArticleSyncFingerprint.anthology(existingComparable)
        let incomingFingerprint = try ArticleSyncFingerprint.anthology(incomingComparable)
        let localDiverged =
            hasPendingLocalChange
            && (baseFingerprint == nil || existingFingerprint != baseFingerprint)

        if localDiverged == false || existingFingerprint == incomingFingerprint {
            try replaceAnthologyAuthoringState(
                incoming,
                preserving: existingAnthology,
                db: db)
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
        let recoveredRecordName =
            "\(ArticleCloudRecordType.anthology.recordNamePrefix).\(recoveredID.uuidString)"
        try db.execute(
            sql: """
                INSERT INTO article_sync_outbox (
                    record_name, record_type, entity_id, operation,
                    generation, account_owner_id, queued_at
                )
                VALUES (?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(record_name, account_owner_id) DO NOTHING
                """,
            arguments: [
                recoveredRecordName,
                ArticleCloudRecordType.anthology.rawValue,
                recoveredID.uuidString,
                ArticleSyncOperation.save.rawValue,
                owner,
                incoming.anthology.modifiedAt,
            ])
    }

    private func replaceAnthologyAuthoringState(
        _ incoming: ArticleCloudAnthologyManifest,
        preserving local: AnthologyRecord,
        db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM anthology_entry WHERE anthology_id = ?",
            arguments: [incoming.anthology.id])
        try db.execute(
            sql: """
                UPDATE anthology
                SET title = ?, subtitle = ?, creator = ?,
                    next_stable_slot = ?, created_at = ?, modified_at = ?
                WHERE id = ?
                """,
            arguments: [
                incoming.anthology.title,
                incoming.anthology.subtitle,
                incoming.anthology.creator,
                incoming.anthology.nextStableSlot,
                incoming.anthology.createdAt,
                incoming.anthology.modifiedAt,
                incoming.anthology.id,
            ])
        for entry in incoming.entries {
            var entry = entry
            try entry.insert(db)
        }
        // `cover_path` and `latest_build_revision` are intentionally omitted:
        // they describe products owned by this device, not cloud authoring state.
        _ = local
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
        let owner =
            try String.fetchOne(
                db,
                sql: "SELECT account_owner_id FROM article_sync_state WHERE id = 'default'")
            ?? ""
        let hasPendingLocalChange =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM article_sync_outbox
                        WHERE record_name = ? AND account_owner_id = ?
                    )
                    """,
                arguments: [recordName, owner]) ?? false
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

    private func requireActiveOwner(_ db: Database) throws -> String {
        guard
            let owner = try String.fetchOne(
                db,
                sql: """
                    SELECT account_owner_id FROM article_sync_state
                    WHERE id = 'default'
                    """),
            owner.isEmpty == false
        else {
            throw Error.missingAccountOwner
        }
        return owner
    }

    private func cloudRecord(from row: Row) throws -> ArticleCloudRecordState {
        let rawType: String = row["record_type"]
        guard let recordType = ArticleCloudRecordType(rawValue: rawType) else {
            throw Error.invalidRecordType(rawType)
        }
        return ArticleCloudRecordState(
            recordName: row["record_name"],
            recordType: recordType,
            entityID: row["entity_id"],
            systemFields: row["system_fields"],
            contentFingerprint: row["content_fingerprint"],
            acknowledgedGeneration: row["acknowledged_generation"],
            accountOwnerID: row["account_owner_id"],
            updatedAt: row["updated_at"])
    }

    private func upsertCloudRecord(
        _ acknowledgement: ArticleCloudSaveAcknowledgement,
        recordTypeRaw: String?,
        entityID: String?,
        owner: String,
        db: Database
    ) throws {
        guard let recordTypeRaw,
            ArticleCloudRecordType(rawValue: recordTypeRaw) != nil,
            let entityID
        else {
            throw Error.invalidRecordType(recordTypeRaw ?? "")
        }
        try db.execute(
            sql: """
                INSERT INTO article_sync_record (
                    record_name, record_type, entity_id, system_fields,
                    content_fingerprint, acknowledged_generation,
                    account_owner_id, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(record_name, account_owner_id) DO UPDATE SET
                    record_type = CASE
                        WHEN excluded.acknowledged_generation >= article_sync_record.acknowledged_generation
                        THEN excluded.record_type ELSE article_sync_record.record_type
                    END,
                    entity_id = CASE
                        WHEN excluded.acknowledged_generation >= article_sync_record.acknowledged_generation
                        THEN excluded.entity_id ELSE article_sync_record.entity_id
                    END,
                    system_fields = CASE
                        WHEN excluded.acknowledged_generation >= article_sync_record.acknowledged_generation
                        THEN excluded.system_fields ELSE article_sync_record.system_fields
                    END,
                    content_fingerprint = CASE
                        WHEN excluded.acknowledged_generation >= article_sync_record.acknowledged_generation
                        THEN excluded.content_fingerprint
                        ELSE article_sync_record.content_fingerprint
                    END,
                    acknowledged_generation = MAX(
                        article_sync_record.acknowledged_generation,
                        excluded.acknowledged_generation
                    ),
                    updated_at = CASE
                        WHEN excluded.acknowledged_generation >= article_sync_record.acknowledged_generation
                        THEN excluded.updated_at ELSE article_sync_record.updated_at
                    END
                """,
            arguments: [
                acknowledgement.recordName,
                recordTypeRaw,
                entityID,
                acknowledgement.systemFields,
                acknowledgement.contentFingerprint,
                acknowledgement.generation,
                owner,
                Date().ISO8601Format(),
            ])
    }
}
