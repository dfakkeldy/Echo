// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import CryptoKit
import Foundation
import GRDB
import Testing
import ZIPFoundation

@testable import Echo

@Suite struct ArticleCloudRecordCodecTests {
    @Test func recordNamesAreDeterministicAndOwnedByThePrivateWorkshopZone() throws {
        let codec = ArticleCloudRecordCodec()
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000201"))

        #expect(
            codec.recordID(for: .capture, entityID: id).recordName == "capture.\(id.uuidString)")
        #expect(
            codec.recordID(for: .revision, entityID: id).recordName == "revision.\(id.uuidString)")
        #expect(
            codec.recordID(for: .anthology, entityID: id).recordName == "anthology.\(id.uuidString)"
        )
        #expect(
            codec.recordID(for: .capture, entityID: id).zoneID.zoneName == "EchoArticleWorkshop.v1")
        #expect(
            codec.recordID(for: .capture, entityID: id).zoneID.ownerName == CKCurrentUserDefaultName
        )
    }

    @Test func captureBodyIsPresentOnlyInsideCompressedAsset() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let record = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)

        let asset = try #require(record["package"] as? CKAsset)
        let archiveURL = try #require(asset.fileURL)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        #expect(archive["snapshot.json"] != nil)
        #expect(record["title"] as? String == "Private article")
        #expect(record["contentXHTML"] == nil)
        #expect(record["textContent"] == nil)
        #expect(record.allKeys().contains("package"))
        #expect(
            record.allKeys().allSatisfy {
                !["generatedEPUB", "narration", "m4b", "cookies", "credentials", "error"].contains(
                    $0)
            })
    }

    @Test func provenanceRejectsCredentialsUserInfoFragmentsAndNonHTTPURLs() throws {
        for sourceURL in [
            "https://reader:secret@example.test/article",
            "https://example.test/article?access_token=private",
            "https://example.test/article?CODE=private",
            "https://example.test/article?%6b%65%79=private",
            "https://example.test/article?sig=private",
            "https://example.test/article?access-key=private",
            "https://example.test/article#session=private",
            "file:///private/article.html",
        ] {
            let fixture = try ArticleCloudCodecFixture(sourceURL: sourceURL)
            defer { fixture.remove() }
            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                _ = try fixture.codec.captureRecord(
                    fixture.capture,
                    packageDirectory: fixture.packageDirectory)
            }
        }

        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let encoded = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        encoded["canonicalURL"] =
            "https://example.test/article?api_key=private" as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                encoded,
                assetCopyDirectory: fixture.incomingDirectory)
        }
    }

    @Test func fetchedAssetIsCopiedBeforeDecodeReturns() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let record = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        let cloudTemporaryURL = try #require((record["package"] as? CKAsset)?.fileURL)

        let copied = try fixture.codec.decode(
            record,
            assetCopyDirectory: fixture.incomingDirectory)
        guard case .capture(let payload) = copied else {
            Issue.record("Expected a capture payload")
            return
        }
        try FileManager.default.removeItem(at: cloudTemporaryURL)

        #expect(FileManager.default.fileExists(atPath: payload.packageArchiveURL.path))
        #expect(payload.capture.id == fixture.capture.id)
        #expect(
            payload.packageArchiveURL.standardizedFileURL.deletingLastPathComponent()
                == fixture.incomingDirectory.standardizedFileURL)
    }

    @Test func revisionJSONIsCanonicalAndOversizedOrMalformedRecordsFailClosed() throws {
        let fixture = try ArticleCloudCodecFixture(
            limits: .init(maxScalarBytes: 128, maxCanonicalJSONBytes: 512, maxPackageBytes: 4_096))
        defer { fixture.remove() }
        let revision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000202",
            captureID: fixture.capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: "{\"title\":\"Edited\",\"author\":\"Reader\"}",
            recipeJSON:
                "{\"metadataOverrides\":{\"title\":\"Edited\",\"author\":\"Reader\"},\"excludedBlockIDs\":[]}",
            readableContentSHA256: String(repeating: "b", count: 64),
            createdAt: "2026-07-29T12:00:00Z",
            deviceName: "Test device")

        let encoded = try fixture.codec.revisionRecord(revision)
        #expect(
            encoded["metadataOverridesJSON"] as? String
                == "{\"author\":\"Reader\",\"title\":\"Edited\"}")
        #expect(
            encoded["recipeJSON"] as? String
                == "{\"excludedBlockIDs\":[],\"metadataOverrides\":{\"author\":\"Reader\",\"title\":\"Edited\"}}"
        )

        encoded["recipeJSON"] = "{not-json" as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                encoded,
                assetCopyDirectory: fixture.incomingDirectory)
        }

        let oversized = try fixture.codec.revisionRecord(revision)
        oversized["deviceName"] = String(repeating: "x", count: 129) as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                oversized,
                assetCopyDirectory: fixture.incomingDirectory)
        }

        let rawPath = try fixture.codec.revisionRecord(revision)
        rawPath["packagePath"] = "/private/local/article" as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                rawPath,
                assetCopyDirectory: fixture.incomingDirectory)
        }

        let wrongShape = try fixture.codec.revisionRecord(revision)
        wrongShape["metadataOverridesJSON"] =
            #"{"title":"Edited","token":"private"}"# as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                wrongShape,
                assetCopyDirectory: fixture.incomingDirectory)
        }

        let inconsistent = try fixture.codec.revisionRecord(revision)
        inconsistent["recipeJSON"] =
            #"{"excludedBlockIDs":[],"metadataOverrides":{"title":"Different"}}"# as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                inconsistent,
                assetCopyDirectory: fixture.incomingDirectory)
        }
    }

    @MainActor
    @Test func fetchedCaptureIsInstalledAndCommittedBeforeBatchApplyReturns() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let record = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)

        try applier.apply(modifications: [record], deletions: [])

        let stored = try #require(try dao.capture(id: fixture.capture.id))
        #expect(stored.packagePath.hasPrefix(fixture.managedDirectory.path + "/"))
        #expect(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: stored.packagePath)
                    .appending(path: "snapshot.json").path))
    }

    @MainActor
    @Test func laterSaveRestoresPersistedCloudKitSystemFields() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let first = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        let systemFields = try fixture.codec.systemFields(for: first)
        try dao.storeFetchedCloudRecord(
            recordName: first.recordID.recordName,
            recordType: .capture,
            entityID: fixture.capture.id,
            systemFields: systemFields,
            contentFingerprint: "first",
            updatedAt: "2026-07-29T12:00:01Z")

        let second = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory,
            baseSystemFields: try dao.cloudRecord(recordName: first.recordID.recordName)?
                .systemFields)

        #expect(second.recordID == first.recordID)
        #expect(second.recordType == first.recordType)
        #expect(try fixture.codec.systemFields(for: second) == systemFields)
    }

    @MainActor
    @Test func fetchedDatabaseFailureRemovesOnlyNewManagedFiles() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let record = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)

        do {
            let database = try DatabaseService(inMemory: ())
            let dao = ArticleSyncDAO(db: database.writer)
            try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
            let applier = ArticleFetchedCloudBatchApplier(
                syncDAO: dao,
                codec: fixture.codec,
                workshopRootDirectory: fixture.managedDirectory,
                incomingDirectory: fixture.incomingDirectory,
                beforeDatabaseCommit: { throw InjectedApplyFailure.failed })
            #expect(throws: InjectedApplyFailure.failed) {
                try applier.apply(modifications: [record], deletions: [])
            }
            let installed = fixture.managedDirectory
                .appending(path: "Captures", directoryHint: .isDirectory)
                .appending(path: fixture.capture.id, directoryHint: .isDirectory)
            #expect(FileManager.default.fileExists(atPath: installed.path) == false)
        }

        let cleanDatabase = try DatabaseService(inMemory: ())
        let cleanDAO = ArticleSyncDAO(db: cleanDatabase.writer)
        try cleanDAO.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let cleanApplier = ArticleFetchedCloudBatchApplier(
            syncDAO: cleanDAO,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)
        try cleanApplier.apply(modifications: [record], deletions: [])
        let preexisting = fixture.managedDirectory
            .appending(path: "Captures", directoryHint: .isDirectory)
            .appending(path: fixture.capture.id, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: preexisting.path))

        let failingDatabase = try DatabaseService(inMemory: ())
        let failingDAO = ArticleSyncDAO(db: failingDatabase.writer)
        try failingDAO.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let failingApplier = ArticleFetchedCloudBatchApplier(
            syncDAO: failingDAO,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory,
            beforeDatabaseCommit: { throw InjectedApplyFailure.failed })
        #expect(throws: InjectedApplyFailure.failed) {
            try failingApplier.apply(modifications: [record], deletions: [])
        }
        #expect(FileManager.default.fileExists(atPath: preexisting.path))
    }

    @MainActor
    @Test func fetchedRevisionMustMaterializeAgainstInstalledCaptureBeforeActivation() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)
        let captureRecord = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        try applier.apply(modifications: [captureRecord], deletions: [])

        let recipe = ArticleEditRecipe(
            excludedBlockIDs: ["unknown-block"],
            metadataOverrides: .init())
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let revision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000220",
            captureID: fixture.capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: String(
                decoding: try encoder.encode(recipe.metadataOverrides),
                as: UTF8.self),
            recipeJSON: String(
                decoding: try encoder.encode(recipe),
                as: UTF8.self),
            readableContentSHA256: String(repeating: "b", count: 64),
            createdAt: "2026-07-29T12:00:00Z",
            deviceName: nil)
        let remoteRevision = try fixture.codec.revisionRecord(revision)

        #expect(throws: (any Error).self) {
            try applier.apply(modifications: [remoteRevision], deletions: [])
        }
        #expect(try dao.revision(id: revision.id) == nil)
        #expect(try dao.capture(id: fixture.capture.id)?.currentRevisionID == nil)

        let installedCapture = try #require(try dao.capture(id: fixture.capture.id))
        let source = try ArticleWorkshopFileStore(root: fixture.managedDirectory)
            .loadSnapshot(for: installedCapture)
        let validRecipe = ArticleEditRecipe()
        let clean = try ArticleRevisionService().apply(
            snapshot: source,
            recipe: validRecipe)
        let missingParent = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000221",
            captureID: fixture.capture.id,
            parentRevisionID: "00000000-0000-0000-0000-000000000229",
            metadataOverridesJSON: String(
                decoding: try encoder.encode(validRecipe.metadataOverrides),
                as: UTF8.self),
            recipeJSON: String(
                decoding: try encoder.encode(validRecipe),
                as: UTF8.self),
            readableContentSHA256: clean.readableContentSHA256,
            createdAt: "2026-07-29T12:00:01Z",
            deviceName: nil)
        let missingParentRecord = try fixture.codec.revisionRecord(missingParent)
        #expect(throws: (any Error).self) {
            try applier.apply(modifications: [missingParentRecord], deletions: [])
        }
        #expect(try dao.revision(id: missingParent.id) == nil)
        #expect(try dao.capture(id: fixture.capture.id)?.currentRevisionID == nil)

        var foreignCapture = fixture.capture
        foreignCapture.id = "00000000-0000-0000-0000-000000000228"
        foreignCapture.currentRevisionID = nil
        let captureDAO = ArticleCaptureDAO(db: database.writer)
        try captureDAO.saveCapture(foreignCapture)
        let foreignParent = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000227",
            captureID: foreignCapture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: String(
                decoding: try encoder.encode(validRecipe.metadataOverrides),
                as: UTF8.self),
            recipeJSON: String(
                decoding: try encoder.encode(validRecipe),
                as: UTF8.self),
            readableContentSHA256: clean.readableContentSHA256,
            createdAt: "2026-07-29T12:00:02Z",
            deviceName: nil)
        try captureDAO.saveRevision(foreignParent, makeCurrent: false)
        var crossCaptureChild = missingParent
        crossCaptureChild.id = "00000000-0000-0000-0000-000000000226"
        crossCaptureChild.parentRevisionID = foreignParent.id
        let crossCaptureRecord = try fixture.codec.revisionRecord(crossCaptureChild)

        #expect(throws: (any Error).self) {
            try applier.apply(modifications: [crossCaptureRecord], deletions: [])
        }
        #expect(try dao.revision(id: crossCaptureChild.id) == nil)
        #expect(try dao.capture(id: fixture.capture.id)?.currentRevisionID == nil)

        let validRevision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000225",
            captureID: fixture.capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: String(
                decoding: try encoder.encode(validRecipe.metadataOverrides),
                as: UTF8.self),
            recipeJSON: String(
                decoding: try encoder.encode(validRecipe),
                as: UTF8.self),
            readableContentSHA256: clean.readableContentSHA256,
            createdAt: "2026-07-29T12:00:03Z",
            deviceName: nil)
        let validRecord = try fixture.codec.revisionRecord(validRevision)
        try applier.apply(modifications: [validRecord], deletions: [])
        try applier.apply(modifications: [validRecord], deletions: [])
        #expect(try dao.revision(id: validRevision.id) == validRevision)
        #expect(try dao.capture(id: fixture.capture.id)?.currentRevisionID == validRevision.id)
        let receiptBeforeCollision = try #require(
            try dao.cloudRecord(recordName: validRecord.recordID.recordName))

        var conflictingRevision = validRevision
        conflictingRevision.deviceName = "Different remote device"
        let conflictingRecord = try fixture.codec.revisionRecord(conflictingRevision)
        let unrelatedAnthology = cloudAnthologyManifest(
            id: "00000000-0000-0000-0000-000000000219",
            title: "Must roll back",
            modifiedAt: "2026-07-29T12:00:04Z")
        let unrelatedRecord = try fixture.codec.anthologyRecord(
            unrelatedAnthology,
            coverURL: nil)
        #expect(throws: (any Error).self) {
            try applier.apply(
                modifications: [conflictingRecord, unrelatedRecord],
                deletions: [])
        }
        #expect(try dao.revision(id: validRevision.id) == validRevision)
        #expect(try dao.capture(id: fixture.capture.id)?.currentRevisionID == validRevision.id)
        #expect(
            try dao.cloudRecord(recordName: validRecord.recordID.recordName)
                == receiptBeforeCollision)
        #expect(try dao.anthologyManifest(id: unrelatedAnthology.anthology.id) == nil)
    }

    @Test func anthologyRecordOmitsLocalCoverPathAndGeneratedBuildState() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let anthologyID = "00000000-0000-0000-0000-000000000210"
        let manifest = ArticleCloudAnthologyManifest(
            schemaVersion: 1,
            anthology: AnthologyRecord(
                id: anthologyID,
                title: "Private reading list",
                subtitle: nil,
                creator: nil,
                coverPath: "/private/local/cover.png",
                nextStableSlot: 0,
                latestBuildRevision: 42,
                createdAt: "2026-07-29T12:00:00Z",
                modifiedAt: "2026-07-29T12:00:00Z"),
            entries: [])

        let record = try fixture.codec.anthologyRecord(manifest, coverURL: nil)
        let json = try #require(record["manifestJSON"] as? String)

        #expect(json.contains("/private/local") == false)
        #expect(json.contains("cover_path") == false)
        #expect(json.contains("latest_build_revision") == false)
        // Stable slots are authoring state: retaining the next value prevents
        // removed chapter positions from being reused after cross-device edits.
        #expect(json.contains(#""next_stable_slot":0"#))
        #expect(record["generatedEPUB"] == nil)
        #expect(record["narration"] == nil)
        #expect(record["m4b"] == nil)
    }

    @MainActor
    @Test func sameManifestRemoteCoverUpdatesOriginalAnthology() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.managedDirectory,
            withIntermediateDirectories: true)
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let local = cloudAnthologyManifest(
            title: "Same manifest",
            modifiedAt: "2026-07-29T12:00:00Z")
        try insertAnthology(local, into: database)
        let coverURL = fixture.root.appending(path: "same-manifest.png")
        try cloudCoverPNGData().write(to: coverURL)
        let record = try fixture.codec.anthologyRecord(local, coverURL: coverURL)
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)

        try applier.apply(modifications: [record], deletions: [])

        let stored = try #require(try dao.anthologyManifest(id: local.anthology.id))
        let coverPath = try #require(stored.anthology.coverPath)
        let cover = fixture.managedDirectory
            .appending(path: "Anthologies", directoryHint: .isDirectory)
            .appending(path: local.anthology.id, directoryHint: .isDirectory)
            .appending(path: coverPath)
        #expect(FileManager.default.fileExists(atPath: cover.path))
    }

    @MainActor
    @Test func oneSidedRemoteManifestAndCoverUpdateUsesOriginalAnthology() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.managedDirectory,
            withIntermediateDirectories: true)
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        var local = cloudAnthologyManifest(
            title: "Old title",
            modifiedAt: "2026-07-29T12:00:00Z")
        local.anthology.latestBuildRevision = 7
        try insertAnthology(local, into: database)
        let incoming = cloudAnthologyManifest(
            title: "Remote title",
            modifiedAt: "2026-07-29T12:00:01Z")
        let coverURL = fixture.root.appending(path: "one-sided.png")
        try cloudCoverPNGData().write(to: coverURL)
        let record = try fixture.codec.anthologyRecord(incoming, coverURL: coverURL)
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)

        try applier.apply(modifications: [record], deletions: [])

        let stored = try #require(try dao.anthologyManifest(id: local.anthology.id))
        let coverPath = try #require(stored.anthology.coverPath)
        #expect(stored.anthology.title == "Remote title")
        #expect(stored.anthology.latestBuildRevision == 7)
        let anthologyRoot = fixture.managedDirectory
            .appending(path: "Anthologies", directoryHint: .isDirectory)
        #expect(
            FileManager.default.fileExists(
                atPath:
                    anthologyRoot
                    .appending(path: local.anthology.id, directoryHint: .isDirectory)
                    .appending(path: coverPath).path))
        #expect(
            (try FileManager.default.contentsOfDirectory(atPath: anthologyRoot.path))
                == [local.anthology.id])
    }

    @MainActor
    @Test func concurrentRemoteCoverIsReferencedByStableRecoveredAnthology() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.managedDirectory,
            withIntermediateDirectories: true)
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let base = cloudAnthologyManifest(
            title: "Shared title",
            modifiedAt: "2026-07-29T12:00:00Z")
        try insertAnthology(base, into: database)
        let baseRecord = try fixture.codec.anthologyRecord(base, coverURL: nil)
        try dao.storeFetchedCloudRecord(
            recordName: baseRecord.recordID.recordName,
            recordType: .anthology,
            entityID: base.anthology.id,
            systemFields: Data("base-fields".utf8),
            contentFingerprint: try fixture.codec.contentFingerprint(for: baseRecord),
            updatedAt: "2026-07-29T12:00:00Z")
        try database.write { db in
            try db.execute(
                sql: "UPDATE anthology SET title = ?, modified_at = ? WHERE id = ?",
                arguments: [
                    "Local edit",
                    "2026-07-29T12:00:01Z",
                    base.anthology.id,
                ])
        }
        _ = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: baseRecord.recordID.recordName,
                recordType: .anthology,
                entityID: base.anthology.id,
                operation: .save,
                queuedAt: "2026-07-29T12:00:01Z"))
        let incoming = cloudAnthologyManifest(
            title: "Remote edit",
            modifiedAt: "2026-07-29T12:00:02Z")
        let local = try #require(try dao.anthologyManifest(id: base.anthology.id))
        let recoveredID = ArticleSyncConflictIdentity.recoveredAnthologyID(
            incoming: incoming,
            existing: local)
        let coverURL = fixture.root.appending(path: "conflict.png")
        try cloudCoverPNGData().write(to: coverURL)
        let record = try fixture.codec.anthologyRecord(incoming, coverURL: coverURL)
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)

        try applier.apply(modifications: [record], deletions: [])

        #expect(
            try dao.anthologyManifest(id: base.anthology.id)?.anthology.title
                == "Local edit")
        let recovered = try #require(
            try dao.anthologyManifest(id: recoveredID.uuidString))
        let coverPath = try #require(recovered.anthology.coverPath)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.managedDirectory
                    .appending(path: "Anthologies", directoryHint: .isDirectory)
                    .appending(path: recoveredID.uuidString, directoryHint: .isDirectory)
                    .appending(path: coverPath).path))
    }

    @MainActor
    @Test func anthologyStateChangeBeforeCommitFailsClosedAndRemovesNewCover() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.managedDirectory,
            withIntermediateDirectories: true)
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let local = cloudAnthologyManifest(
            title: "Original",
            modifiedAt: "2026-07-29T12:00:00Z")
        try insertAnthology(local, into: database)
        let incoming = cloudAnthologyManifest(
            title: "Incoming",
            modifiedAt: "2026-07-29T12:00:01Z")
        let intervening = cloudAnthologyManifest(
            title: "Intervening",
            modifiedAt: "2026-07-29T12:00:02Z")
        let coverData = cloudCoverPNGData()
        let coverURL = fixture.root.appending(path: "state-change.png")
        try coverData.write(to: coverURL)
        let record = try fixture.codec.anthologyRecord(incoming, coverURL: coverURL)
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory,
            beforeDatabaseCommit: {
                try dao.applyFetchedChanges([.anthology(intervening)])
            })

        #expect(throws: (any Error).self) {
            try applier.apply(modifications: [record], deletions: [])
        }

        #expect(
            try dao.anthologyManifest(id: local.anthology.id)?.anthology.title
                == "Intervening")
        let coverName =
            "cover-"
            + SHA256.hash(data: coverData).map { String(format: "%02x", $0) }.joined()
            + ".png"
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.managedDirectory
                    .appending(path: "Anthologies", directoryHint: .isDirectory)
                    .appending(path: local.anthology.id, directoryHint: .isDirectory)
                    .appending(path: coverName).path) == false)
    }

    @Test func capturePackageRequiresRealMatchingEnvelopeAndSanitizerSemantics() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        _ = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)

        for invalidData in [
            Data(#"{"schemaVersion":2}"#.utf8),
            Data(
                #"""
                {"schemaVersion":1,"captureID":"00000000-0000-0000-0000-000000000299"}
                """#.utf8),
            Data(#"{"payload":{"contentXHTML":"<p>body</p>"}}"#.utf8),
        ] {
            try invalidData.write(
                to: fixture.packageDirectory.appending(path: "snapshot.json"),
                options: .atomic)
            var invalidCapture = fixture.capture
            invalidCapture.contentSHA256 = SHA256.hash(data: invalidData)
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                _ = try fixture.codec.captureRecord(
                    invalidCapture,
                    packageDirectory: fixture.packageDirectory)
            }
        }
    }

    @Test func cloudCaptureScalarsMustMatchAuthoritativeSnapshot() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let record = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        record["title"] = "Mutated cloud title" as CKRecordValue
        let decoded = try fixture.codec.decode(
            record,
            assetCopyDirectory: fixture.incomingDirectory)
        let payload: ArticleCloudCapturePayload
        guard case .capture(let capturePayload) = decoded else {
            Issue.record("Expected a capture payload")
            return
        }
        payload = capturePayload

        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.installCapturePackage(
                payload,
                workshopRootDirectory: fixture.managedDirectory)
        }
    }

    @Test func archiveEntryAndPathBoundsIncludeDirectories() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let archiveURL = fixture.root.appending(path: "directory-dos.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let empty = Data()
        for index in 0...(ArticleWorkshopLimits.maxImages + 2) {
            try archive.addEntry(
                with: "d\(index)/",
                type: .directory,
                uncompressedSize: 0,
                compressionMethod: .none
            ) { (_: Int64, _: Int) -> Data in empty }
        }
        try archive.addEntry(
            with: "snapshot.json",
            type: .file,
            uncompressedSize: 2,
            compressionMethod: .none
        ) { (position: Int64, size: Int) -> Data in
            Data("{}".utf8).subdata(in: Int(position)..<min(Int(position) + size, 2))
        }

        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            try fixture.codec.validateCaptureArchive(at: archiveURL)
        }
    }
}

private enum InjectedApplyFailure: Swift.Error {
    case failed
}

private func cloudAnthologyManifest(
    id: String = "00000000-0000-0000-0000-000000000210",
    title: String,
    modifiedAt: String
) -> ArticleCloudAnthologyManifest {
    ArticleCloudAnthologyManifest(
        schemaVersion: 1,
        anthology: AnthologyRecord(
            id: id,
            title: title,
            subtitle: nil,
            creator: nil,
            coverPath: nil,
            nextStableSlot: 0,
            latestBuildRevision: 0,
            createdAt: "2026-07-29T12:00:00Z",
            modifiedAt: modifiedAt),
        entries: [])
}

@MainActor
private func insertAnthology(
    _ manifest: ArticleCloudAnthologyManifest,
    into database: DatabaseService
) throws {
    try database.write { db in
        var anthology = manifest.anthology
        try anthology.insert(db)
    }
}

private func cloudCoverPNGData() -> Data {
    Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURTNmmf////ENxh0AAAABYktHRAH/Ai3eAAAAB3RJTUUH6gcdBwQUEKHG6gAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNy0yOVQwNzowNDoyMCswMDowMAupiH8AAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDctMjlUMDc6MDQ6MjArMDA6MDB69DDDAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA3LTI5VDA3OjA0OjIwKzAwOjAwLeERHAAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAASUVORK5CYII="
    )!
}

private struct ArticleCloudCodecFixture {
    let root: URL
    let packageDirectory: URL
    let incomingDirectory: URL
    let managedDirectory: URL
    let codec: ArticleCloudRecordCodec
    let capture: ArticleCaptureRecord

    init(
        limits: ArticleCloudRecordCodec.Limits = .production,
        sourceURL: String = "https://example.test/source"
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ArticleCloudRecordCodecTests-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        packageDirectory = root.appending(path: "Package", directoryHint: .isDirectory)
        incomingDirectory = root.appending(path: "Incoming", directoryHint: .isDirectory)
        managedDirectory = root.appending(path: "Managed", directoryHint: .isDirectory)
        let outgoing = root.appending(path: "Outgoing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: packageDirectory,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: incomingDirectory,
            withIntermediateDirectories: true)
        let captureID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000201"))
        let capturedAt = Date(timeIntervalSince1970: 1_721_736_060)
        let envelope = ArticleCaptureEnvelope(
            schemaVersion: 1,
            captureID: captureID,
            capturedAt: capturedAt,
            method: .urlFetch,
            sourceApplication: nil,
            payload: ReadabilityCapturePayload(
                sourceURL: sourceURL,
                canonicalURL: "https://example.test/canonical",
                title: "Private article",
                byline: "A. Reader",
                siteName: "Example",
                language: "en",
                publishedTime: "2026-07-28T12:00:00Z",
                excerpt: "Private body",
                contentXHTML:
                    #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>private body</p></body></html>"#,
                textContent: "private body",
                imageURLs: []))
        let snapshotData = try JSONEncoder.articleWorkshop.encode(envelope)
        try snapshotData.write(to: packageDirectory.appending(path: "snapshot.json"))
        codec = ArticleCloudRecordCodec(
            temporaryDirectory: outgoing,
            limits: limits)
        capture = ArticleCaptureRecord(
            id: "00000000-0000-0000-0000-000000000201",
            sourceURL: sourceURL,
            canonicalURL: "https://example.test/canonical",
            title: "Private article",
            author: "A. Reader",
            siteName: "Example",
            language: "en",
            publishedAt: "2026-07-28T12:00:00Z",
            capturedAt: capturedAt.ISO8601Format(),
            captureMethod: .urlFetch,
            packagePath: packageDirectory.path,
            contentSHA256: SHA256.hash(data: snapshotData)
                .map { String(format: "%02x", $0) }
                .joined(),
            extractorVersion: "schema-1",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: "2026-07-28T12:01:00Z",
            modifiedAt: "2026-07-28T12:01:00Z")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
