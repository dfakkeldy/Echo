// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct ArticleInboxServiceTests {
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
        try fixture.captureDAO.saveCapture(fixture.capture(id: first))
        try fixture.captureDAO.saveCapture(fixture.capture(id: second))

        let anthology = try fixture.service.createAnthologySeed(
            title: "Weekend Reading",
            captureIDs: [second, first]
        )

        #expect(anthology.title == "Weekend Reading")
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
        let anthologyID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        try fixture.captureDAO.saveCapture(fixture.capture(id: first))
        try fixture.captureDAO.saveCapture(fixture.capture(id: second))

        #expect(throws: (any Error).self) {
            try fixture.service.createAnthologySeed(
                title: "Must Roll Back",
                captureIDs: [first, second, first]
            )
        }

        #expect(try fixture.anthologyDAO.anthology(id: anthologyID) == nil)
        #expect(try fixture.anthologyDAO.entries(anthologyID: anthologyID).isEmpty)
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
            makeID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
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
        deletionHook: @escaping @Sendable (ArticleInboxService.DeletionPoint, URL) throws -> Void
    ) -> ArticleInboxService {
        ArticleInboxService(
            captureDAO: captureDAO,
            anthologyDAO: anthologyDAO,
            fileStore: fileStore,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            makeID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! },
            deletionHook: deletionHook
        )
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
}

private nonisolated enum DeletionFailure: Error {
    case expected
}
