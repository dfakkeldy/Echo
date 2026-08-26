// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ArticleInboxServiceTests {
    @Test func newDraftOnlyAndFailedBuildCapturesRemainInInbox() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let newCapture = "00000000-0000-0000-0000-000000000001"
        let draftCapture = "00000000-0000-0000-0000-000000000002"
        let failedCapture = "00000000-0000-0000-0000-000000000003"
        try fixture.saveBuildEligibleCapture(id: newCapture)
        try fixture.saveBuildEligibleCapture(id: draftCapture)
        try fixture.saveBuildEligibleCapture(id: failedCapture)
        _ = try fixture.service.createAnthologySeed(
            title: "Draft Only",
            captureIDs: [draftCapture])
        _ = try fixture.saveBuild(
            captureIDs: [failedCapture],
            status: "failed",
            title: "Rolled Back")

        let items = try fixture.service.inboxItems()

        #expect(Set(items.map(\.id)) == [newCapture, draftCapture, failedCapture])
        #expect(items.allSatisfy { $0.isUsed == false })
    }

    @Test func successfulBuildArchivesWithoutMutatingCapturePackageOrBuildArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        try fixture.saveBuildEligibleCapture(id: captureID)
        let captureBefore = try #require(try fixture.captureDAO.capture(id: captureID))
        let snapshotURL = URL(fileURLWithPath: captureBefore.packagePath)
            .appending(path: "snapshot.json")
        let packageBytesBefore = try Data(contentsOf: snapshotURL)
        let evidence = try fixture.saveBuild(
            captureIDs: [captureID],
            status: "succeeded",
            title: "Built Once")
        let captureAfterBuild = try #require(try fixture.captureDAO.capture(id: captureID))
        let epubBytesBefore = try Data(contentsOf: evidence.epubURL)

        #expect(try fixture.service.inboxItems().isEmpty)
        let archived = try fixture.service.inboxItems(showUsedCaptures: true)
        #expect(archived.map(\.id) == [captureID])
        #expect(archived.map(\.isUsed) == [true])
        #expect(try fixture.captureDAO.capture(id: captureID) == captureAfterBuild)
        #expect(try Data(contentsOf: snapshotURL) == packageBytesBefore)
        #expect(
            try fixture.anthologyDAO.latestSuccessfulBuild(
                anthologyID: evidence.record.anthologyID) == evidence.record)
        #expect(try Data(contentsOf: evidence.epubURL) == epubBytesBefore)
    }

    @Test func reusedCaptureHasOneStableArchivedSourceIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        try fixture.saveBuildEligibleCapture(id: captureID)
        let packagePath = try #require(try fixture.captureDAO.capture(id: captureID)).packagePath
        _ = try fixture.saveBuild(
            captureIDs: [captureID],
            status: "succeeded",
            title: "First Collection")
        _ = try fixture.saveBuild(
            captureIDs: [captureID],
            status: "succeeded",
            title: "Second Collection")

        let archived = try fixture.service.inboxItems(showUsedCaptures: true)

        #expect(archived.map(\.id) == [captureID])
        #expect(try fixture.captureDAO.captures().map(\.id) == [captureID])
        #expect(try fixture.captureDAO.capture(id: captureID)?.packagePath == packagePath)
    }

    @Test func builtCaptureCannotBeDeletedAfterRemovalFromCurrentDraft() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        try fixture.saveBuildEligibleCapture(id: captureID)
        let evidence = try fixture.saveBuild(
            captureIDs: [captureID],
            status: "succeeded",
            title: "Historical Edition")
        let entry = try #require(
            try fixture.anthologyDAO.entries(anthologyID: evidence.record.anthologyID).first)
        try fixture.anthologyDAO.removeEntry(
            id: entry.id,
            anthologyID: evidence.record.anthologyID)
        let capture = try #require(try fixture.captureDAO.capture(id: captureID))

        let impact = try fixture.service.deletionImpact(for: captureID)

        #expect(impact == .referenced(projectNames: ["Historical Edition"]))
        #expect(throws: ArticleInboxService.Error.self) {
            try fixture.service.delete(id: captureID)
        }
        #expect(try fixture.captureDAO.capture(id: captureID) == capture)
        #expect(FileManager.default.fileExists(atPath: capture.packagePath))
    }

    @Test func inboxOrdersNewestFirstAndShowsReadyReviewAndFailedStates() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000004",
                capturedAt: "2026-07-28T12:04:00Z",
                state: "ready"
            ))
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000002",
                capturedAt: "2026-07-28T12:03:00Z",
                state: "reviewSuggested"
            ))
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000001",
                capturedAt: "2026-07-28T12:03:00Z",
                state: "captureFailed"
            ))
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000003",
                capturedAt: "2026-07-28T12:02:00Z",
                state: "futureState"
            ))

        let items = try fixture.service.inboxItems()

        #expect(
            items.map(\.id) == [
                "00000000-0000-0000-0000-000000000004",
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000002",
                "00000000-0000-0000-0000-000000000003",
            ])
        #expect(
            items.map(\.state) == [
                .ready,
                .captureFailed,
                .reviewSuggested,
                .captureFailed,
            ])
        #expect(items.last?.warnings.contains("Unknown capture state: futureState") == true)
    }

    @Test func malformedWarningsAreReviewNeededRatherThanReady() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        var capture = fixture.capture(
            id: "00000000-0000-0000-0000-000000000001",
            capturedAt: "2026-07-28T12:03:00Z",
            state: "ready"
        )
        capture.warningsJSON = #"{"not":"an array"}"#
        try fixture.captureDAO.saveCapture(capture)

        let item = try #require(try fixture.service.inboxItems().first)

        #expect(item.state == .reviewSuggested)
        #expect(item.warnings == ["Capture warnings could not be read."])
    }

    @Test func duplicateIsWarningAndKeepBothRemainsAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000001",
                canonicalURL: "https://example.com/story",
                digest: "same-readable-content"
            ))
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000002",
                canonicalURL: "https://example.com/story",
                digest: "different-bytes"
            ))

        let items = try fixture.service.inboxItems()

        #expect(items.map(\.isPossibleDuplicate) == [true, true])
        #expect(items.map(\.keepBothAvailable) == [true, true])
        #expect(try fixture.captureDAO.captures().count == 2)
    }

    @Test func matchingStoredSourceURLIsDuplicateEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let sharedSourceURL = "https://example.com/read-this"
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000001",
                sourceURL: sharedSourceURL,
                canonicalURL: nil,
                digest: "first-content"
            ))
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: "00000000-0000-0000-0000-000000000002",
                sourceURL: sharedSourceURL,
                canonicalURL: "https://canonical.example/different",
                digest: "second-content"
            ))

        let items = try fixture.service.inboxItems()

        #expect(items.map(\.isPossibleDuplicate) == [true, true])
        #expect(items.map(\.keepBothAvailable) == [true, true])
        #expect(try fixture.captureDAO.captures().count == 2)
    }

    @Test func multiSelectionCreatesAnAnthologySeedWithoutEditing() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let first = "00000000-0000-0000-0000-000000000001"
        let second = "00000000-0000-0000-0000-000000000002"
        try fixture.saveBuildEligibleCapture(id: first)
        try fixture.saveBuildEligibleCapture(id: second)

        let anthology = try fixture.service.createAnthologySeed(
            title: "Weekend Reading",
            captureIDs: [second, first]
        )

        #expect(anthology.title == "Weekend Reading")
        #expect(anthology.creator == nil)
        #expect(anthology.latestBuildRevision == 0)
        #expect(anthology.nextStableSlot == 2)
        #expect(
            try fixture.anthologyDAO.entries(anthologyID: anthology.id).map(\.captureID) == [
                second, first,
            ])
        #expect(
            try fixture.anthologyDAO.entries(anthologyID: anthology.id).map(\.sortOrder) == [0, 1])
        #expect(
            try fixture.anthologyDAO.entries(anthologyID: anthology.id).map(\.stableSlot) == [0, 1])
        #expect(try fixture.anthologyDAO.anthology(id: anthology.id)?.nextStableSlot == 2)
    }

    @Test func laterEntryFailureRollsBackEntireAnthologySeed() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let first = "00000000-0000-0000-0000-000000000001"
        let second = "00000000-0000-0000-0000-000000000002"
        try fixture.captureDAO.saveCapture(fixture.capture(id: first))
        try fixture.captureDAO.saveCapture(fixture.capture(id: second))

        #expect(throws: (any Error).self) {
            try fixture.service.createAnthologySeed(
                title: "Must Roll Back",
                captureIDs: [first, second, first]
            )
        }

        #expect(try fixture.anthologyDAO.all().isEmpty)
    }

    @Test func failedOrMissingPackageCaptureCannotCreateAnthologySeed() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let failed = "00000000-0000-0000-0000-000000000001"
        let missingPackage = "00000000-0000-0000-0000-000000000002"
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: failed, state: ArticleContentState.captureFailed.rawValue))
        try fixture.captureDAO.saveCapture(fixture.capture(id: missingPackage))

        #expect(throws: ArticleInboxService.Error.self) {
            try fixture.service.createAnthologySeed(
                title: "Must Stay Empty",
                captureIDs: [failed])
        }
        #expect(throws: ArticleInboxService.Error.self) {
            try fixture.service.createAnthologySeed(
                title: "Still Empty",
                captureIDs: [missingPackage])
        }

        #expect(try fixture.anthologyDAO.all().isEmpty)
    }

    @Test func referencedArticleDeletionReturnsAffectedProjectNames() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let package = try fixture.createOwnedPackage(id: captureID)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: package.path))
        try fixture.saveAnthology(id: "project-b", title: "Field Notes", captureID: captureID)
        try fixture.saveAnthology(id: "project-a", title: "Morning Brief", captureID: captureID)

        let impact = try fixture.service.deletionImpact(for: captureID)

        #expect(impact == .referenced(projectNames: ["Field Notes", "Morning Brief"]))
        #expect(throws: ArticleInboxService.Error.self) {
            try fixture.service.delete(id: captureID)
        }
        #expect(try fixture.captureDAO.capture(id: captureID) != nil)
        #expect(FileManager.default.fileExists(atPath: package.path))
    }

    @Test func unreferencedDeletionRemovesDatabaseAndOwnedPackage() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let package = try fixture.createOwnedPackage(id: captureID)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: package.path))

        try fixture.service.delete(id: captureID)

        #expect(try fixture.captureDAO.capture(id: captureID) == nil)
        #expect(FileManager.default.fileExists(atPath: package.path) == false)
    }

    @Test func failureBeforeDatabaseCommitRestoresPackageAndRow() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let package = try fixture.createOwnedPackage(id: captureID)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: package.path))
        let service = fixture.makeService { point, _ in
            if point == .beforeDatabaseCommit {
                throw DeletionFailure.expected
            }
        }

        #expect(throws: DeletionFailure.self) {
            try service.delete(id: captureID)
        }

        #expect(try fixture.captureDAO.capture(id: captureID) != nil)
        #expect(FileManager.default.fileExists(atPath: package.path))
        #expect(try fixture.deletionQuarantineContents().isEmpty)
    }

    @Test func failureAfterDatabaseCommitLeavesReconciliableResidue() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let package = try fixture.createOwnedPackage(id: captureID)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: package.path))
        let service = fixture.makeService { point, _ in
            if point == .beforeQuarantineCleanup {
                throw DeletionFailure.expected
            }
        }

        try service.delete(id: captureID)

        #expect(try fixture.captureDAO.capture(id: captureID) == nil)
        #expect(FileManager.default.fileExists(atPath: package.path) == false)
        #expect(try fixture.deletionQuarantineContents().count == 1)

        #expect(try fixture.service.inboxItems().isEmpty)
        #expect(try fixture.deletionQuarantineContents().isEmpty)
    }

    @Test func referenceAppearingBeforeTransactionalDeleteRestoresPackageAndRow() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let package = try fixture.createOwnedPackage(id: captureID)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: package.path))
        let anthologyDAO = fixture.anthologyDAO
        let anthology = fixture.anthology(id: "late-reference", title: "Late Reference")
        let service = fixture.makeService { point, _ in
            guard point == .beforeDatabaseCommit else { return }
            try anthologyDAO.save(anthology)
            _ = try anthologyDAO.addCapture(captureID, to: anthology.id)
        }

        #expect(throws: ArticleInboxService.Error.self) {
            try service.delete(id: captureID)
        }

        #expect(try fixture.captureDAO.capture(id: captureID) != nil)
        #expect(FileManager.default.fileExists(atPath: package.path))
        #expect(try fixture.anthologyDAO.entries(anthologyID: anthology.id).count == 1)
        #expect(try fixture.deletionQuarantineContents().isEmpty)
    }

    @Test func successfulBuildAppearingBeforeTransactionalDeleteRestoresPackageAndRow() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        try fixture.saveBuildEligibleCapture(id: captureID)
        let evidence = try fixture.saveBuild(
            captureIDs: [captureID],
            status: "succeeded",
            title: "Late Historical Edition")
        let entry = try #require(
            try fixture.anthologyDAO.entries(anthologyID: evidence.record.anthologyID).first)
        try fixture.anthologyDAO.removeEntry(
            id: entry.id,
            anthologyID: evidence.record.anthologyID)
        try fixture.database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM anthology_build WHERE id = ?",
                arguments: [evidence.record.id])
        }
        let anthologyDAO = fixture.anthologyDAO
        let service = fixture.makeService { point, _ in
            guard point == .beforeDatabaseCommit else { return }
            try anthologyDAO.saveBuild(evidence.record)
        }
        let capture = try #require(try fixture.captureDAO.capture(id: captureID))

        #expect(throws: ArticleInboxService.Error.self) {
            try service.delete(id: captureID)
        }

        #expect(try fixture.captureDAO.capture(id: captureID) == capture)
        #expect(FileManager.default.fileExists(atPath: capture.packagePath))
        #expect(try fixture.deletionQuarantineContents().isEmpty)
    }

    @Test func unrecognizedDeletionResidueFailsClosedWithoutRemovingIt() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let quarantineRoot = fixture.fileStore.root.appending(
            path: ".DeletionQuarantine", directoryHint: .isDirectory)
        let unrecognized = quarantineRoot.appending(
            path: "not-a-deletion-residue", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: unrecognized, withIntermediateDirectories: true)
        let marker = unrecognized.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)

        #expect(throws: ArticleInboxService.Error.self) {
            try fixture.service.inboxItems()
        }

        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func symlinkedWorkshopRootIsRejectedWithoutRemovingTargetResidue() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let target = fixture.root.appending(
            path: "workshop-target", directoryHint: .isDirectory)
        let symlink = fixture.root.appending(
            path: "workshop-symlink", directoryHint: .isDirectory)
        let targetStore = ArticleWorkshopFileStore(root: target)
        let targetQuarantine = targetStore.root.appending(
            path: ".DeletionQuarantine", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: targetQuarantine, withIntermediateDirectories: true)
        let targetMarker = targetStore.root.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: targetMarker)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let service = fixture.makeService(
            fileStore: ArticleWorkshopFileStore(root: symlink),
            deletionQuarantineLimit: 2
        )

        #expect(throws: ArticleInboxService.Error.self) {
            try service.inboxItems()
        }

        #expect(FileManager.default.fileExists(atPath: targetMarker.path))
        #expect(FileManager.default.fileExists(atPath: targetQuarantine.path))
    }

    @Test func overLimitDeletionResiduesFailBeforeRemovingAnyEntry() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let residues = try (1...3).map { index in
            try fixture.createDeletionResidue(
                in: fixture.fileStore,
                captureID: String(
                    format: "10000000-0000-0000-0000-%012d", index),
                nonce: String(
                    format: "20000000-0000-0000-0000-%012d", index)
            )
        }
        let service = fixture.makeService(deletionQuarantineLimit: 2)

        #expect(throws: ArticleInboxService.Error.self) {
            try service.inboxItems()
        }

        #expect(residues.allSatisfy { FileManager.default.fileExists(atPath: $0.marker.path) })
    }

    @Test func atLimitValidDeletionResiduesReconcileCompletely() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let residues = try (1...2).map { index in
            try fixture.createDeletionResidue(
                in: fixture.fileStore,
                captureID: String(
                    format: "10000000-0000-0000-0000-%012d", index),
                nonce: String(
                    format: "20000000-0000-0000-0000-%012d", index)
            )
        }
        let service = fixture.makeService(deletionQuarantineLimit: 2)

        #expect(try service.inboxItems().isEmpty)

        #expect(
            residues.allSatisfy { FileManager.default.fileExists(atPath: $0.marker.path) == false })
        #expect(try fixture.deletionQuarantineContents().isEmpty)
    }

    @Test func forgedPackagePathFailsClosedWithoutDeletingFileOrDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let victim = fixture.root.appending(path: "unowned", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: victim.appending(path: "important.txt"))
        try fixture.captureDAO.saveCapture(fixture.capture(id: captureID, packagePath: victim.path))

        #expect(throws: ArticleInboxService.Error.self) {
            try fixture.service.delete(id: captureID)
        }

        #expect(try fixture.captureDAO.capture(id: captureID) != nil)
        #expect(
            FileManager.default.fileExists(atPath: victim.appending(path: "important.txt").path))
    }

    @Test func symlinkedOwnedPackageFailsClosedWithoutDeletingTargetOrDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let external = fixture.root.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: external.appending(path: "important.txt"))
        let expected = fixture.expectedPackage(id: captureID)
        try FileManager.default.createDirectory(
            at: expected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: expected, withDestinationURL: external)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: expected.path))

        #expect(throws: ArticleInboxService.Error.self) {
            try fixture.service.delete(id: captureID)
        }

        #expect(try fixture.captureDAO.capture(id: captureID) != nil)
        #expect(
            FileManager.default.fileExists(atPath: external.appending(path: "important.txt").path))
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let fileStore: ArticleWorkshopFileStore
    let database: DatabaseService
    let captureDAO: ArticleCaptureDAO
    let anthologyDAO: AnthologyDAO
    let service: ArticleInboxService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "ArticleInboxServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileStore = ArticleWorkshopFileStore(
            root: root.appending(path: "workshop", directoryHint: .isDirectory))
        database = try DatabaseService(inMemory: ())
        captureDAO = ArticleCaptureDAO(db: database.writer)
        anthologyDAO = AnthologyDAO(db: database.writer)
        service = ArticleInboxService(
            captureDAO: captureDAO,
            anthologyDAO: anthologyDAO,
            fileStore: fileStore,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            makeID: UUID.init
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    func expectedPackage(id: String) -> URL {
        fileStore.root
            .appending(path: "Captures", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
    }

    func createOwnedPackage(id: String) throws -> URL {
        let package = expectedPackage(id: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("snapshot".utf8).write(to: package.appending(path: "snapshot.json"))
        return package
    }

    func saveAnthology(id: String, title: String, captureID: String) throws {
        try anthologyDAO.save(anthology(id: id, title: title))
        _ = try anthologyDAO.addCapture(captureID, to: id)
    }

    func anthology(id: String, title: String) -> AnthologyRecord {
        AnthologyRecord(
            id: id,
            title: title,
            subtitle: nil,
            creator: "Echo",
            coverPath: nil,
            nextStableSlot: 0,
            latestBuildRevision: 0,
            createdAt: "2026-07-28T12:01:00Z",
            modifiedAt: "2026-07-28T12:01:00Z"
        )
    }

    func makeService(
        fileStore: ArticleWorkshopFileStore? = nil,
        deletionQuarantineLimit: Int = 128,
        deletionHook: (@Sendable (ArticleInboxService.DeletionPoint, URL) throws -> Void)? = nil
    ) -> ArticleInboxService {
        ArticleInboxService(
            captureDAO: captureDAO,
            anthologyDAO: anthologyDAO,
            fileStore: fileStore ?? self.fileStore,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            makeID: UUID.init,
            deletionQuarantineLimit: deletionQuarantineLimit,
            deletionHook: deletionHook
        )
    }

    func createDeletionResidue(
        in fileStore: ArticleWorkshopFileStore,
        captureID: String,
        nonce: String
    ) throws -> (directory: URL, marker: URL) {
        let directory =
            fileStore.root
            .appending(path: ".DeletionQuarantine", directoryHint: .isDirectory)
            .appending(
                path: "\(captureID)-\(nonce)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let marker = directory.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)
        return (directory, marker)
    }

    func deletionQuarantineContents() throws -> [URL] {
        let root = fileStore.root.appending(
            path: ".DeletionQuarantine", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
    }

    func capture(
        id: String,
        sourceURL: String? = nil,
        capturedAt: String = "2026-07-28T12:01:00Z",
        state: String = "ready",
        canonicalURL: String? = nil,
        digest: String? = nil,
        packagePath: String? = nil
    ) -> ArticleCaptureRecord {
        ArticleCaptureRecord(
            id: id,
            sourceURL: sourceURL ?? "https://example.com/articles/\(id)",
            canonicalURL: canonicalURL,
            title: "Article \(id.suffix(4))",
            author: "Example Author",
            siteName: "Example",
            language: "en",
            publishedAt: nil,
            capturedAt: capturedAt,
            captureMethod: .urlFetch,
            packagePath: packagePath ?? expectedPackage(id: id).path,
            contentSHA256: digest ?? "digest-\(id)",
            extractorVersion: "1",
            contentState: state,
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: capturedAt,
            modifiedAt: capturedAt
        )
    }

    func saveBuildEligibleCapture(id: String) throws {
        let captureID = try #require(UUID(uuidString: id))
        let envelope = ArticleCaptureEnvelope(
            schemaVersion: 1,
            captureID: captureID,
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
            method: .urlFetch,
            sourceApplication: nil,
            payload: ReadabilityCapturePayload(
                sourceURL: "https://example.com/articles/\(id)",
                canonicalURL: nil,
                title: "Article \(id.suffix(4))",
                byline: "Example Author",
                siteName: "Example",
                language: "en",
                publishedTime: nil,
                excerpt: nil,
                contentXHTML: "<article><p>Readable article.</p></article>",
                textContent: "Readable article.",
                imageURLs: []))
        let staging = root.appending(
            path: "Staging-\(id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let imported = try fileStore.importEnvelope(
            at: ArticleCaptureStagingWriter(root: staging).stage(envelope))
        try captureDAO.saveCapture(
            capture(
                id: id,
                digest: imported.sha256,
                packagePath: imported.snapshotURL.deletingLastPathComponent().path))
    }

    func saveBuild(
        captureIDs: [String],
        status: String,
        title: String
    ) throws -> (record: AnthologyBuildRecord, epubURL: URL) {
        let anthology = try service.createAnthologySeed(
            title: title,
            captureIDs: captureIDs)
        let manifest = try AnthologyService(
            captureDAO: captureDAO,
            anthologyDAO: anthologyDAO,
            fileStore: fileStore,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            makeID: UUID.init
        ).prepareManifest(anthologyID: anthology.id)
        let encoder = JSONEncoder.articleWorkshop
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let epubURL = root.appending(path: "\(anthology.id).epub")
        let epubBytes = Data("epub-\(anthology.id)-\(manifest.revision)".utf8)
        try epubBytes.write(to: epubURL)
        let record = AnthologyBuildRecord(
            id: UUID().uuidString,
            anthologyID: anthology.id,
            revision: manifest.revision,
            epubIdentifier: manifest.epubIdentifier,
            manifestJSON: String(decoding: manifestData, as: UTF8.self),
            manifestSHA256: SHA256.hash(data: manifestData)
                .map { String(format: "%02x", $0) }.joined(),
            epubPath: status == "succeeded" ? epubURL.path : nil,
            epubSHA256: status == "succeeded"
                ? SHA256.hash(data: epubBytes).map { String(format: "%02x", $0) }.joined()
                : nil,
            audiobookID: status == "succeeded" ? "fixture-\(anthology.id)" : nil,
            status: status,
            errorCode: status == "failed" ? "build_failed" : nil,
            createdAt: "2026-07-28T12:05:00Z")
        try anthologyDAO.saveBuild(record)
        return (record, epubURL)
    }
}

private nonisolated enum DeletionFailure: Error {
    case expected
}
