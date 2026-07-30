// SPDX-License-Identifier: GPL-3.0-or-later
import CloudKit
import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
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
            "https://example.test/article?authToken=private",
            "https://example.test/article?sessionToken=private",
            "https://example.test/article?%2561uth%2554oken=private",
            "https://example.test/article?%252561uth%252554oken=private",
            "https://example.test/article?redirect=https%253A%252F%252Freader%253Ahunter2%2540example.test%252Fprivate",
            "https://example.test/article?redirect=https%3A%2F%2Freader%3Ahunter2%40example.test%2Fprivate",
            "https://example.test/article?redirect=https%3A%2F%2Fexample.test%2Fprivate%3FrefreshToken%3Dprivate",
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

    @Test func snapshotXHTMLCredentialURLsFailUploadAndInstall() throws {
        let credentialAttributes = [
            #"<a href="https://example.test/?auth%2554oken=private">body</a>"#,
            #"<img srcset="https://example.test/safe.png 1x, https://reader:secret@example.test/private.png 2x" />"#,
            #"<form action="https://example.test/?refresh%2554oken=private"><p>body</p></form>"#,
            #"<div style="background:url(https://reader:secret@example.test/private.png)">body</div>"#,
            #"<img src="data:image/png;base64,cHJpdmF0ZQ==" />"#,
            #"<a href="/article#auth%2554oken=private">body</a>"#,
        ]
        for attribute in credentialAttributes {
            let fixture = try ArticleCloudCodecFixture(
                contentXHTML:
                    #"<html xmlns="http://www.w3.org/1999/xhtml"><body>\#(attribute)</body></html>"#
            )
            defer { fixture.remove() }

            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                _ = try fixture.codec.captureRecord(
                    fixture.capture,
                    packageDirectory: fixture.packageDirectory)
            }

            let snapshotURL = fixture.packageDirectory.appending(path: "snapshot.json")
            let archiveURL = fixture.root.appending(path: "credential-snapshot.zip")
            try makeCaptureArchive(
                at: archiveURL,
                members: [("snapshot.json", try Data(contentsOf: snapshotURL))])
            let payload = ArticleCloudCapturePayload(
                capture: fixture.capture,
                packageArchiveURL: archiveURL,
                packageAssets: [])
            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                _ = try fixture.codec.installCapturePackage(
                    payload,
                    workshopRootDirectory: fixture.managedDirectory)
            }
        }
    }

    @Test func snapshotImageURLsRejectCredentialsOnUploadAndInstall() throws {
        for imageURL in [
            "https://reader:secret@example.test/private.png",
            "https://example.test/private.png?authToken=private",
            "https://example.test/private.png?next=https%253A%252F%252Freader%253Asecret%2540example.test%252Fimage.png",
            "https://example.test/private.png#https%253A%252F%252Freader%253Asecret%2540example.test%252Fimage.png",
        ] {
            let fixture = try ArticleCloudCodecFixture(imageURLs: [imageURL])
            defer { fixture.remove() }
            try expectCaptureRejectedForUploadAndInstall(fixture)
        }
    }

    @Test func snapshotURLAttributesRejectMultiValueCSSLegacyAndMalformedBypasses() throws {
        let bypasses = [
            #"<a ping="https://example.test/safe https://reader:secret@example.test/private">body</a>"#,
            #"<img imagesrcset="https://example.test/safe.png 1x, https://reader:secret@example.test/private.png 2x" />"#,
            #"<img srcset="/safe.png,https://reader:secret@example.test/private.png" />"#,
            #"<div style="background-image:image-set(&quot;https://example.test/safe.png&quot; 1x, &quot;https://reader:secret@example.test/private.png&quot; 2x)">body</div>"#,
            #"<style>body { background-image: url(https://reader:secret@example.test/private.png); }</style>"#,
            #"<style><![CDATA[body { background-image: url(https://reader:secret@example.test/private.png); }]]></style>"#,
            #"<h:style xmlns:h="http://www.w3.org/1999/xhtml">body { background-image: url(https://reader:secret@example.test/private.png); }</h:style>"#,
            #"<a href="/article#https%253A%252F%252Freader%253Asecret%2540example.test%252Fprivate">body</a>"#,
            #"<div manifest="https://reader:secret@example.test/private">body</div>"#,
            #"<div profile="https://reader:secret@example.test/private">body</div>"#,
            #"<div usemap="https://reader:secret@example.test/private">body</div>"#,
            #"<div codebase="https://reader:secret@example.test/private">body</div>"#,
            #"<div classid="https://reader:secret@example.test/private">body</div>"#,
            #"<div dynsrc="https://reader:secret@example.test/private">body</div>"#,
            #"<div lowsrc="https://reader:secret@example.test/private">body</div>"#,
            #"<div xml:base="https://reader:secret@example.test/private">body</div>"#,
            #"<div itemid="https://reader:secret@example.test/private">body</div>"#,
            #"<div resource="https://reader:secret@example.test/private">body</div>"#,
            #"<div about="https://reader:secret@example.test/private">body</div>"#,
            #"<div icon="https://reader:secret@example.test/private">body</div>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="https://reader:secret@example.test/private" /></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><path clip-path="url(https://reader:secret@example.test/private)" /></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><path cursor="url(https://reader:secret@example.test/private)" /></svg>"#,
            #"<div style="background:u\72l(https://reader:secret@example.test/private)">body</div>"#,
            #"<meta http-equiv="refresh" content="0;url=https://reader:secret@example.test/private" />"#,
            #"<h:meta xmlns:h="http://www.w3.org/1999/xhtml" http-equiv="refresh" content="0;url=https://reader:secret@example.test/private" />"#,
            #"<?xml-stylesheet type="text/css" href="https://reader:secret@example.test/private.css"?>"#,
            #"<div style="background-image:image-set(private.png 1x)">body</div>"#,
            #"<a ping="https://example.test/safe https://[malformed">body</a>"#,
        ]
        for body in bypasses {
            let fixture = try ArticleCloudCodecFixture(
                contentXHTML:
                    #"<html xmlns="http://www.w3.org/1999/xhtml"><body>\#(body)</body></html>"#
            )
            defer { fixture.remove() }
            try expectCaptureRejectedForUploadAndInstall(fixture)
        }
    }

    @Test func snapshotURLScannerAllowsNormalRelativeProducerXHTML() throws {
        let fixture = try ArticleCloudCodecFixture(
            contentXHTML:
                #"""
                <html xmlns="http://www.w3.org/1999/xhtml"><body>
                <p><a href="/article#section-2" ping="/audit-one /audit-two">body</a></p>
                <img src="/image.png" srcset="/image.png?crop=1,2 1x, /image-2x.png 2x" />
                <div style="background-image:image-set(url('/image.png') 1x, &quot;/image-2x.png&quot; 2x)"><p>body</p></div>
                <style>body { background-image: url('/image.png'); }</style>
                </body></html>
                """#
        )
        defer { fixture.remove() }

        _ = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
    }

    @Test func unknownSnapshotEnvelopeAndPayloadFieldsFailClosed() throws {
        for insertion in [
            #"{"unknownRoot":"must-not-persist","#,
            #"{"unknownPayload":"must-not-persist","#,
        ].enumerated() {
            let fixture = try ArticleCloudCodecFixture()
            defer { fixture.remove() }
            let snapshotURL = fixture.packageDirectory.appending(path: "snapshot.json")
            let original = try String(
                decoding: Data(contentsOf: snapshotURL),
                as: UTF8.self)
            let mutated: String
            if insertion.offset == 0 {
                mutated = insertion.element + original.dropFirst()
            } else {
                mutated = original.replacingOccurrences(
                    of: #""payload":{"#,
                    with: #""payload":\#(insertion.element)"#)
            }
            let data = Data(mutated.utf8)
            try data.write(to: snapshotURL, options: .atomic)
            var capture = fixture.capture
            capture.contentSHA256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()

            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                _ = try fixture.codec.captureRecord(
                    capture,
                    packageDirectory: fixture.packageDirectory)
            }
        }
    }

    @Test func duplicateKnownSnapshotKeysFailClosed() throws {
        for payloadDuplicate in [false, true] {
            let fixture = try ArticleCloudCodecFixture()
            defer { fixture.remove() }
            let snapshotURL = fixture.packageDirectory.appending(path: "snapshot.json")
            let original = try String(
                decoding: Data(contentsOf: snapshotURL),
                as: UTF8.self)
            let mutated: String
            if payloadDuplicate {
                mutated = original.replacingOccurrences(
                    of: #""payload":{"#,
                    with: #""payload":{"title":"hidden","#)
            } else {
                mutated = #"{"schemaVersion":999,"# + original.dropFirst()
            }
            let data = Data(mutated.utf8)
            try data.write(to: snapshotURL, options: .atomic)
            var capture = fixture.capture
            capture.contentSHA256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()

            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                _ = try fixture.codec.captureRecord(
                    capture,
                    packageDirectory: fixture.packageDirectory)
            }
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

    @Test func inboundCloudJSONRejectsDuplicateKnownKeysBeforeCanonicalization() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }

        let imageData = cloudCoverPNGData()
        try imageData.write(
            to: fixture.packageDirectory.appending(path: "image-0.png"))
        let captureRecord = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        let packageAssetsJSON = try #require(
            captureRecord["packageAssetsJSON"] as? String)
        captureRecord["packageAssetsJSON"] =
            packageAssetsJSON.replacingOccurrences(
                of: #""mediaType":"image/png""#,
                with: #""mediaType":"image/png","mediaType":"image/png""#)
            as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                captureRecord,
                assetCopyDirectory: fixture.incomingDirectory)
        }

        let revision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000202",
            captureID: fixture.capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: #"{"title":"Edited"}"#,
            recipeJSON:
                #"{"excludedBlockIDs":[],"metadataOverrides":{"title":"Edited"}}"#,
            readableContentSHA256: String(repeating: "b", count: 64),
            createdAt: "2026-07-29T12:00:00Z",
            deviceName: nil)
        let duplicateMetadata = try fixture.codec.revisionRecord(revision)
        duplicateMetadata["metadataOverridesJSON"] =
            #"{"title":"Edited","title":"Edited"}"# as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                duplicateMetadata,
                assetCopyDirectory: fixture.incomingDirectory)
        }
        let duplicateRecipe = try fixture.codec.revisionRecord(revision)
        duplicateRecipe["recipeJSON"] =
            #"{"excludedBlockIDs":[],"excludedBlockIDs":[],"metadataOverrides":{"title":"Edited"}}"#
            as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                duplicateRecipe,
                assetCopyDirectory: fixture.incomingDirectory)
        }

        let manifest = cloudAnthologyManifest(
            title: "Duplicate JSON",
            modifiedAt: "2026-07-29T12:00:00Z")
        let anthologyRecord = try fixture.codec.anthologyRecord(
            manifest,
            coverURL: nil)
        let manifestJSON = try #require(
            anthologyRecord["manifestJSON"] as? String)
        anthologyRecord["manifestJSON"] =
            manifestJSON.replacingOccurrences(
                of: #""schemaVersion":1"#,
                with: #""schemaVersion":1,"schemaVersion":1"#)
            as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                anthologyRecord,
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
    @Test func guardedFetchedCaptureCannotInstallOrCommit() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        try dao.quarantineActiveAccountOwner(
            reason: "zoneResetOrPurge",
            updatedAt: "2026-07-29T12:00:01Z")
        let record = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)

        #expect(throws: ArticleSyncDAO.Error.accountOwnerQuarantined) {
            try applier.apply(modifications: [record], deletions: [])
        }

        #expect(try dao.capture(id: fixture.capture.id) == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.managedDirectory
                    .appending(path: "Captures", directoryHint: .isDirectory)
                    .appending(path: fixture.capture.id, directoryHint: .isDirectory)
                    .path) == false)
    }

    @MainActor
    @Test func quarantineDuringFetchedCaptureApplyRollsBackFilesAndDatabase() throws {
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
            incomingDirectory: fixture.incomingDirectory,
            beforeDatabaseCommit: {
                try dao.quarantineActiveAccountOwner(
                    reason: "encryptedDataReset",
                    updatedAt: "2026-07-29T12:00:01Z")
            })

        #expect(throws: ArticleSyncDAO.Error.accountOwnerQuarantined) {
            try applier.apply(modifications: [record], deletions: [])
        }

        #expect(try dao.capture(id: fixture.capture.id) == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.managedDirectory
                    .appending(path: "Captures", directoryHint: .isDirectory)
                    .appending(path: fixture.capture.id, directoryHint: .isDirectory)
                    .path) == false)
    }

    @MainActor
    @Test func pendingDeleteTombstonesPreventFetchedEntityResurrection() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let revision = ArticleRevisionRecord(
            id: "00000000-0000-0000-0000-000000000202",
            captureID: fixture.capture.id,
            parentRevisionID: nil,
            metadataOverridesJSON: "{}",
            recipeJSON: #"{"excludedBlockIDs":[],"metadataOverrides":{}}"#,
            readableContentSHA256: String(repeating: "a", count: 64),
            createdAt: "2026-07-29T12:00:00Z",
            deviceName: nil)
        let anthology = cloudAnthologyManifest(
            title: "Deleted locally",
            modifiedAt: "2026-07-29T12:00:00Z")
        let identities: [(CKRecord, ArticleCloudRecordType, String)] = [
            (
                try fixture.codec.captureRecord(
                    fixture.capture,
                    packageDirectory: fixture.packageDirectory),
                .capture,
                fixture.capture.id
            ),
            (
                try fixture.codec.revisionRecord(revision),
                .revision,
                revision.id
            ),
            (
                try fixture.codec.anthologyRecord(anthology, coverURL: nil),
                .anthology,
                anthology.anthology.id
            ),
        ]
        var tombstones: [ArticlePendingCloudChange] = []
        for (record, type, entityID) in identities {
            tombstones.append(
                try dao.enqueueReturning(
                    ArticlePendingCloudChange(
                        recordName: record.recordID.recordName,
                        recordType: type,
                        entityID: entityID,
                        operation: .delete,
                        queuedAt: "2026-07-29T12:00:01Z")))
        }
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)

        try applier.apply(modifications: identities.map(\.0), deletions: [])

        #expect(try dao.capture(id: fixture.capture.id) == nil)
        #expect(try dao.revision(id: revision.id) == nil)
        #expect(try dao.anthologyManifest(id: anthology.anthology.id) == nil)
        #expect(try Set(dao.pendingChanges()) == Set(tombstones))
        try dao.acknowledgeDeleted(
            tombstones.map {
                ArticleCloudDeleteAcknowledgement(
                    recordName: $0.recordName,
                    generation: $0.generation)
            })
        #expect(try dao.pendingChanges().isEmpty)
        #expect(try dao.capture(id: fixture.capture.id) == nil)
        #expect(try dao.revision(id: revision.id) == nil)
        #expect(try dao.anthologyManifest(id: anthology.anthology.id) == nil)
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
            let capturesRoot = fixture.managedDirectory
                .appending(path: "Captures", directoryHint: .isDirectory)
            let installed =
                capturesRoot
                .appending(path: fixture.capture.id, directoryHint: .isDirectory)
            #expect(FileManager.default.fileExists(atPath: installed.path) == false)
            #expect(FileManager.default.fileExists(atPath: capturesRoot.path) == false)
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
    @Test func fetchedDatabaseFailureRemovesOnlyNewManagedCoverDirectories() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.managedDirectory,
            withIntermediateDirectories: true)
        let anthologiesRoot = fixture.managedDirectory
            .appending(path: "Anthologies", directoryHint: .isDirectory)
        let incoming = cloudAnthologyManifest(
            title: "Remote anthology",
            modifiedAt: "2026-07-29T12:00:01Z")
        let anthologyDirectory =
            anthologiesRoot
            .appending(path: incoming.anthology.id, directoryHint: .isDirectory)
        let firstCoverURL = fixture.root.appending(path: "reclaimed-cover.png")
        try cloudCoverPNGData().write(to: firstCoverURL)

        // A fetched transaction that fails after the cover is materialized must
        // leave no managed directory behind: nothing durable references it.
        do {
            let database = try DatabaseService(inMemory: ())
            let dao = ArticleSyncDAO(db: database.writer)
            try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
            let record = try fixture.codec.anthologyRecord(
                incoming,
                coverURL: firstCoverURL)
            let applier = ArticleFetchedCloudBatchApplier(
                syncDAO: dao,
                codec: fixture.codec,
                workshopRootDirectory: fixture.managedDirectory,
                incomingDirectory: fixture.incomingDirectory,
                beforeDatabaseCommit: { throw InjectedApplyFailure.failed })

            #expect(throws: InjectedApplyFailure.failed) {
                try applier.apply(modifications: [record], deletions: [])
            }

            #expect(try dao.anthologyManifest(id: incoming.anthology.id) == nil)
            #expect(
                FileManager.default.fileExists(atPath: anthologyDirectory.path) == false)
            #expect(
                FileManager.default.fileExists(atPath: anthologiesRoot.path) == false)
        }

        // A directory that already held a durable cover must survive the next
        // failed transaction; only the newly written cover is reclaimed.
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        let cleanApplier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)
        try cleanApplier.apply(
            modifications: [
                try fixture.codec.anthologyRecord(incoming, coverURL: firstCoverURL)
            ],
            deletions: [])
        let stored = try #require(try dao.anthologyManifest(id: incoming.anthology.id))
        let durableCoverPath = try #require(stored.anthology.coverPath)
        let durableCover = anthologyDirectory.appending(path: durableCoverPath)
        #expect(FileManager.default.fileExists(atPath: durableCover.path))

        let replacement = cloudAnthologyManifest(
            title: "Later remote anthology",
            modifiedAt: "2026-07-29T12:00:02Z")
        let secondCoverURL = fixture.root.appending(path: "reclaimed-cover-2.png")
        try generatedCloudCoverPNGData(width: 2).write(to: secondCoverURL)
        let failingApplier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory,
            beforeDatabaseCommit: { throw InjectedApplyFailure.failed })
        #expect(throws: InjectedApplyFailure.failed) {
            try failingApplier.apply(
                modifications: [
                    try fixture.codec.anthologyRecord(
                        replacement,
                        coverURL: secondCoverURL)
                ],
                deletions: [])
        }

        #expect(FileManager.default.fileExists(atPath: anthologyDirectory.path))
        #expect(FileManager.default.fileExists(atPath: durableCover.path))
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: anthologyDirectory.path) == [durableCoverPath])
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

    @Test func anthologyCoverVersionPairsWithAssetAndEntersStableFingerprint() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let data = try generatedCloudCoverPNGData(width: 2)
        let coverURL = fixture.root.appending(path: "cover.png")
        try data.write(to: coverURL)
        let version = cloudCoverContentVersion(data)
        var manifest = cloudAnthologyManifest(
            title: "Cover identity",
            modifiedAt: "2026-07-29T12:00:00Z")
        manifest.coverContentVersion = version

        let record = try fixture.codec.anthologyRecord(
            manifest,
            coverURL: coverURL)
        let json = try #require(record["manifestJSON"] as? String)
        #expect(record["coverContentVersion"] as? String == version)
        #expect(json.contains("coverContentVersion") == false)
        #expect(
            try fixture.codec.contentFingerprint(for: record)
                == ArticleSyncFingerprint.anthology(manifest))

        let decoded = try fixture.codec.decode(
            record,
            assetCopyDirectory: fixture.incomingDirectory)
        guard case .anthology(let payload) = decoded else {
            Issue.record("Expected anthology")
            return
        }
        #expect(payload.manifest.coverContentVersion == version)

        record["coverContentVersion"] = nil
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                record,
                assetCopyDirectory: fixture.incomingDirectory)
        }
        record["coverContentVersion"] =
            "sha256:\(String(repeating: "0", count: 64))" as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                record,
                assetCopyDirectory: fixture.incomingDirectory)
        }
        record["cover"] = nil
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                record,
                assetCopyDirectory: fixture.incomingDirectory)
        }
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
        let baseRecord = try fixture.codec.anthologyRecord(local, coverURL: nil)
        try dao.storeFetchedCloudRecord(
            recordName: baseRecord.recordID.recordName,
            recordType: .anthology,
            entityID: local.anthology.id,
            systemFields: Data("same-manifest-base".utf8),
            contentFingerprint: try fixture.codec.contentFingerprint(for: baseRecord),
            updatedAt: "2026-07-29T12:00:00Z")
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
        let baseRecord = try fixture.codec.anthologyRecord(local, coverURL: nil)
        try dao.storeFetchedCloudRecord(
            recordName: baseRecord.recordID.recordName,
            recordType: .anthology,
            entityID: local.anthology.id,
            systemFields: Data("one-sided-base".utf8),
            contentFingerprint: try fixture.codec.contentFingerprint(for: baseRecord),
            updatedAt: "2026-07-29T12:00:00Z")
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
        var incoming = cloudAnthologyManifest(
            title: "Remote edit",
            modifiedAt: "2026-07-29T12:00:02Z")
        let coverData = cloudCoverPNGData()
        incoming.coverContentVersion = cloudCoverContentVersion(coverData)
        let local = try #require(try dao.anthologyManifest(id: base.anthology.id))
        let recoveredID = ArticleSyncConflictIdentity.recoveredAnthologyID(
            incoming: incoming,
            existing: local)
        let coverURL = fixture.root.appending(path: "conflict.png")
        try coverData.write(to: coverURL)
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
    @Test func concurrentCoverOnlyEditsPreserveLocalAndRecoveredCoverBytes() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.managedDirectory,
            withIntermediateDirectories: true)
        let anthologyID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000210"))
        let baseData = try generatedCloudCoverPNGData(width: 2)
        let localData = try generatedCloudCoverPNGData(width: 3)
        let remoteData = try generatedCloudCoverPNGData(width: 4)
        let baseSource = fixture.root.appending(path: "base.png")
        let localSource = fixture.root.appending(path: "local.png")
        let remoteSource = fixture.root.appending(path: "remote.png")
        try baseData.write(to: baseSource)
        try localData.write(to: localSource)
        try remoteData.write(to: remoteSource)
        let coverStore = AnthologyCoverStore(root: fixture.managedDirectory)
        let basePath = try coverStore.importCover(
            from: baseSource,
            anthologyID: anthologyID)
        let localPath = try coverStore.importCover(
            from: localSource,
            anthologyID: anthologyID)

        let database = try DatabaseService(inMemory: ())
        let dao = ArticleSyncDAO(db: database.writer)
        try dao.bindAccountOwner("account-A", updatedAt: "2026-07-29T12:00:00Z")
        var base = cloudAnthologyManifest(
            title: "Cover-only conflict",
            modifiedAt: "2026-07-29T12:00:00Z")
        base.anthology.coverPath = basePath
        base.coverContentVersion = cloudCoverContentVersion(baseData)
        try insertAnthology(base, into: database)
        let baseRecord = try fixture.codec.anthologyRecord(
            base,
            coverURL: baseSource)
        try dao.storeFetchedCloudRecord(
            recordName: baseRecord.recordID.recordName,
            recordType: .anthology,
            entityID: base.anthology.id,
            systemFields: Data("base-fields".utf8),
            contentFingerprint: try fixture.codec.contentFingerprint(for: baseRecord),
            updatedAt: "2026-07-29T12:00:00Z")
        try database.write { db in
            try db.execute(
                sql: "UPDATE anthology SET cover_path = ? WHERE id = ?",
                arguments: [localPath, base.anthology.id])
        }
        _ = try dao.enqueueReturning(
            ArticlePendingCloudChange(
                recordName: baseRecord.recordID.recordName,
                recordType: .anthology,
                entityID: base.anthology.id,
                operation: .save,
                queuedAt: "2026-07-29T12:00:01Z"))

        var incoming = cloudAnthologyManifest(
            title: "Cover-only conflict",
            modifiedAt: "2026-07-29T12:00:00Z")
        incoming.coverContentVersion = cloudCoverContentVersion(remoteData)
        let local = try #require(try dao.anthologyManifest(id: base.anthology.id))
        let recoveredID = ArticleSyncConflictIdentity.recoveredAnthologyID(
            incoming: incoming,
            existing: local)
        let record = try fixture.codec.anthologyRecord(
            incoming,
            coverURL: remoteSource)
        let applier = ArticleFetchedCloudBatchApplier(
            syncDAO: dao,
            codec: fixture.codec,
            workshopRootDirectory: fixture.managedDirectory,
            incomingDirectory: fixture.incomingDirectory)

        try applier.apply(modifications: [record], deletions: [])

        let original = try #require(
            try dao.anthologyManifest(id: anthologyID.uuidString))
        let recovered = try #require(
            try dao.anthologyManifest(id: recoveredID.uuidString))
        #expect(original.anthology.coverPath == localPath)
        let recoveredPath = try #require(recovered.anthology.coverPath)
        let anthologyRoot = fixture.managedDirectory.appending(
            path: "Anthologies",
            directoryHint: .isDirectory)
        #expect(
            try Data(
                contentsOf:
                    anthologyRoot
                    .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
                    .appending(path: localPath)) == localData)
        #expect(
            try Data(
                contentsOf:
                    anthologyRoot
                    .appending(path: recoveredID.uuidString, directoryHint: .isDirectory)
                    .appending(path: recoveredPath)) == remoteData)
        // Managed cover files are immutable because completed build manifests
        // may retain historical paths; Task 17 owns reference-aware reclamation.
        #expect(
            FileManager.default.fileExists(
                atPath:
                    anthologyRoot
                    .appending(path: anthologyID.uuidString, directoryHint: .isDirectory)
                    .appending(path: basePath).path))
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
        let baseRecord = try fixture.codec.anthologyRecord(local, coverURL: nil)
        try dao.storeFetchedCloudRecord(
            recordName: baseRecord.recordID.recordName,
            recordType: .anthology,
            entityID: local.anthology.id,
            systemFields: Data("state-change-base".utf8),
            contentFingerprint: try fixture.codec.contentFingerprint(for: baseRecord),
            updatedAt: "2026-07-29T12:00:00Z")
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

    @Test func capturePackageAllowsOnlyValidatedFlatContiguousProducerImages() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let imageData = cloudCoverPNGData()
        let imageZero = fixture.packageDirectory.appending(path: "image-0.png")
        try imageData.write(to: imageZero)
        let record = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
        let assetManifest = try #require(record["packageAssetsJSON"] as? String)
        #expect(assetManifest.contains(#""path":"image-0.png""#))
        #expect(assetManifest.contains(#""mediaType":"image/png""#))
        _ = try fixture.codec.decode(
            record,
            assetCopyDirectory: fixture.incomingDirectory)
        record["packageAssetsJSON"] = "[]" as CKRecordValue
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.decode(
                record,
                assetCopyDirectory: fixture.incomingDirectory)
        }

        for invalidName in [
            "secret.txt",
            ".DS_Store",
            "image-00.png",
            "image-0.extra.png",
            "image-2.png",
        ] {
            let invalidURL = fixture.packageDirectory.appending(path: invalidName)
            try imageData.write(to: invalidURL)
            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                _ = try fixture.codec.captureRecord(
                    fixture.capture,
                    packageDirectory: fixture.packageDirectory)
            }
            try FileManager.default.removeItem(at: invalidURL)
        }

        let nested = fixture.packageDirectory.appending(
            path: "nested",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false)
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.captureRecord(
                fixture.capture,
                packageDirectory: fixture.packageDirectory)
        }
        try FileManager.default.removeItem(at: nested)

        try Data("not-an-image".utf8).write(to: imageZero, options: .atomic)
        #expect(throws: ArticleCloudRecordCodec.Error.self) {
            _ = try fixture.codec.captureRecord(
                fixture.capture,
                packageDirectory: fixture.packageDirectory)
        }
    }

    @Test func downloadedCaptureArchiveUsesSameExactMemberGrammar() throws {
        let fixture = try ArticleCloudCodecFixture()
        defer { fixture.remove() }
        let snapshot = try Data(
            contentsOf: fixture.packageDirectory.appending(path: "snapshot.json"))
        let image = cloudCoverPNGData()

        let valid = fixture.root.appending(path: "valid-members.zip")
        try makeCaptureArchive(
            at: valid,
            members: [
                ("snapshot.json", snapshot),
                ("image-0.png", image),
            ])
        try fixture.codec.validateCaptureArchive(at: valid)

        for invalidMembers in [
            [("snapshot.json", snapshot), ("notes.txt", image)],
            [("snapshot.json", snapshot), ("image-1.png", image)],
            [("snapshot.json", snapshot), ("image-00.png", image)],
            [("snapshot.json", snapshot), ("image-0.extra.png", image)],
            [("nested/snapshot.json", snapshot)],
        ] {
            let archiveURL = fixture.root.appending(
                path: "invalid-\(UUID().uuidString).zip")
            try makeCaptureArchive(at: archiveURL, members: invalidMembers)
            #expect(throws: ArticleCloudRecordCodec.Error.self) {
                try fixture.codec.validateCaptureArchive(at: archiveURL)
            }
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

private func cloudCoverContentVersion(_ data: Data) -> String {
    "sha256:"
        + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func generatedCloudCoverPNGData(width: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(
        CGColor(
            red: CGFloat(width) / 10,
            green: 0.4,
            blue: 0.8,
            alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: width))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeCaptureArchive(
    at url: URL,
    members: [(String, Data)]
) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in members {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none
        ) { position, size in
            data.subdata(
                in: Int(position)..<min(Int(position) + size, data.count))
        }
    }
}

private func expectCaptureRejectedForUploadAndInstall(
    _ fixture: ArticleCloudCodecFixture
) throws {
    #expect(throws: ArticleCloudRecordCodec.Error.self) {
        _ = try fixture.codec.captureRecord(
            fixture.capture,
            packageDirectory: fixture.packageDirectory)
    }

    let snapshotURL = fixture.packageDirectory.appending(path: "snapshot.json")
    let archiveURL = fixture.root.appending(path: "rejected-snapshot.zip")
    try makeCaptureArchive(
        at: archiveURL,
        members: [("snapshot.json", try Data(contentsOf: snapshotURL))])
    let payload = ArticleCloudCapturePayload(
        capture: fixture.capture,
        packageArchiveURL: archiveURL,
        packageAssets: [])
    #expect(throws: ArticleCloudRecordCodec.Error.self) {
        _ = try fixture.codec.installCapturePackage(
            payload,
            workshopRootDirectory: fixture.managedDirectory)
    }
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
        sourceURL: String = "https://example.test/source",
        contentXHTML: String =
            #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>private body</p></body></html>"#,
        imageURLs: [String] = []
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
                contentXHTML: contentXHTML,
                textContent: "private body",
                imageURLs: imageURLs))
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        let snapshotData = try encoder.encode(envelope)
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
