// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import CryptoKit
import Foundation
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
            recipeJSON: "{\"trimAfterBlockID\":\"z\",\"excludedBlockIDs\":[\"b\",\"a\"]}",
            readableContentSHA256: String(repeating: "b", count: 64),
            createdAt: "2026-07-29T12:00:00Z",
            deviceName: "Test device")

        let encoded = try fixture.codec.revisionRecord(revision)
        #expect(
            encoded["metadataOverridesJSON"] as? String
                == "{\"author\":\"Reader\",\"title\":\"Edited\"}")
        #expect(
            encoded["recipeJSON"] as? String
                == "{\"excludedBlockIDs\":[\"b\",\"a\"],\"trimAfterBlockID\":\"z\"}")

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
    }

    @MainActor
    @Test func fetchedCaptureIsInstalledAndCommittedBeforeBatchApplyReturns() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
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
}

private struct ArticleCloudCodecFixture {
    let root: URL
    let packageDirectory: URL
    let incomingDirectory: URL
    let managedDirectory: URL
    let codec: ArticleCloudRecordCodec
    let capture: ArticleCaptureRecord

    init(limits: ArticleCloudRecordCodec.Limits = .production) throws {
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
        let snapshotData = Data(
            """
            {"payload":{"contentXHTML":"<p>private body</p>","textContent":"private body"}}
            """.utf8
        )
        try snapshotData.write(to: packageDirectory.appending(path: "snapshot.json"))
        codec = ArticleCloudRecordCodec(
            temporaryDirectory: outgoing,
            limits: limits)
        capture = ArticleCaptureRecord(
            id: "00000000-0000-0000-0000-000000000201",
            sourceURL: "https://example.test/source",
            canonicalURL: "https://example.test/canonical",
            title: "Private article",
            author: "A. Reader",
            siteName: "Example",
            language: "en",
            publishedAt: "2026-07-28T12:00:00Z",
            capturedAt: "2026-07-28T12:01:00Z",
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
