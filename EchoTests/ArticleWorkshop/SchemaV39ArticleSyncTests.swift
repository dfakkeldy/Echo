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
                        "queued_at",
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
        let save = ArticlePendingCloudChange(
            recordName: "capture.00000000-0000-0000-0000-000000000101",
            recordType: .capture,
            entityID: "00000000-0000-0000-0000-000000000101",
            operation: .save,
            queuedAt: "2026-07-29T12:00:00Z")
        try dao.enqueue(save)
        try dao.acknowledgeSaved(recordNames: [save.recordName])
        #expect(try dao.pendingChanges().isEmpty)

        var tombstone = save
        tombstone.operation = .delete
        tombstone.queuedAt = "2026-07-29T12:01:00Z"
        try dao.enqueue(tombstone)
        try dao.acknowledgeSaved(recordNames: [save.recordName])
        #expect(try dao.pendingChanges() == [tombstone])

        try dao.acknowledgeDeleted(recordNames: [save.recordName])
        #expect(try dao.pendingChanges().isEmpty)
    }

    @MainActor
    @Test func partialSaveAcknowledgmentRetainsOnlyFailedOutboxRows() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
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
        try dao.enqueue([succeeded, failed])

        try dao.acknowledgeSaved(recordNames: [succeeded.recordName])

        #expect(try dao.pendingChanges() == [failed])
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
