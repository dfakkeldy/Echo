// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct ArticleInboxIngestionServiceTests {
    @Test func incompletePackageIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let package = fixture.stagingRoot.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONEncoder.articleWorkshop.encode(envelope).write(
            to: package.appending(path: "envelope.json"), options: .atomic)

        try fixture.service.drainStaging()

        #expect(try fixture.dao.capture(id: envelope.captureID.uuidString) == nil)
        #expect(FileManager.default.fileExists(atPath: package.path))
        #expect(FileManager.default.fileExists(
            atPath: fixture.workshopRoot.appending(path: "Captures/\(envelope.captureID.uuidString)/snapshot.json").path
        ) == false)
    }

    @Test func validPackageMovesIntoApplicationSupportAndDeletesStagingCopy() async throws {
        let fixture = try makeFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let package = try fixture.writer.stage(envelope)

        try fixture.service.drainStaging()

        let snapshot = fixture.workshopRoot
            .appending(path: "Captures/\(envelope.captureID.uuidString)/snapshot.json")
        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(FileManager.default.fileExists(atPath: package.path) == false)
        #expect(try fixture.dao.capture(id: envelope.captureID.uuidString)?.packagePath == snapshot.deletingLastPathComponent().path)
    }

    @Test func secondDrainOfSameCaptureUUIDDoesNotDuplicateRows() async throws {
        let fixture = try makeFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let envelope = articleWorkshopFixtureEnvelope()
        _ = try fixture.writer.stage(envelope)
        try fixture.service.drainStaging()
        _ = try fixture.writer.stage(envelope)

        try fixture.service.drainStaging()

        #expect(try fixture.dao.captures().filter { $0.id == envelope.captureID.uuidString }.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: fixture.stagingRoot.appending(path: envelope.captureID.uuidString).path
        ) == false)
    }

    @Test func importedButUnclearedStagingPackageIsCleanedOnRetry() async throws {
        let fixture = try makeFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let package = try fixture.writer.stage(envelope)
        _ = try fixture.fileStore.importEnvelope(at: package)

        try fixture.service.drainStaging()

        #expect(try fixture.dao.capture(id: envelope.captureID.uuidString) != nil)
        #expect(FileManager.default.fileExists(atPath: package.path) == false)
    }

    @Test func failedDestinationWriteLeavesCompleteStagingPackageForRetry() async throws {
        let fixture = try makeFixture(destinationRootIsFile: true)
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let package = try fixture.writer.stage(envelope)

        #expect(throws: (any Error).self) {
            try fixture.service.drainStaging()
        }

        #expect(FileManager.default.fileExists(atPath: package.appending(path: "complete").path))
        #expect(try fixture.dao.capture(id: envelope.captureID.uuidString) == nil)
    }

    @Test func matchingDigestWithConflictingMetadataRetainsStagingPackage() async throws {
        let fixture = try makeFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let envelope = articleWorkshopFixtureEnvelope()
        _ = try fixture.writer.stage(envelope)
        try fixture.service.drainStaging()
        var conflicting = try #require(try fixture.dao.capture(id: envelope.captureID.uuidString))
        conflicting.title = "Conflicting title"
        try fixture.dao.saveCapture(conflicting)
        let package = try fixture.writer.stage(envelope)

        #expect(throws: ArticleInboxIngestionService.Error.self) {
            try fixture.service.drainStaging()
        }

        #expect(FileManager.default.fileExists(atPath: package.path))
        #expect(try fixture.dao.capture(id: envelope.captureID.uuidString)?.title == "Conflicting title")
    }

    @Test func symlinkedDirectPackageIsRejectedWithoutFollowingIt() async throws {
        let fixture = try makeFixture()
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        let envelope = articleWorkshopFixtureEnvelope()
        let externalRoot = fixture.root.appending(path: "external", directoryHint: .isDirectory)
        let externalPackage = try ArticleCaptureStagingWriter(root: externalRoot).stage(envelope)
        let stagedPath = fixture.stagingRoot.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: stagedPath, withDestinationURL: externalPackage)

        #expect(throws: (any Error).self) {
            try fixture.service.drainStaging()
        }

        #expect(FileManager.default.fileExists(atPath: externalPackage.path))
        #expect(try fixture.dao.capture(id: envelope.captureID.uuidString) == nil)
    }

    @Test func replacementBeforeCleanupIsRetainedWhenBytesDoNotMatchImport() async throws {
        let envelope = articleWorkshopFixtureEnvelope()
        let replacement = articleWorkshopFixtureEnvelope(captureID: envelope.captureID, title: "Replacement")
        var writer: ArticleCaptureStagingWriter?
        let fixture = try makeFixture { point, package in
            guard point == .beforeQuarantine else { return }
            try FileManager.default.removeItem(at: package)
            _ = try writer!.stage(replacement)
        }
        writer = fixture.writer
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.writer.stage(envelope)

        #expect(throws: ArticleInboxIngestionService.Error.self) {
            try fixture.service.drainStaging()
        }

        let quarantineRoots = try FileManager.default.contentsOfDirectory(at: fixture.stagingRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".cleanup-") }
        let retained = try #require(quarantineRoots.first)
            .appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        let validated = try fixture.fileStore.validateEnvelope(at: retained)
        #expect(validated.envelope.payload.title == "Replacement")
    }

    @Test func newOriginalPackageAfterQuarantineIsNotRemoved() async throws {
        let envelope = articleWorkshopFixtureEnvelope()
        var writer: ArticleCaptureStagingWriter?
        let fixture = try makeFixture { point, _ in
            guard point == .afterQuarantine else { return }
            _ = try writer!.stage(envelope)
        }
        writer = fixture.writer
        defer { try! FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.writer.stage(envelope)

        try fixture.service.drainStaging()

        let replacement = fixture.stagingRoot.appending(path: envelope.captureID.uuidString, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: replacement.path))
        #expect(try fixture.dao.capture(id: envelope.captureID.uuidString) != nil)
    }

    private func makeFixture(
        destinationRootIsFile: Bool = false,
        cleanupHook: ((ArticleInboxIngestionService.CleanupPoint, URL) throws -> Void)? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ArticleInboxIngestionServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stagingRoot = root.appending(path: "staging", directoryHint: .isDirectory)
        let workshopRoot = root.appending(path: "workshop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        if destinationRootIsFile {
            try Data("not a directory".utf8).write(to: workshopRoot, options: .atomic)
        }
        let database = try DatabaseService(inMemory: ())
        let dao = ArticleCaptureDAO(db: database.writer)
        let fileStore = ArticleWorkshopFileStore(root: workshopRoot)
        return Fixture(
            root: root,
            stagingRoot: stagingRoot,
            workshopRoot: workshopRoot,
            writer: ArticleCaptureStagingWriter(root: stagingRoot),
            fileStore: fileStore,
            dao: dao,
            service: ArticleInboxIngestionService(
                captureDAO: dao,
                fileStore: fileStore,
                stagingRoot: stagingRoot,
                cleanupHook: cleanupHook
            )
        )
    }

    private struct Fixture {
        let root: URL
        let stagingRoot: URL
        let workshopRoot: URL
        let writer: ArticleCaptureStagingWriter
        let fileStore: ArticleWorkshopFileStore
        let dao: ArticleCaptureDAO
        let service: ArticleInboxIngestionService
    }
}
