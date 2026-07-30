// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct SchemaV39ArticleSyncTests {
    @MainActor
    @Test func freshInstallCreatesSyncStateAndDurableOutbox() throws {
        let database = try DatabaseService(inMemory: ())

        try database.read { db in
            let stateColumns = try db.columns(in: "article_sync_state").map(\.name)
            #expect(
                stateColumns
                    == [
                        "id",
                        "engine_state",
                        "account_owner_id",
                        "account_status",
                        "last_error_code",
                        "updated_at",
                    ])

            let outboxColumns = try db.columns(in: "article_sync_outbox").map(\.name)
            #expect(
                outboxColumns
                    == [
                        "record_name",
                        "record_type",
                        "entity_id",
                        "operation",
                        "generation",
                        "account_owner_id",
                        "queued_at",
                    ])

            let recordColumns = try db.columns(in: "article_sync_record").map(\.name)
            #expect(
                recordColumns
                    == [
                        "record_name",
                        "record_type",
                        "entity_id",
                        "system_fields",
                        "content_fingerprint",
                        "acknowledged_generation",
                        "account_owner_id",
                        "updated_at",
                    ])

            let guardColumns = try db.columns(in: "article_sync_account_guard").map(\.name)
            #expect(
                guardColumns
                    == [
                        "account_owner_id",
                        "reason",
                        "updated_at",
                    ])
        }
    }

    @MainActor
    @Test func v38UpgradePreservesWorkshopRows() throws {
        let writer = try DatabaseQueue()
        try migrateThroughV38(writer)

        let capture = articleSyncCaptureFixture(id: "00000000-0000-0000-0000-000000000101")
        try writer.write { db in
            var capture = capture
            try capture.insert(db)
        }

        var v39 = DatabaseMigrator()
        v39.registerMigration("v39_article_sync") { db in
            try Schema_V39.migrate(db)
        }
        try v39.migrate(writer)

        let preserved = try writer.read { db in
            try ArticleCaptureRecord.fetchOne(db, key: capture.id)
        }
        #expect(preserved == capture)
    }

    @MainActor
    @Test func engineSerializationRoundTripsThroughDurableState() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let original = try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: Data(#"{"data":"dGFzay0xNg=="}"#.utf8))

        try dao.saveEngineState(
            original,
            accountStatus: .available,
            updatedAt: "2026-07-29T12:00:00Z")
        let restored = try #require(try dao.engineState())

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let restoredData = try encoder.encode(restored)
        let originalData = try encoder.encode(original)
        #expect(restoredData == originalData)
        #expect(try dao.state()?.accountStatus == .available)
    }

    @MainActor
    @Test func deleteTombstoneSurvivesSaveAcknowledgmentUntilDeleteAcknowledgment() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let save = ArticlePendingCloudChange(
            recordName: "capture.00000000-0000-0000-0000-000000000101",
            recordType: .capture,
            entityID: "00000000-0000-0000-0000-000000000101",
            operation: .save,
            queuedAt: "2026-07-29T12:00:00Z")
        let persistedSave = try dao.enqueueReturning(save)
        try dao.acknowledgeSaved([
            .init(
                recordName: persistedSave.recordName,
                generation: persistedSave.generation,
                systemFields: Data("save-system-fields".utf8),
                contentFingerprint: "save")
        ])
        #expect(try dao.pendingChanges().isEmpty)

        var tombstone = save
        tombstone.operation = .delete
        tombstone.queuedAt = "2026-07-29T12:01:00Z"
        let persistedTombstone = try dao.enqueueReturning(tombstone)
        try dao.acknowledgeSaved([
            .init(
                recordName: persistedSave.recordName,
                generation: persistedSave.generation,
                systemFields: Data("late-save-system-fields".utf8),
                contentFingerprint: "late-save")
        ])
        #expect(try dao.pendingChanges() == [persistedTombstone])

        try dao.acknowledgeDeleted([
            .init(
                recordName: persistedTombstone.recordName,
                generation: persistedTombstone.generation)
        ])
        #expect(try dao.pendingChanges().isEmpty)
    }

    @MainActor
    @Test func partialSaveAcknowledgmentRetainsOnlyFailedOutboxRows() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let succeeded = ArticlePendingCloudChange(
            recordName: "revision.00000000-0000-0000-0000-000000000110",
            recordType: .revision,
            entityID: "00000000-0000-0000-0000-000000000110",
            operation: .save,
            queuedAt: "2026-07-29T12:00:00Z")
        let failed = ArticlePendingCloudChange(
            recordName: "revision.00000000-0000-0000-0000-000000000111",
            recordType: .revision,
            entityID: "00000000-0000-0000-0000-000000000111",
            operation: .save,
            queuedAt: "2026-07-29T12:00:01Z")
        let persistedSucceeded = try dao.enqueueReturning(succeeded)
        let persistedFailed = try dao.enqueueReturning(failed)

        try dao.acknowledgeSaved([
            .init(
                recordName: persistedSucceeded.recordName,
                generation: persistedSucceeded.generation,
                systemFields: Data("save-system-fields".utf8),
                contentFingerprint: "save")
        ])

        #expect(try dao.pendingChanges() == [persistedFailed])
    }

    @MainActor
    @Test func staleSaveAcknowledgmentCannotDeleteNewerGeneration() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let change = ArticlePendingCloudChange(
            recordName: "anthology.00000000-0000-0000-0000-000000000121",
            recordType: .anthology,
            entityID: "00000000-0000-0000-0000-000000000121",
            operation: .save,
            queuedAt: "2026-07-29T12:00:01Z")

        let v1 = try dao.enqueueReturning(change)
        let v2 = try dao.enqueueReturning(change)
        #expect(v2.generation > v1.generation)

        try dao.acknowledgeSaved([
            .init(
                recordName: v1.recordName,
                generation: v1.generation,
                systemFields: Data("old".utf8),
                contentFingerprint: "v1")
        ])
        #expect(try dao.pendingChanges() == [v2])
        #expect(
            try dao.cloudRecord(recordName: v1.recordName)?.systemFields
                == Data("old".utf8))
        #expect(try dao.cloudRecord(recordName: v1.recordName)?.contentFingerprint == "v1")
    }

    @MainActor
    @Test func systemFieldsPersistForNextSaveAndClearAfterMatchingDelete() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let save = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.00000000-0000-0000-0000-000000000122",
                recordType: .capture,
                entityID: "00000000-0000-0000-0000-000000000122",
                operation: .save,
                queuedAt: "2026-07-29T12:00:01Z"))
        let fields = Data("server-system-fields".utf8)

        try dao.acknowledgeSaved([
            .init(
                recordName: save.recordName,
                generation: save.generation,
                systemFields: fields,
                contentFingerprint: "fingerprint")
        ])
        #expect(try dao.cloudRecord(recordName: save.recordName)?.systemFields == fields)

        var deletion = save
        deletion.operation = .delete
        deletion.queuedAt = "2026-07-29T12:01:00Z"
        let tombstone = try dao.enqueueReturning(deletion)
        try dao.acknowledgeDeleted([
            .init(recordName: tombstone.recordName, generation: tombstone.generation)
        ])
        #expect(try dao.cloudRecord(recordName: save.recordName) == nil)
    }

    @MainActor
    @Test func veryLateSaveCannotReplaceNewerAcknowledgedServerBase() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let seed = ArticlePendingCloudChange(
            recordName: "capture.00000000-0000-0000-0000-000000000124",
            recordType: .capture,
            entityID: "00000000-0000-0000-0000-000000000124",
            operation: .save,
            queuedAt: "2026-07-29T12:00:01Z")
        let v1 = try dao.enqueueReturning(seed)
        let v2 = try dao.enqueueReturning(seed)
        try dao.acknowledgeSaved([
            .init(
                recordName: v1.recordName,
                generation: v1.generation,
                systemFields: Data("v1-fields".utf8),
                contentFingerprint: "v1")
        ])
        try dao.acknowledgeSaved([
            .init(
                recordName: v2.recordName,
                generation: v2.generation,
                systemFields: Data("v2-fields".utf8),
                contentFingerprint: "v2")
        ])
        let v3 = try dao.enqueueReturning(seed)
        #expect(v3.generation > v2.generation)

        try dao.acknowledgeSaved([
            .init(
                recordName: v1.recordName,
                generation: v1.generation,
                systemFields: Data("late-v1-fields".utf8),
                contentFingerprint: "late-v1")
        ])

        let stored = try #require(try dao.cloudRecord(recordName: seed.recordName))
        #expect(stored.systemFields == Data("v2-fields".utf8))
        #expect(stored.contentFingerprint == "v2")
        #expect(stored.acknowledgedGeneration == v2.generation)
        #expect(try dao.pendingChanges() == [v3])
    }

    @MainActor
    @Test func accountSwitchQuarantinesPriorOwnerOutboxAndEngineState() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let state = try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: Data(#"{"data":"YWNjb3VudC1B"}"#.utf8))
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        try dao.saveEngineState(state, updatedAt: "2026-07-29T12:00:01Z")
        let pendingA = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "revision.00000000-0000-0000-0000-000000000123",
                recordType: .revision,
                entityID: "00000000-0000-0000-0000-000000000123",
                operation: .save,
                queuedAt: "2026-07-29T12:00:02Z"))
        #expect(pendingA.accountOwnerID == "account-A")

        try dao.bindAccountOwner("account-B", updatedAt: "2026-07-29T12:01:00Z")

        #expect(try dao.engineState() == nil)
        #expect(try dao.pendingChanges().isEmpty)
        #expect(try dao.pendingChanges(accountOwnerID: "account-A") == [pendingA])
        #expect(try dao.state()?.accountOwnerID == "account-B")

        let returned = try dao.bindAccountOwner(
            "account-A",
            updatedAt: "2026-07-29T12:02:00Z")
        #expect(returned == .quarantined)
        #expect(try dao.activeAccountLaneIsRestricted())
        #expect(try dao.pendingChanges().isEmpty)
    }

    @MainActor
    @Test func explicitStaleOwnerEnqueueIsRejectedWithoutMutation() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        try dao.bindAccountOwner("account-B", updatedAt: "2026-07-29T12:01:00Z")
        let stale = ArticlePendingCloudChange(
            recordName: "capture.00000000-0000-0000-0000-000000000124",
            recordType: .capture,
            entityID: "00000000-0000-0000-0000-000000000124",
            operation: .save,
            accountOwnerID: "account-A",
            queuedAt: "2026-07-29T12:01:01Z")

        #expect(throws: ArticleSyncDAO.Error.accountOwnerMismatch) {
            _ = try dao.enqueueReturning(stale)
        }
        #expect(try dao.pendingChanges().isEmpty)
        #expect(try dao.pendingChanges(accountOwnerID: "account-A").isEmpty)
    }

    @MainActor
    @Test func deleteOnlyPriorOwnerLaneMayResumeWithoutSerializingContent() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let deletion = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.00000000-0000-0000-0000-000000000125",
                recordType: .capture,
                entityID: "00000000-0000-0000-0000-000000000125",
                operation: .delete,
                queuedAt: "2026-07-29T12:00:01Z"))

        try dao.bindAccountOwner("account-B", updatedAt: "2026-07-29T12:01:00Z")
        let returned = try dao.bindAccountOwner(
            "account-A",
            updatedAt: "2026-07-29T12:02:00Z")

        #expect(returned == .available)
        #expect(try dao.activeAccountLaneIsRestricted() == false)
        #expect(try dao.pendingChanges() == [deletion])
    }

    @MainActor
    @Test func signOutWithPendingSaveGuardsOwnerBeforeStateIsCleared() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let pending = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.00000000-0000-0000-0000-000000000126",
                recordType: .capture,
                entityID: "00000000-0000-0000-0000-000000000126",
                operation: .save,
                queuedAt: "2026-07-29T12:00:01Z"))

        try dao.unbindAccountOwner(
            status: .signedOut,
            updatedAt: "2026-07-29T12:01:00Z")
        let returned = try dao.bindAccountOwner(
            "account-A",
            updatedAt: "2026-07-29T12:02:00Z")

        #expect(returned == .quarantined)
        #expect(try dao.pendingChanges().isEmpty)
        #expect(try dao.pendingChanges(accountOwnerID: "account-A") == [pending])
    }

    @MainActor
    @Test func missingZoneRecoveryUsesOnlyActiveOwnerDesiredState() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let captureDAO = ArticleCaptureDAO(db: database.writer)
        let accountAID = "00000000-0000-0000-0000-000000000130"
        let accountBAcknowledgedID = "00000000-0000-0000-0000-000000000131"
        let accountBPendingSaveID = "00000000-0000-0000-0000-000000000132"
        let accountBPendingDeleteID = "00000000-0000-0000-0000-000000000133"
        for id in [
            accountAID,
            accountBAcknowledgedID,
            accountBPendingSaveID,
            accountBPendingDeleteID,
        ] {
            try captureDAO.saveCapture(articleSyncCaptureFixture(id: id))
        }

        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let accountARecordName = "capture.\(accountAID)"
        try dao.storeFetchedCloudRecord(
            recordName: accountARecordName,
            recordType: .capture,
            entityID: accountAID,
            systemFields: Data("account-a-fields".utf8),
            contentFingerprint: "account-a",
            updatedAt: "2026-07-29T12:00:01Z")

        try dao.bindAccountOwner("account-B", updatedAt: "2026-07-29T12:01:00Z")
        let accountBAcknowledgedRecordName = "capture.\(accountBAcknowledgedID)"
        try dao.storeFetchedCloudRecord(
            recordName: accountBAcknowledgedRecordName,
            recordType: .capture,
            entityID: accountBAcknowledgedID,
            systemFields: Data("account-b-fields".utf8),
            contentFingerprint: "account-b",
            updatedAt: "2026-07-29T12:01:01Z")
        let pendingSave = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.\(accountBPendingSaveID)",
                recordType: .capture,
                entityID: accountBPendingSaveID,
                operation: .save,
                queuedAt: "2026-07-29T12:01:02Z"))
        let pendingDelete = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.\(accountBPendingDeleteID)",
                recordType: .capture,
                entityID: accountBPendingDeleteID,
                operation: .delete,
                queuedAt: "2026-07-29T12:01:03Z"))

        let recovered = try dao.recoverMissingZone(updatedAt: "2026-07-29T12:02:00Z")

        #expect(
            Set(recovered.map(\.recordName)) == [
                accountBAcknowledgedRecordName,
                pendingSave.recordName,
            ])
        #expect(recovered.allSatisfy { $0.accountOwnerID == "account-B" })
        #expect(recovered.allSatisfy { $0.operation == .save })
        #expect(
            recovered.first { $0.recordName == pendingSave.recordName }?.generation
                == pendingSave.generation + 1)
        #expect(recovered.contains { $0.recordName == accountARecordName } == false)
        #expect(recovered.contains { $0.recordName == pendingDelete.recordName } == false)
        #expect(try dao.pendingChanges() == recovered)
        #expect(try dao.allCloudRecords().isEmpty)
        try database.read { db in
            let accountAReceiptCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM article_sync_record
                    WHERE account_owner_id = 'account-A' AND record_name = ?
                    """,
                arguments: [accountARecordName])
            let captureCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM article_capture")
            #expect(accountAReceiptCount == 1)
            #expect(captureCount == 4)
        }
    }

    @MainActor
    @Test func quarantinedAccountRemainsRestrictedAcrossSignInSwitchAndRestart() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let zone = CKRecordZone.ID(
            zoneName: "_defaultZone",
            ownerName: CKCurrentUserDefaultName)
        let accountA = CKRecord.ID(recordName: "account-A", zoneID: zone)
        let accountB = CKRecord.ID(recordName: "account-B", zoneID: zone)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let pendingA = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.00000000-0000-0000-0000-000000000134",
                recordType: .capture,
                entityID: "00000000-0000-0000-0000-000000000134",
                operation: .save,
                queuedAt: "2026-07-29T12:00:01Z"))
        try dao.quarantineActiveAccountOwner(
            reason: "encryptedDataReset",
            updatedAt: "2026-07-29T12:00:02Z")

        let restartedDAO = ArticleSyncDAO(db: database.writer)
        let restartedHandler = ArticleSyncAccountEventHandler(syncDAO: restartedDAO)
        let sameAccount = try restartedHandler.handle(
            .signIn(currentUser: accountA),
            updatedAt: "2026-07-29T12:01:00Z")
        #expect(sameAccount.shouldSchedulePendingChanges == false)
        #expect(try restartedDAO.state()?.accountOwnerID == "account-A")
        #expect(try restartedDAO.state()?.accountStatus == .restricted)
        #expect(try restartedDAO.pendingChanges().isEmpty)
        #expect(
            try restartedDAO.pendingChanges(accountOwnerID: "account-A") == [pendingA])
        try restartedDAO.updateStatus(
            .unknown,
            lastErrorCode: "late-event",
            updatedAt: "2026-07-29T12:01:01Z")
        #expect(try restartedDAO.state()?.accountStatus == .restricted)
        #expect(try restartedDAO.pendingChanges().isEmpty)

        let switchedToB = try restartedHandler.handle(
            .switchAccounts(previousUser: accountA, currentUser: accountB),
            updatedAt: "2026-07-29T12:02:00Z")
        #expect(switchedToB.shouldSchedulePendingChanges)
        #expect(try restartedDAO.state()?.accountOwnerID == "account-B")
        #expect(try restartedDAO.state()?.accountStatus == .switchedAccount)

        let switchedBackToA = try restartedHandler.handle(
            .switchAccounts(previousUser: accountB, currentUser: accountA),
            updatedAt: "2026-07-29T12:03:00Z")
        #expect(switchedBackToA.shouldSchedulePendingChanges == false)
        #expect(try restartedDAO.state()?.accountOwnerID == "account-A")
        #expect(try restartedDAO.state()?.accountStatus == .restricted)
        #expect(try restartedDAO.pendingChanges().isEmpty)
        #expect(
            try restartedDAO.pendingChanges(accountOwnerID: "account-A") == [pendingA])
    }

    @MainActor
    @Test func routineStateUpdatePreservesLastErrorUntilExplicitClear() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let state = try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: Data(#"{"data":"c3RhdGU="}"#.utf8))
        try dao.updateStatus(
            .temporarilyUnavailable,
            lastErrorCode: "network",
            updatedAt: "2026-07-29T12:00:00Z")

        try dao.saveEngineState(state, updatedAt: "2026-07-29T12:00:01Z")
        #expect(try dao.state()?.lastErrorCode == "network")
        try dao.clearLastError(updatedAt: "2026-07-29T12:00:02Z")
        #expect(try dao.state()?.lastErrorCode == nil)
    }
}

private func migrateThroughV38(_ writer: DatabaseWriter) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_create_schema") { try Schema_V1.migrate($0) }
    migrator.registerMigration("v25_study_plans") { try Schema_V25.migrate($0) }
    migrator.registerMigration("v26_timeline_segment_key") { try Schema_V26.migrate($0) }
    migrator.registerMigration("v27_library") { try Schema_V27.migrate($0) }
    migrator.registerMigration("v28_pdf_block_page") { try Schema_V28.migrate($0) }
    migrator.registerMigration("v29_audiobook_text_origin") { try Schema_V29.migrate($0) }
    migrator.registerMigration("v30_narration_quality_issue") { try Schema_V30.migrate($0) }
    migrator.registerMigration("v31_abs_server_multi") { try Schema_V31.migrate($0) }
    migrator.registerMigration("v32_narration_text") { try Schema_V32.migrate($0) }
    migrator.registerMigration("v33_study_plan_card_pacing") { try Schema_V33.migrate($0) }
    migrator.registerMigration("v34_study_auto_export") { try Schema_V34.migrate($0) }
    migrator.registerMigration("v35_library_edition_grouping") { try Schema_V35.migrate($0) }
    migrator.registerMigration("v36_code_language") { try Schema_V36.migrate($0) }
    migrator.registerMigration("v37_article_workshop") { try Schema_V37.migrate($0) }
    migrator.registerMigration("v37_repair_anthology_build_attempt_receipts") {
        try Schema_V37.repairBuildAttemptReceipts($0)
    }
    migrator.registerMigration("v38_generated_chapter_key") { try Schema_V38.migrate($0) }
    try migrator.migrate(writer)
}

private func articleSyncCaptureFixture(id: String) -> ArticleCaptureRecord {
    ArticleCaptureRecord(
        id: id,
        sourceURL: "https://example.test/source",
        canonicalURL: "https://example.test/canonical",
        title: "Private article",
        author: "A. Reader",
        siteName: "Example",
        language: "en",
        publishedAt: "2026-07-28T12:00:00Z",
        capturedAt: "2026-07-28T12:01:00Z",
        captureMethod: .urlFetch,
        packagePath: "/local/private/package",
        contentSHA256: String(repeating: "a", count: 64),
        extractorVersion: "schema-1",
        contentState: "ready",
        warningsJSON: "[]",
        currentRevisionID: nil,
        createdAt: "2026-07-28T12:01:00Z",
        modifiedAt: "2026-07-28T12:01:00Z")
}
