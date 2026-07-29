// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import Foundation
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
        #expect(await driver.scheduledChanges() == [tombstone])
        #expect(try dao.pendingChanges() == [tombstone])

        try engine.acknowledgeSent(savedRecordNames: [], deletedRecordNames: [tombstone.recordName])
        #expect(try dao.pendingChanges().isEmpty)
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
