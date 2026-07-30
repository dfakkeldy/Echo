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

nonisolated enum ArticleSyncAccountBindingResult: Equatable, Sendable {
    case available
    case quarantined
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
        let manifestJSON = String(
            decoding: try encoder.encode(cloud),
            as: UTF8.self)
        var scalarFields = [
            "entityID\u{0}\(cloud.anthology.id)",
            "manifestJSON\u{0}\(manifestJSON)",
        ]
        if let coverContentVersion = cloud.coverContentVersion {
            scalarFields.append("coverContentVersion\u{0}\(coverContentVersion)")
        }
        scalarFields.sort()
        return SHA256.hash(
            data: Data(scalarFields.joined(separator: "\u{1}").utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }
}

nonisolated struct ArticleCloudAnthologyManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var anthology: AnthologyRecord
    var entries: [AnthologyEntryRecord]
    /// Canonical Cloud identity for the optional cover asset. This sideband is
    /// deliberately omitted from manifest JSON and never stores a device path.
    var coverContentVersion: String?

    init(
        schemaVersion: Int,
        anthology: AnthologyRecord,
        entries: [AnthologyEntryRecord],
        coverContentVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.anthology = anthology
        self.entries = entries
        self.coverContentVersion = coverContentVersion
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
        coverContentVersion = nil
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

nonisolated struct ArticleFetchedAnthologyDisposition: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case insert
        case keepLocal
        case replace
        case recover
    }

    let action: Action
    let sourceAnthologyID: String
    let targetAnthologyID: String
    let stateToken: String
}

nonisolated enum ArticleFetchedDatabaseChange: Equatable, Sendable {
    case capture(ArticleCaptureRecord)
    case revision(ArticleRevisionRecord)
    case anthology(
        ArticleCloudAnthologyManifest,
        disposition: ArticleFetchedAnthologyDisposition? = nil)
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
                incoming.coverContentVersion ?? "<no-cover>",
                existing.coverContentVersion ?? "<no-cover>",
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
        case accountOwnerMismatch
        case recordIdentityMismatch
        case invalidGeneration
        case accountOwnerQuarantined
        case anthologyStateChanged
        case remoteModificationTombstoned
        case revisionIdentityCollision(String)
        case revisionHasDescendants(String)
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
                    SELECT account_owner_id, account_status, last_error_code
                    FROM article_sync_state WHERE id = 'default'
                    """)
            let owner: String? = row?["account_owner_id"]
            let storedStatus: String? = row?["account_status"]
            let storedError: String? = row?["last_error_code"]
            let quarantined =
                try owner.map { try accountOwnerIsQuarantined($0, db: db) } ?? false
            let currentStatus =
                quarantined
                ? ArticleSyncAccountStatus.restricted.rawValue
                : accountStatus?.rawValue
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
                arguments: [
                    quarantined ? nil : data,
                    currentStatus,
                    currentError,
                    updatedAt,
                ])
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
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_owner_id, last_error_code
                    FROM article_sync_state WHERE id = 'default'
                    """)
            let owner: String? = row?["account_owner_id"]
            let storedError: String? = row?["last_error_code"]
            let quarantined =
                try owner.map { try accountOwnerIsQuarantined($0, db: db) } ?? false
            let currentStatus =
                quarantined ? ArticleSyncAccountStatus.restricted : accountStatus
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
                arguments: [currentStatus.rawValue, currentError, updatedAt])
        }
    }

    func activeAccountOwnerIsQuarantined() throws -> Bool {
        try db.read { db in
            guard
                let owner = try String.fetchOne(
                    db,
                    sql: """
                        SELECT account_owner_id FROM article_sync_state
                        WHERE id = 'default'
                        """)
            else {
                return false
            }
            return try accountOwnerIsQuarantined(owner, db: db)
        }
    }

    func activeAccountLaneIsRestricted() throws -> Bool {
        try db.read { try activeAccountLaneIsRestricted($0) }
    }

    func requireActiveAccountLaneAllowsCloudIO() throws {
        if try activeAccountLaneIsRestricted() {
            throw Error.accountOwnerQuarantined
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
    @discardableResult
    func bindAccountOwner(
        _ ownerID: String,
        updatedAt: String
    ) throws -> ArticleSyncAccountBindingResult {
        guard ownerID.isEmpty == false else { throw Error.missingAccountOwner }
        return try db.write { db in
            let previous = try String.fetchOne(
                db,
                sql: "SELECT account_owner_id FROM article_sync_state WHERE id = 'default'")
            let switched = previous != nil && previous != ownerID
            if switched, let previous {
                try guardOwnerWithPendingSave(
                    previous,
                    reason: "accountSwitchWithPendingSave",
                    updatedAt: updatedAt,
                    db: db)
            }
            let quarantined =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM article_sync_account_guard
                            WHERE account_owner_id = ?
                        )
                        """,
                    arguments: [ownerID]) ?? false
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
                    quarantined
                        ? ArticleSyncAccountStatus.restricted.rawValue
                        : switched
                            ? ArticleSyncAccountStatus.switchedAccount.rawValue
                            : ArticleSyncAccountStatus.available.rawValue,
                    updatedAt,
                ])

            if quarantined == false {
                try adoptOwnerlessChanges(for: ownerID, db: db)
            }
            return quarantined ? .quarantined : .available
        }
    }

    func quarantineActiveAccountOwner(
        reason: String,
        updatedAt: String
    ) throws {
        guard reason.isEmpty == false else { throw Error.accountOwnerQuarantined }
        try db.write { db in
            let owner = try requireActiveOwner(db)
            try db.execute(
                sql: """
                    INSERT INTO article_sync_account_guard (
                        account_owner_id, reason, updated_at
                    )
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_owner_id) DO UPDATE SET
                        reason = excluded.reason,
                        updated_at = excluded.updated_at
                    """,
                arguments: [owner, reason, updatedAt])
            try db.execute(
                sql: """
                    UPDATE article_sync_state
                    SET engine_state = NULL,
                        account_status = ?,
                        updated_at = ?
                    WHERE id = 'default' AND account_owner_id = ?
                    """,
                arguments: [
                    ArticleSyncAccountStatus.restricted.rawValue,
                    updatedAt,
                    owner,
                ])
        }
    }

    func unbindAccountOwner(
        status: ArticleSyncAccountStatus,
        updatedAt: String
    ) throws {
        try db.write { db in
            if let owner = try String.fetchOne(
                db,
                sql: """
                    SELECT account_owner_id FROM article_sync_state
                    WHERE id = 'default'
                    """)
            {
                try guardOwnerWithPendingSave(
                    owner,
                    reason: "accountSignOutWithPendingSave",
                    updatedAt: updatedAt,
                    db: db)
            }
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
        guard
            change.recordName
                == "\(change.recordType.recordNamePrefix).\(change.entityID)"
        else {
            throw Error.recordIdentityMismatch
        }
        return try db.write { db in
            let boundOwner = try String.fetchOne(
                db,
                sql: """
                    SELECT account_owner_id
                    FROM article_sync_state WHERE id = 'default'
                    """)
            if let explicitOwner = change.accountOwnerID,
                explicitOwner != boundOwner
            {
                throw Error.accountOwnerMismatch
            }
            let activeOwner = change.accountOwnerID ?? boundOwner
            let ownerKey = activeOwner ?? ""
            if change.operation == .save, let activeOwner {
                let historicalOwners = try syncIdentityOwners(
                    recordName: change.recordName,
                    db: db)
                guard historicalOwners.isEmpty
                    || historicalOwners == Set([activeOwner])
                else {
                    throw Error.accountOwnerMismatch
                }
            }
            let previousGeneration =
                try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT generation FROM article_sync_outbox
                        WHERE record_name = ? AND account_owner_id = ?
                        """,
                    arguments: [change.recordName, ownerKey]) ?? 0
            let acknowledgedGeneration =
                try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT acknowledged_generation FROM article_sync_record
                        WHERE record_name = ? AND account_owner_id = ?
                        """,
                    arguments: [change.recordName, ownerKey]) ?? 0
            let durableGeneration = max(previousGeneration, acknowledgedGeneration)
            guard durableGeneration < Int64.max else {
                throw Error.invalidGeneration
            }
            let generation = max(durableGeneration + 1, change.generation)
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
            let state = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_owner_id, account_status
                    FROM article_sync_state WHERE id = 'default'
                    """)
            let stateOwner: String? = state?["account_owner_id"]
            let rawStatus: String? = state?["account_status"]
            let quarantined =
                try stateOwner.map { try accountOwnerIsQuarantined($0, db: db) } ?? false
            if explicitOwner == nil,
                quarantined
                    || rawStatus == ArticleSyncAccountStatus.restricted.rawValue
            {
                return []
            }
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

    func hasActivePendingDelete(
        recordType: ArticleCloudRecordType,
        entityID: String
    ) throws -> Bool {
        try db.read {
            try hasActivePendingDelete(
                recordType: recordType,
                entityID: entityID,
                db: $0)
        }
    }

    func acknowledgeSaved(_ acknowledgements: [ArticleCloudSaveAcknowledgement]) throws {
        guard acknowledgements.isEmpty == false else { return }
        try db.write { db in
            let owner = try requireActiveOwner(db)
            try acknowledgeSaved(acknowledgements, owner: owner, db: db)
        }
    }

    func acknowledgeDeleted(_ acknowledgements: [ArticleCloudDeleteAcknowledgement]) throws {
        guard acknowledgements.isEmpty == false else { return }
        try db.write { db in
            let owner = try requireActiveOwner(db)
            try acknowledgeDeleted(acknowledgements, owner: owner, db: db)
        }
    }

    func acknowledgeSent(
        saved: [ArticleCloudSaveAcknowledgement],
        deleted: [ArticleCloudDeleteAcknowledgement]
    ) throws {
        guard saved.isEmpty == false || deleted.isEmpty == false else { return }
        try db.write { db in
            let owner = try requireActiveOwner(db)
            try acknowledgeSaved(saved, owner: owner, db: db)
            try acknowledgeDeleted(deleted, owner: owner, db: db)
        }
    }

    private func acknowledgeSaved(
        _ acknowledgements: [ArticleCloudSaveAcknowledgement],
        owner: String,
        db: Database
    ) throws {
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

    private func acknowledgeDeleted(
        _ acknowledgements: [ArticleCloudDeleteAcknowledgement],
        owner: String,
        db: Database
    ) throws {
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
            let quarantined =
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM article_sync_account_guard
                            WHERE account_owner_id = ?
                        )
                        """,
                    arguments: [owner]) ?? false
            guard quarantined == false else {
                throw Error.accountOwnerQuarantined
            }
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
        try db.read { try anthologyManifest(id: id, db: $0) }
    }

    func anthologyDisposition(
        for incoming: ArticleCloudAnthologyManifest
    ) throws -> ArticleFetchedAnthologyDisposition {
        try db.read { try anthologyDisposition(for: incoming, db: $0) }
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
            guard try activeAccountLaneIsRestricted(db) == false else {
                throw Error.accountOwnerQuarantined
            }
            for change in changes {
                let identity: (ArticleCloudRecordType, String)?
                switch change {
                case .capture(let capture):
                    identity = (.capture, capture.id)
                case .revision(let revision):
                    identity = (.revision, revision.id)
                case .anthology(let manifest, _):
                    identity = (.anthology, manifest.anthology.id)
                case .delete:
                    identity = nil
                }
                if let identity,
                    try hasActivePendingDelete(
                        recordType: identity.0,
                        entityID: identity.1,
                        db: db)
                {
                    throw Error.remoteModificationTombstoned
                }
            }
            for receipt in cloudRecords {
                if try hasActivePendingDelete(
                    recordType: receipt.recordType,
                    entityID: receipt.entityID,
                    db: db)
                {
                    throw Error.remoteModificationTombstoned
                }
            }
            for change in changes {
                guard case .capture(var capture) = change else { continue }
                guard try ArticleCaptureRecord.fetchOne(db, key: capture.id) == nil else {
                    continue
                }
                try capture.insert(db)
            }

            for change in changes {
                guard case .revision(var revision) = change else { continue }
                if let existing = try ArticleRevisionRecord.fetchOne(db, key: revision.id) {
                    guard existing == revision else {
                        throw Error.revisionIdentityCollision(revision.id)
                    }
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
                guard case .anthology(let manifest, let disposition) = change else {
                    continue
                }
                try applyFetchedAnthology(
                    manifest,
                    expectedDisposition: disposition,
                    db: db)
            }

            for change in changes {
                guard case .delete(.anthology, let entityID) = change else {
                    continue
                }
                try applyFetchedDeletion(
                    recordType: .anthology,
                    entityID: entityID,
                    db: db)
            }
            try applyFetchedRevisionDeletions(changes, db: db)
            for change in changes {
                guard case .delete(.capture, let entityID) = change else {
                    continue
                }
                try applyFetchedDeletion(
                    recordType: .capture,
                    entityID: entityID,
                    db: db)
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

    private func anthologyDisposition(
        for incoming: ArticleCloudAnthologyManifest,
        db: Database
    ) throws -> ArticleFetchedAnthologyDisposition {
        guard let sourceID = UUID(uuidString: incoming.anthology.id),
            sourceID.uuidString == incoming.anthology.id
        else {
            throw Error.anthologyStateChanged
        }
        let state = try Row.fetchOne(
            db,
            sql: """
                SELECT account_owner_id, account_status
                FROM article_sync_state WHERE id = 'default'
                """)
        let owner: String = state?["account_owner_id"] ?? ""
        let status: String = state?["account_status"] ?? ""
        let recordName =
            "\(ArticleCloudRecordType.anthology.recordNamePrefix).\(sourceID.uuidString)"
        let pending = try Row.fetchOne(
            db,
            sql: """
                SELECT record_type, entity_id, operation, generation, queued_at
                FROM article_sync_outbox
                WHERE record_name = ? AND account_owner_id = ?
                """,
            arguments: [recordName, owner])
        if let pending {
            let rawType: String = pending["record_type"]
            let pendingEntityID: String = pending["entity_id"]
            let rawOperation: String = pending["operation"]
            guard rawType == ArticleCloudRecordType.anthology.rawValue,
                pendingEntityID == sourceID.uuidString,
                ArticleSyncOperation(rawValue: rawOperation) != nil
            else {
                throw Error.anthologyStateChanged
            }
        }
        let baseFingerprint = try String.fetchOne(
            db,
            sql: """
                SELECT content_fingerprint FROM article_sync_record
                WHERE record_name = ? AND account_owner_id = ?
                """,
            arguments: [recordName, owner])
        let existing = try anthologyManifest(id: sourceID.uuidString, db: db)

        let action: ArticleFetchedAnthologyDisposition.Action
        let targetID: String
        if let existing {
            let existingFingerprint = try ArticleSyncFingerprint.anthology(existing)
            let incomingFingerprint = try ArticleSyncFingerprint.anthology(incoming)
            let pendingOperation: String? = pending?["operation"]
            let hasPendingSave =
                pendingOperation == ArticleSyncOperation.save.rawValue
            let localDiverged =
                hasPendingSave
                && (baseFingerprint == nil || existingFingerprint != baseFingerprint)
            let remoteDiverged =
                baseFingerprint.map { incomingFingerprint != $0 }
            if localDiverged && remoteDiverged == false {
                action = .keepLocal
                targetID = sourceID.uuidString
            } else if existingFingerprint != incomingFingerprint
                && (baseFingerprint == nil
                    || (localDiverged && remoteDiverged == true))
            {
                action = .recover
                targetID =
                    ArticleSyncConflictIdentity.recoveredAnthologyID(
                        incoming: incoming,
                        existing: existing
                    ).uuidString
            } else {
                action = .replace
                targetID = sourceID.uuidString
            }
        } else {
            action = .insert
            targetID = sourceID.uuidString
        }

        let target = try anthologyManifest(id: targetID, db: db)
        let token = anthologyStateToken(
            owner: owner,
            status: status,
            source: existing,
            target: target,
            pending: pending,
            baseFingerprint: baseFingerprint)
        return ArticleFetchedAnthologyDisposition(
            action: action,
            sourceAnthologyID: sourceID.uuidString,
            targetAnthologyID: targetID,
            stateToken: token)
    }

    private func applyFetchedAnthology(
        _ incoming: ArticleCloudAnthologyManifest,
        expectedDisposition: ArticleFetchedAnthologyDisposition?,
        db: Database
    ) throws {
        let currentDisposition = try anthologyDisposition(for: incoming, db: db)
        if let expectedDisposition,
            expectedDisposition != currentDisposition
        {
            throw Error.anthologyStateChanged
        }
        let disposition = expectedDisposition ?? currentDisposition
        switch disposition.action {
        case .insert:
            guard
                try AnthologyRecord.fetchOne(
                    db,
                    key: disposition.sourceAnthologyID) == nil
            else {
                throw Error.anthologyStateChanged
            }
            try insertAnthologyManifest(incoming, db: db)
        case .replace:
            guard
                try AnthologyRecord.fetchOne(
                    db,
                    key: disposition.sourceAnthologyID) != nil
            else {
                throw Error.anthologyStateChanged
            }
            try replaceAnthologyAuthoringState(
                incoming,
                db: db)
        case .keepLocal:
            break
        case .recover:
            try applyRecoveredAnthology(
                incoming,
                disposition: disposition,
                db: db)
        }
    }

    private func applyRecoveredAnthology(
        _ incoming: ArticleCloudAnthologyManifest,
        disposition: ArticleFetchedAnthologyDisposition,
        db: Database
    ) throws {
        guard let recoveredID = UUID(uuidString: disposition.targetAnthologyID),
            recoveredID.uuidString == disposition.targetAnthologyID
        else {
            throw Error.anthologyStateChanged
        }
        let owner =
            try String.fetchOne(
                db,
                sql: "SELECT account_owner_id FROM article_sync_state WHERE id = 'default'")
            ?? ""
        if try AnthologyRecord.fetchOne(db, key: recoveredID.uuidString) != nil {
            try db.execute(
                sql: """
                    UPDATE anthology
                    SET cover_path = ?
                    WHERE id = ?
                    """,
                arguments: [
                    incoming.anthology.coverPath,
                    recoveredID.uuidString,
                ])
        } else {
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
                    entries: recoveredEntries,
                    coverContentVersion: incoming.coverContentVersion),
                db: db)
        }
        try enqueueRecoveredAnthology(
            id: recoveredID.uuidString,
            owner: owner,
            queuedAt: incoming.anthology.modifiedAt,
            db: db)
    }

    private func replaceAnthologyAuthoringState(
        _ incoming: ArticleCloudAnthologyManifest,
        db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM anthology_entry WHERE anthology_id = ?",
            arguments: [incoming.anthology.id])
        try db.execute(
            sql: """
                UPDATE anthology
                SET title = ?, subtitle = ?, creator = ?,
                    cover_path = ?, next_stable_slot = ?,
                    created_at = ?, modified_at = ?
                WHERE id = ?
                """,
            arguments: [
                incoming.anthology.title,
                incoming.anthology.subtitle,
                incoming.anthology.creator,
                incoming.anthology.coverPath,
                incoming.anthology.nextStableSlot,
                incoming.anthology.createdAt,
                incoming.anthology.modifiedAt,
                incoming.anthology.id,
            ])
        for entry in incoming.entries {
            var entry = entry
            try entry.insert(db)
        }
        // The optional cover asset is synced authoring state. Its managed path
        // is device-local, while `latest_build_revision` remains local-only.
    }

    private func anthologyManifest(
        id: String,
        db: Database
    ) throws -> ArticleCloudAnthologyManifest? {
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
            entries: entries,
            coverContentVersion: coverContentVersion(from: anthology.coverPath))
    }

    private func anthologyStateToken(
        owner: String,
        status: String,
        source: ArticleCloudAnthologyManifest?,
        target: ArticleCloudAnthologyManifest?,
        pending: Row?,
        baseFingerprint: String?
    ) -> String {
        var values = [
            owner,
            status,
            baseFingerprint ?? "<none>",
            source.map(anthologyState) ?? "<missing-source>",
            target.map(anthologyState) ?? "<missing-target>",
        ]
        if let pending {
            let recordType: String = pending["record_type"]
            let entityID: String = pending["entity_id"]
            let operation: String = pending["operation"]
            let generation: Int64 = pending["generation"]
            let queuedAt: String = pending["queued_at"]
            values += [
                recordType,
                entityID,
                operation,
                String(generation),
                queuedAt,
            ]
        } else {
            values.append("<no-pending-change>")
        }
        let framed = values.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func anthologyState(
        _ manifest: ArticleCloudAnthologyManifest
    ) -> String {
        let anthology = manifest.anthology
        var values = [
            String(manifest.schemaVersion),
            anthology.id,
            anthology.title,
            anthology.subtitle ?? "<nil>",
            anthology.creator ?? "<nil>",
            anthology.coverPath ?? "<nil>",
            manifest.coverContentVersion ?? "<no-cover>",
            String(anthology.nextStableSlot),
            String(anthology.latestBuildRevision),
            anthology.createdAt,
            anthology.modifiedAt,
        ]
        for entry in manifest.entries.sorted(by: {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            if $0.stableSlot != $1.stableSlot {
                return $0.stableSlot < $1.stableSlot
            }
            return $0.id < $1.id
        }) {
            values += [
                entry.id,
                entry.anthologyID,
                entry.captureID,
                String(entry.sortOrder),
                String(entry.stableSlot),
                entry.chapterTitleOverride ?? "<nil>",
                entry.narrationVoiceID ?? "<nil>",
            ]
        }
        return values.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func coverContentVersion(from coverPath: String?) -> String? {
        guard let coverPath,
            coverPath == URL(fileURLWithPath: coverPath).lastPathComponent
        else {
            return nil
        }
        let components = coverPath.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
            ["jpg", "jpeg", "png"].contains(String(components[1])),
            components[0].hasPrefix("cover-")
        else {
            return nil
        }
        let digest = components[0].dropFirst("cover-".count)
        guard digest.count == 64,
            digest.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            return nil
        }
        return "sha256:\(digest)"
    }

    private func enqueueRecoveredAnthology(
        id: String,
        owner: String,
        queuedAt: String,
        db: Database
    ) throws {
        let recordName =
            "\(ArticleCloudRecordType.anthology.recordNamePrefix).\(id)"
        let outboxGeneration =
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT generation FROM article_sync_outbox
                    WHERE record_name = ? AND account_owner_id = ?
                    """,
                arguments: [recordName, owner]) ?? 0
        let acknowledgedGeneration =
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT acknowledged_generation FROM article_sync_record
                    WHERE record_name = ? AND account_owner_id = ?
                    """,
                arguments: [recordName, owner]) ?? 0
        let durableGeneration = max(outboxGeneration, acknowledgedGeneration)
        guard durableGeneration < Int64.max else {
            throw Error.invalidGeneration
        }
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
                ArticleCloudRecordType.anthology.rawValue,
                id,
                ArticleSyncOperation.save.rawValue,
                durableGeneration + 1,
                owner,
                queuedAt,
            ])
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
                let hasRetainedChild =
                    try Bool.fetchOne(
                        db,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1 FROM article_revision
                                WHERE parent_revision_id = ?
                            )
                            """,
                        arguments: [entityID]) ?? false
                guard hasRetainedChild == false else {
                    throw Error.revisionHasDescendants(entityID)
                }
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

    private func applyFetchedRevisionDeletions(
        _ changes: [ArticleFetchedDatabaseChange],
        db: Database
    ) throws {
        var remaining = Set(
            changes.compactMap { change -> String? in
                guard case .delete(let type, let entityID) = change,
                    type == .revision
                else {
                    return nil
                }
                return entityID
            })
        guard remaining.isEmpty == false else { return }
        let revisions = try ArticleRevisionRecord.fetchAll(db)
        while remaining.isEmpty == false {
            let leaves = remaining.filter { candidate in
                revisions.contains {
                    $0.parentRevisionID == candidate && remaining.contains($0.id)
                } == false
            }.sorted()
            guard leaves.isEmpty == false else {
                throw Error.revisionHasDescendants(remaining.sorted()[0])
            }
            for entityID in leaves {
                try applyFetchedDeletion(
                    recordType: .revision,
                    entityID: entityID,
                    db: db)
                remaining.remove(entityID)
            }
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

    private func syncIdentityOwners(
        recordName: String,
        db: Database
    ) throws -> Set<String> {
        Set(
            try String.fetchAll(
                db,
                sql: """
                    SELECT account_owner_id
                    FROM article_sync_record
                    WHERE record_name = ? AND account_owner_id != ''
                    UNION
                    SELECT account_owner_id
                    FROM article_sync_outbox
                    WHERE record_name = ? AND account_owner_id != ''
                    """,
                arguments: [recordName, recordName]))
    }

    private func adoptOwnerlessChanges(
        for owner: String,
        db: Database
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT record_name, record_type, entity_id, operation,
                       generation, queued_at
                FROM article_sync_outbox
                WHERE account_owner_id = ''
                ORDER BY queued_at, record_name
                """)
        for row in rows {
            let recordName: String = row["record_name"]
            let rawType: String = row["record_type"]
            let entityID: String = row["entity_id"]
            let rawOperation: String = row["operation"]
            let ownerlessGeneration: Int64 = row["generation"]
            let queuedAt: String = row["queued_at"]
            guard let recordType = ArticleCloudRecordType(rawValue: rawType)
            else {
                throw Error.invalidRecordType(rawType)
            }
            guard ArticleSyncOperation(rawValue: rawOperation) != nil else {
                throw Error.invalidOperation(rawOperation)
            }
            guard
                recordName
                    == "\(recordType.recordNamePrefix).\(entityID)",
                ownerlessGeneration > 0
            else {
                throw Error.invalidGeneration
            }
            let historicalOwners = try syncIdentityOwners(
                recordName: recordName,
                db: db)
            guard historicalOwners.isEmpty || historicalOwners == Set([owner])
            else {
                continue
            }
            let target = try Row.fetchOne(
                db,
                sql: """
                    SELECT record_type, entity_id, generation
                    FROM article_sync_outbox
                    WHERE record_name = ? AND account_owner_id = ?
                    """,
                arguments: [recordName, owner])
            if let target {
                let targetType: String = target["record_type"]
                let targetEntityID: String = target["entity_id"]
                guard targetType == rawType, targetEntityID == entityID else {
                    throw Error.recordIdentityMismatch
                }
            }
            let receipt = try Row.fetchOne(
                db,
                sql: """
                    SELECT record_type, entity_id, acknowledged_generation
                    FROM article_sync_record
                    WHERE record_name = ? AND account_owner_id = ?
                    """,
                arguments: [recordName, owner])
            if let receipt {
                let receiptType: String = receipt["record_type"]
                let receiptEntityID: String = receipt["entity_id"]
                guard receiptType == rawType, receiptEntityID == entityID else {
                    throw Error.recordIdentityMismatch
                }
            }
            let targetGeneration: Int64 = target?["generation"] ?? 0
            let acknowledgedGeneration: Int64 =
                receipt?["acknowledged_generation"] ?? 0
            let durableGeneration = max(
                ownerlessGeneration,
                targetGeneration,
                acknowledgedGeneration)
            guard durableGeneration < Int64.max else {
                throw Error.invalidGeneration
            }
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
                    rawType,
                    entityID,
                    rawOperation,
                    durableGeneration + 1,
                    owner,
                    queuedAt,
                ])
            try db.execute(
                sql: """
                    DELETE FROM article_sync_outbox
                    WHERE record_name = ? AND account_owner_id = ''
                    """,
                arguments: [recordName])
        }
    }

    private func accountOwnerIsQuarantined(
        _ owner: String,
        db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM article_sync_account_guard
                    WHERE account_owner_id = ?
                )
                """,
            arguments: [owner]) ?? false
    }

    private func guardOwnerWithPendingSave(
        _ owner: String,
        reason: String,
        updatedAt: String,
        db: Database
    ) throws {
        let hasPendingSave =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM article_sync_outbox
                        WHERE account_owner_id = ? AND operation = ?
                    )
                    """,
                arguments: [owner, ArticleSyncOperation.save.rawValue]) ?? false
        guard hasPendingSave else { return }
        try db.execute(
            sql: """
                INSERT INTO article_sync_account_guard (
                    account_owner_id, reason, updated_at
                )
                VALUES (?, ?, ?)
                ON CONFLICT(account_owner_id) DO UPDATE SET
                    reason = excluded.reason,
                    updated_at = excluded.updated_at
                """,
            arguments: [owner, reason, updatedAt])
    }

    private func activeAccountLaneIsRestricted(_ db: Database) throws -> Bool {
        guard
            let state = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_owner_id, account_status
                    FROM article_sync_state WHERE id = 'default'
                    """)
        else {
            return true
        }
        let status: String = state["account_status"]
        if status == ArticleSyncAccountStatus.restricted.rawValue {
            return true
        }
        let owner: String? = state["account_owner_id"]
        guard let owner, owner.isEmpty == false else { return true }
        return try accountOwnerIsQuarantined(owner, db: db)
    }

    private func hasActivePendingDelete(
        recordType: ArticleCloudRecordType,
        entityID: String,
        db: Database
    ) throws -> Bool {
        guard
            let owner = try String.fetchOne(
                db,
                sql: """
                    SELECT account_owner_id FROM article_sync_state
                    WHERE id = 'default'
                    """),
            owner.isEmpty == false
        else {
            return false
        }
        let recordName = "\(recordType.recordNamePrefix).\(entityID)"
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT record_type, entity_id, operation
                    FROM article_sync_outbox
                    WHERE record_name = ? AND account_owner_id = ?
                    """,
                arguments: [recordName, owner])
        else {
            return false
        }
        let rawType: String = row["record_type"]
        let storedEntityID: String = row["entity_id"]
        let rawOperation: String = row["operation"]
        guard rawType == recordType.rawValue, storedEntityID == entityID,
            let operation = ArticleSyncOperation(rawValue: rawOperation)
        else {
            throw Error.invalidOperation(rawOperation)
        }
        return operation == .delete
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
