// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct ArticleSyncConflictResolverTests {
    @Test func siblingCleanupRevisionsAreBothRetainedAndMarkedForReview() throws {
        let resolver = ArticleSyncConflictResolver()
        let parent = revision(
            id: "00000000-0000-0000-0000-000000000301",
            parentID: nil,
            recipe: "{}")
        let local = revision(
            id: "00000000-0000-0000-0000-000000000302",
            parentID: parent.id,
            recipe: "{\"excludedBlockIDs\":[\"local\"]}")
        let remote = revision(
            id: "00000000-0000-0000-0000-000000000303",
            parentID: parent.id,
            recipe: "{\"excludedBlockIDs\":[\"remote\"]}")

        let result = resolver.resolveRevision(
            incoming: remote,
            existing: [parent, local],
            activeRevisionID: local.id)

        #expect(Set(result.revisions.map(\.id)) == [parent.id, local.id, remote.id])
        #expect(result.activeRevisionID == local.id)
        #expect(result.requiresReview)
    }

    @Test func concurrentAnthologyEditCreatesRecoveredCopyWithoutLosingEitherOrder() throws {
        let resolver = ArticleSyncConflictResolver()
        let local = anthologyManifest(
            title: "Reading list",
            modifiedAt: "2026-07-29T12:00:00Z",
            captureIDs: [
                "00000000-0000-0000-0000-000000000311",
                "00000000-0000-0000-0000-000000000312",
            ])
        let incoming = anthologyManifest(
            title: "Reading list from Mac",
            modifiedAt: "2026-07-29T12:00:01Z",
            captureIDs: [
                "00000000-0000-0000-0000-000000000312",
                "00000000-0000-0000-0000-000000000311",
            ])
        let recoveredID = UUID(uuidString: "00000000-0000-0000-0000-000000000399")!

        let result = resolver.resolveAnthology(
            incoming: incoming,
            existing: local,
            makeRecoveredID: { recoveredID })
        let repeated = resolver.resolveAnthology(
            incoming: incoming,
            existing: local,
            makeRecoveredID: { recoveredID })

        #expect(result.active == local)
        #expect(result.recovered.anthology.id == recoveredID.uuidString)
        #expect(result.recovered.anthology.title == "Reading list from Mac (Recovered)")
        #expect(result.active.entries.map(\.captureID) == local.entries.map(\.captureID))
        #expect(result.recovered.entries.map(\.captureID) == incoming.entries.map(\.captureID))
        #expect(result.recovered.entries.map(\.id) == repeated.recovered.entries.map(\.id))
    }

    @MainActor
    @Test func deterministicDriverKeepsDeletePendingUntilCloudAcknowledgesIt() async throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let driver = DeterministicArticleSyncEngineDriver()
        let engine = ArticleWorkshopCloudSyncEngine(syncDAO: dao, driver: driver)
        let tombstone = ArticlePendingCloudChange(
            recordName: "anthology.00000000-0000-0000-0000-000000000321",
            recordType: .anthology,
            entityID: "00000000-0000-0000-0000-000000000321",
            operation: .delete,
            queuedAt: "2026-07-29T12:00:00Z")

        await engine.schedule([tombstone])
        try await engine.sendChanges()
        let persisted = try #require(try dao.pendingChange(recordName: tombstone.recordName))
        #expect(await driver.scheduledChanges() == [persisted])
        #expect(try dao.pendingChanges() == [persisted])

        try dao.acknowledgeDeleted([
            .init(recordName: persisted.recordName, generation: persisted.generation)
        ])
        #expect(try dao.pendingChanges().isEmpty)
    }

    @MainActor
    @Test func deterministicDriverReceivesAdvancedDurableGeneration() async throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let driver = DeterministicArticleSyncEngineDriver()
        let engine = ArticleWorkshopCloudSyncEngine(syncDAO: dao, driver: driver)
        let proposed = ArticlePendingCloudChange(
            recordName: "capture.00000000-0000-0000-0000-000000000322",
            recordType: .capture,
            entityID: "00000000-0000-0000-0000-000000000322",
            operation: .save,
            queuedAt: "2026-07-29T12:00:00Z")

        await engine.schedule([proposed])
        let first = try #require(try dao.pendingChange(recordName: proposed.recordName))
        await engine.schedule([proposed])
        let second = try #require(try dao.pendingChange(recordName: proposed.recordName))

        #expect(second.generation > first.generation)
        #expect(await driver.scheduledChanges() == [first, second])
    }

    @MainActor
    @Test func fetchedRecordBatchCommitsCaptureAndRevisionTogether() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let capture = fetchedCapture(id: "00000000-0000-0000-0000-000000000330")
        let incomingRevision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000331",
            captureID: capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: "{}",
            recipeJSON: "{}",
            readableContentSHA256: String(repeating: "d", count: 64),
            createdAt: "2026-07-29T12:01:00Z",
            deviceName: "Remote device")

        try dao.applyFetchedChanges([
            .capture(capture),
            .revision(incomingRevision),
        ])

        #expect(try dao.capture(id: capture.id)?.packagePath == capture.packagePath)
        #expect(try dao.revision(id: incomingRevision.id) == incomingRevision)
        #expect(try dao.capture(id: capture.id)?.currentRevisionID == incomingRevision.id)
    }

    @MainActor
    @Test func failedFetchedRecordBatchRollsBackEveryDatabaseChange() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let capture = fetchedCapture(id: "00000000-0000-0000-0000-000000000340")
        let invalidRevision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000341",
            captureID: "00000000-0000-0000-0000-000000000349",
            parentRevisionID: nil,
            metadataOverridesJSON: "{}",
            recipeJSON: "{}",
            readableContentSHA256: String(repeating: "e", count: 64),
            createdAt: "2026-07-29T12:01:00Z",
            deviceName: nil)

        #expect(throws: (any Error).self) {
            try dao.applyFetchedChanges([
                .capture(capture),
                .revision(invalidRevision),
            ])
        }
        #expect(try dao.capture(id: capture.id) == nil)
    }

    @MainActor
    @Test func sequentialRemoteAnthologyUpdateReplacesAuthoringStateButKeepsLocalProducts() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let local = anthologyManifest(
            title: "Old remote title",
            modifiedAt: "2026-07-29T12:00:00Z",
            captureIDs: [])
        var stored = local.anthology
        stored.coverPath = "cover-local.png"
        stored.latestBuildRevision = 7
        try database.write { db in try stored.insert(db) }
        let incoming = anthologyManifest(
            title: "New remote title",
            modifiedAt: "2026-07-29T12:01:00Z",
            captureIDs: [])

        try dao.applyFetchedChanges([.anthology(incoming)])

        let updated = try #require(try dao.anthologyManifest(id: stored.id))
        #expect(updated.anthology.title == "New remote title")
        #expect(updated.anthology.coverPath == "cover-local.png")
        #expect(updated.anthology.latestBuildRevision == 7)
        #expect(
            try database.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM anthology")
            } == 1)
    }

    @MainActor
    @Test func locallyDivergedAnthologyCreatesRecoveredCopy() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let base = anthologyManifest(
            title: "Shared title",
            modifiedAt: "2026-07-29T12:00:00Z",
            captureIDs: [])
        try database.write { db in
            var anthology = base.anthology
            try anthology.insert(db)
        }
        try dao.storeFetchedCloudRecord(
            recordName: "anthology.\(base.anthology.id)",
            recordType: .anthology,
            entityID: base.anthology.id,
            systemFields: Data("base-fields".utf8),
            contentFingerprint: try ArticleSyncFingerprint.anthology(base),
            updatedAt: "2026-07-29T12:00:00Z")
        try database.write { db in
            try db.execute(
                sql: "UPDATE anthology SET title = ?, modified_at = ? WHERE id = ?",
                arguments: [
                    "Local edit",
                    "2026-07-29T12:01:00Z",
                    base.anthology.id,
                ])
        }
        _ = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "anthology.\(base.anthology.id)",
                recordType: .anthology,
                entityID: base.anthology.id,
                operation: .save,
                queuedAt: "2026-07-29T12:01:00Z"))
        let incoming = anthologyManifest(
            title: "Remote edit",
            modifiedAt: "2026-07-29T12:01:01Z",
            captureIDs: [])

        try dao.applyFetchedChanges([.anthology(incoming)])

        #expect(try dao.anthologyManifest(id: base.anthology.id)?.anthology.title == "Local edit")
        #expect(
            try database.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM anthology")
            } == 2)
    }

    @MainActor
    @Test func missingZoneRecoveryRequeuesEveryAuthoritativeLocalRecord() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let capture = fetchedCapture(id: "00000000-0000-0000-0000-000000000350")
        let revision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000351",
            captureID: capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON:
                #"{"author":null,"language":null,"publishedTime":null,"siteName":null,"title":null}"#,
            recipeJSON:
                #"{"excludedBlockIDs":[],"metadataOverrides":{"author":null,"language":null,"publishedTime":null,"siteName":null,"title":null},"trimAfterBlockID":null,"trimBeforeBlockID":null}"#,
            readableContentSHA256: String(repeating: "d", count: 64),
            createdAt: "2026-07-29T12:00:01Z",
            deviceName: nil)
        let anthology = anthologyManifest(
            title: "Local anthology",
            modifiedAt: "2026-07-29T12:00:02Z",
            captureIDs: [])
        try database.write { db in
            var capture = capture
            var revision = revision
            var project = anthology.anthology
            try capture.insert(db)
            try revision.insert(db)
            try project.insert(db)
        }
        for (type, id) in [
            (ArticleCloudRecordType.capture, capture.id),
            (.revision, revision.id),
            (.anthology, anthology.anthology.id),
        ] {
            try dao.storeFetchedCloudRecord(
                recordName: "\(type.recordNamePrefix).\(id)",
                recordType: type,
                entityID: id,
                systemFields: Data("stale".utf8),
                contentFingerprint: "stale",
                updatedAt: "2026-07-29T12:00:03Z")
        }

        let recovery = try dao.recoverMissingZone(updatedAt: "2026-07-29T12:01:00Z")

        #expect(
            Set(recovery.map(\.recordName)) == [
                "capture.\(capture.id)",
                "revision.\(revision.id)",
                "anthology.\(anthology.anthology.id)",
            ])
        #expect(recovery.allSatisfy { $0.operation == .save })
        #expect(try dao.allCloudRecords().isEmpty)
    }

    @Test func fetchedApplyFailureBlocksCheckpointAndSurfacesRetryableFailure() {
        var progress = ArticleSyncFetchProgress()
        progress.recordApplyFailure(.invalidRemoteRecord)

        #expect(progress.shouldPersistState == false)
        #expect(throws: ArticleSyncFetchProgress.Error.applyFailed(.invalidRemoteRecord)) {
            try progress.throwIfFailed()
        }
        progress.recordApplySuccess()
        #expect(progress.shouldPersistState == false)
        progress.resetForNewEngineEpoch()
        #expect(progress.shouldPersistState)
    }

    @MainActor
    @Test func accountEventHandlerSelectsNewLaneAndQuarantinesOldPendingRows() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        let handler = ArticleSyncAccountEventHandler(syncDAO: dao)
        let zone = CKRecordZone.ID(zoneName: "_defaultZone", ownerName: CKCurrentUserDefaultName)
        let accountA = CKRecord.ID(recordName: "account-A", zoneID: zone)
        let accountB = CKRecord.ID(recordName: "account-B", zoneID: zone)
        let signedIn = try handler.handle(
            .signIn(currentUser: accountA),
            updatedAt: "2026-07-29T12:00:00Z")
        #expect(signedIn.shouldSchedulePendingChanges)
        let pendingA = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.00000000-0000-0000-0000-000000000360",
                recordType: .capture,
                entityID: "00000000-0000-0000-0000-000000000360",
                operation: .save,
                queuedAt: "2026-07-29T12:00:01Z"))

        let switched = try handler.handle(
            .switchAccounts(previousUser: accountA, currentUser: accountB),
            updatedAt: "2026-07-29T12:01:00Z")
        #expect(switched.shouldSchedulePendingChanges)

        #expect(try dao.state()?.accountOwnerID == "account-B")
        #expect(try dao.pendingChanges().isEmpty)
        #expect(try dao.pendingChanges(accountOwnerID: "account-A") == [pendingA])
        #expect(
            ArticleSyncAccountEventPolicy.startsNewEngineEpoch(
                .switchAccounts(previousUser: accountA, currentUser: accountB)))
        #expect(
            ArticleSyncAccountEventPolicy.startsNewEngineEpoch(
                .signOut(previousUser: accountB)) == false)

        let signedOut = try handler.handle(
            .signOut(previousUser: accountB),
            updatedAt: "2026-07-29T12:02:00Z")
        #expect(signedOut.shouldSchedulePendingChanges == false)
        _ = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: "capture.00000000-0000-0000-0000-000000000361",
                recordType: .capture,
                entityID: "00000000-0000-0000-0000-000000000361",
                operation: .save,
                queuedAt: "2026-07-29T12:02:01Z"))
        #expect(try dao.pendingChanges().count == 1)
    }

    @Test func failurePolicyRequeuesOnlyAppActionableChanges() {
        #expect(
            ArticleSyncFailurePolicy.action(for: .serverRecordChanged, operation: .save)
                == .mergeServerAndRequeue)
        #expect(
            ArticleSyncFailurePolicy.action(for: .zoneNotFound, operation: .save)
                == .rebuildZone)
        #expect(
            ArticleSyncFailurePolicy.action(for: .unknownItem, operation: .delete)
                == .acknowledgeMissingDelete)
        #expect(
            ArticleSyncFailurePolicy.action(for: .networkFailure, operation: .save)
                == .engineRetains)
        #expect(
            ArticleSyncFailurePolicy.action(for: .quotaExceeded, operation: .save)
                == .waitForUser)
        #expect(
            ArticleSyncFailurePolicy.action(for: .assetFileModified, operation: .save)
                == .manualRequeue)
    }

    @Test func destructiveZoneResetQuarantinesInsteadOfReuploading() {
        #expect(
            ArticleSyncZoneDeletionPolicy.action(for: .deleted)
                == .rebuildFromLocalAuthority)
        #expect(
            ArticleSyncZoneDeletionPolicy.action(for: .purged)
                == .quarantineLane)
        #expect(
            ArticleSyncZoneDeletionPolicy.action(for: .encryptedDataReset)
                == .quarantineLane)
    }

    @Test func failedChangePlanCarriesExactGenerationForRequeueAndMissingDeleteAck() {
        let save = ArticlePendingCloudChange(
            recordName: "revision.00000000-0000-0000-0000-000000000370",
            recordType: .revision,
            entityID: "00000000-0000-0000-0000-000000000370",
            operation: .save,
            generation: 17,
            accountOwnerID: "account-A",
            queuedAt: "2026-07-29T12:00:00Z")
        let requeue = ArticleSyncFailedChangePlan.make(
            code: .assetFileModified,
            change: save)
        #expect(requeue.action == .manualRequeue)
        #expect(requeue.changeToRequeue == save)

        var deletion = save
        deletion.operation = .delete
        let missing = ArticleSyncFailedChangePlan.make(
            code: .unknownItem,
            change: deletion)
        #expect(missing.action == .acknowledgeMissingDelete)
        #expect(
            missing.deleteToAcknowledge
                == ArticleCloudDeleteAcknowledgement(
                    recordName: deletion.recordName,
                    generation: 17))
    }

    @Test func cloudFailuresUseStablePrivacySafeClassifications() {
        let cases: [(CKError.Code, ArticleSyncFailureCode)] = [
            (.quotaExceeded, .quota),
            (.networkUnavailable, .network),
            (.serverRecordChanged, .serverRecordConflict),
            (.notAuthenticated, .authentication),
            (.zoneNotFound, .missingZone),
            (.partialFailure, .partialFailure),
        ]

        for (code, expected) in cases {
            let error = CKError(
                _nsError: NSError(
                    domain: CKErrorDomain,
                    code: code.rawValue))
            #expect(ArticleSyncFailureCode.classify(error) == expected)
        }
    }
}

private actor DeterministicArticleSyncEngineDriver: ArticleSyncEngineDriver {
    private var scheduled: [ArticlePendingCloudChange] = []

    func schedule(_ changes: [ArticlePendingCloudChange]) async {
        scheduled.append(contentsOf: changes)
    }

    func fetchChanges() async throws {}
    func sendChanges() async throws {}

    func scheduledChanges() -> [ArticlePendingCloudChange] {
        scheduled
    }
}

private func revision(id: String, parentID: String?, recipe: String) -> ArticleRevisionRecord {
    ArticleRevisionRecord(
        id: id,
        captureID: "00000000-0000-0000-0000-000000000300",
        parentRevisionID: parentID,
        metadataOverridesJSON: "{}",
        recipeJSON: recipe,
        readableContentSHA256: String(repeating: "c", count: 64),
        createdAt: "2026-07-29T12:00:00Z",
        deviceName: nil)
}

private func anthologyManifest(
    title: String,
    modifiedAt: String,
    captureIDs: [String]
) -> ArticleCloudAnthologyManifest {
    let anthologyID = "00000000-0000-0000-0000-000000000310"
    return ArticleCloudAnthologyManifest(
        schemaVersion: 1,
        anthology: AnthologyRecord(
            id: anthologyID,
            title: title,
            subtitle: nil,
            creator: nil,
            coverPath: nil,
            nextStableSlot: captureIDs.count,
            latestBuildRevision: 0,
            createdAt: "2026-07-29T11:00:00Z",
            modifiedAt: modifiedAt),
        entries: captureIDs.enumerated().map { offset, captureID in
            AnthologyEntryRecord(
                id: "00000000-0000-0000-0000-\(String(format: "%012d", offset + 1))",
                anthologyID: anthologyID,
                captureID: captureID,
                sortOrder: offset,
                stableSlot: offset,
                chapterTitleOverride: nil,
                narrationVoiceID: nil)
        })
}

private func fetchedCapture(id: String) -> ArticleCaptureRecord {
    ArticleCaptureRecord(
        id: id,
        sourceURL: "https://example.test/synced",
        canonicalURL: nil,
        title: "Synced article",
        author: nil,
        siteName: "Example",
        language: "en",
        publishedAt: nil,
        capturedAt: "2026-07-29T12:00:00Z",
        captureMethod: .urlFetch,
        packagePath: "/managed/article/package",
        contentSHA256: String(repeating: "f", count: 64),
        extractorVersion: "schema-1",
        contentState: "ready",
        warningsJSON: "[]",
        currentRevisionID: nil,
        createdAt: "2026-07-29T12:00:00Z",
        modifiedAt: "2026-07-29T12:00:00Z")
}
