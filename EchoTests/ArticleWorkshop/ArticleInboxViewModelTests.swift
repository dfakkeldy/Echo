// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct ArticleInboxViewModelTests {
    @Test func reloadDrainsCompleteStagingPackagesBeforeFetching() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let stagedID = "00000000-0000-0000-0000-000000000001"
        let captureDAO = fixture.captureDAO
        let stagedCapture = fixture.capture(id: stagedID)
        let viewModel = ArticleInboxViewModel(
            service: fixture.service,
            drainStaging: {
                try captureDAO.saveCapture(stagedCapture)
            }
        )

        await viewModel.reload()

        #expect(viewModel.articles.map(\.id) == [stagedID])
        #expect(viewModel.isImporting == false)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func reloadWorkerYieldsMainActorWhileStagingAndDatabaseWorkAreBlocked() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let gate = ReloadWorkerGate()
        let worker = ArticleInboxReloadWorker {
            gate.signalStartedAndWaitForRelease()
            return ArticleInboxReloadResult(articles: [], anthologies: [])
        }
        let viewModel = ArticleInboxViewModel(service: fixture.service, reloadWorker: worker)

        let reloadTask = Task { @MainActor in
            await viewModel.reload()
        }
        await Task.detached {
            gate.waitUntilStarted()
        }.value

        #expect(viewModel.isImporting)
        let mainActorDidRun = await Task { @MainActor in true }.value
        #expect(mainActorDidRun)

        gate.release()
        await reloadTask.value
        #expect(viewModel.isImporting == false)
    }

    @Test func selectionPrunesMissingIDsAndSelectAllTogglesPredictably() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let first = "00000000-0000-0000-0000-000000000001"
        let second = "00000000-0000-0000-0000-000000000002"
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: first, capturedAt: "2026-07-28T12:02:00Z"))
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: second, capturedAt: "2026-07-28T12:01:00Z"))
        let viewModel = ArticleInboxViewModel(service: fixture.service, drainStaging: {})
        await viewModel.reload()

        viewModel.selectAll()
        #expect(viewModel.selectedIDs == [first, second])
        viewModel.selectAll()
        #expect(viewModel.selectedIDs.isEmpty)
        viewModel.toggleSelection(first)
        try fixture.captureDAO.deleteCapture(id: first)

        await viewModel.reload()

        #expect(viewModel.articles.map(\.id) == [second])
        #expect(viewModel.selectedIDs.isEmpty)
    }

    @Test func reloadErrorPreservesLastSuccessfullyLoadedList() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        try fixture.captureDAO.saveCapture(fixture.capture(id: captureID))
        let shouldFail = LockedFlag()
        let viewModel = ArticleInboxViewModel(
            service: fixture.service,
            drainStaging: {
                if shouldFail.value { throw ReloadFailure.expected }
            }
        )
        await viewModel.reload()
        shouldFail.value = true

        await viewModel.reload()

        #expect(viewModel.articles.map(\.id) == [captureID])
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.isImporting == false)
    }

    @Test func selectedVisibleOrderCreatesDeterministicAnthologySeed() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let newest = "00000000-0000-0000-0000-000000000002"
        let oldest = "00000000-0000-0000-0000-000000000001"
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: oldest, capturedAt: "2026-07-28T12:01:00Z"))
        try fixture.captureDAO.saveCapture(
            fixture.capture(
                id: newest, capturedAt: "2026-07-28T12:02:00Z"))
        let viewModel = ArticleInboxViewModel(service: fixture.service, drainStaging: {})
        await viewModel.reload()
        viewModel.toggleSelection(oldest)
        viewModel.toggleSelection(newest)

        let anthology = try viewModel.createAnthology(title: "Visible Order")

        #expect(
            try fixture.anthologyDAO.entries(anthologyID: anthology.id).map(\.captureID) == [
                newest, oldest,
            ])
        #expect(viewModel.selectedIDs.isEmpty)
        #expect(viewModel.anthologies.map(\.id) == [anthology.id])
    }

    @Test func reloadFailureAfterLogicalDeleteDoesNotRestoreStaleArticleOrSelection() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let package = try fixture.createOwnedPackage(id: captureID)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: package.path))
        let reloadShouldFail = LockedFlag()
        let service = fixture.service
        let worker = ArticleInboxReloadWorker {
            if reloadShouldFail.value { throw ReloadFailure.expected }
            return ArticleInboxReloadResult(
                articles: try service.inboxItems(),
                anthologies: try service.anthologies()
            )
        }
        let viewModel = ArticleInboxViewModel(service: service, reloadWorker: worker)
        await viewModel.reload()
        viewModel.toggleSelection(captureID)
        reloadShouldFail.value = true

        await viewModel.delete(id: captureID)

        #expect(viewModel.articles.isEmpty)
        #expect(viewModel.selectedIDs.isEmpty)
        #expect(viewModel.errorMessage != nil)
        #expect(try fixture.captureDAO.capture(id: captureID) == nil)
    }
}

@MainActor
private final class ViewModelFixture {
    let root: URL
    let fileStore: ArticleWorkshopFileStore
    let database: DatabaseService
    let captureDAO: ArticleCaptureDAO
    let anthologyDAO: AnthologyDAO
    let service: ArticleInboxService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(
                path: "ArticleInboxViewModelTests-\(UUID().uuidString)", directoryHint: .isDirectory
            )
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

    func createOwnedPackage(id: String) throws -> URL {
        let package = fileStore.root
            .appending(path: "Captures", directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("snapshot".utf8).write(to: package.appending(path: "snapshot.json"))
        return package
    }

    func capture(
        id: String,
        capturedAt: String = "2026-07-28T12:01:00Z",
        packagePath: String? = nil
    ) -> ArticleCaptureRecord {
        ArticleCaptureRecord(
            id: id,
            sourceURL: "https://example.com/articles/\(id)",
            canonicalURL: nil,
            title: "Article \(id.suffix(4))",
            author: nil,
            siteName: "Example",
            language: "en",
            publishedAt: nil,
            capturedAt: capturedAt,
            captureMethod: .urlFetch,
            packagePath: packagePath
                ?? fileStore.root
                .appending(path: "Captures/\(id)", directoryHint: .isDirectory).path,
            contentSHA256: "digest-\(id)",
            extractorVersion: "1",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: capturedAt,
            modifiedAt: capturedAt
        )
    }
}

private nonisolated enum ReloadFailure: Error {
    case expected
}

private nonisolated final class ReloadWorkerGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseWorker = DispatchSemaphore(value: 0)

    func signalStartedAndWaitForRelease() {
        started.signal()
        releaseWorker.wait()
    }

    func waitUntilStarted() {
        started.wait()
    }

    func release() {
        releaseWorker.signal()
    }
}

private nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock { storedValue = newValue }
        }
    }
}
