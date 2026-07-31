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

    @Test func olderReloadCannotPublishOrClearImportingBeforeLatestReloadCompletes() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let baseline = fixture.inboxItem(id: "baseline")
        let stale = fixture.inboxItem(id: "stale")
        let latest = fixture.inboxItem(id: "latest")
        let operations = SequencedReloadOperations(results: [
            ArticleInboxReloadResult(articles: [stale], anthologies: []),
            ArticleInboxReloadResult(articles: [latest], anthologies: []),
        ])
        let viewModel = ArticleInboxViewModel(
            service: fixture.service,
            reloadWorker: ArticleInboxReloadWorker(operation: operations.next)
        )
        viewModel.articles = [baseline]

        let firstReload = Task { @MainActor in await viewModel.reload() }
        await operations.waitUntilStarted(0)
        let secondReload = Task { @MainActor in await viewModel.reload() }
        await MainActor.run {}

        operations.release(0)
        await operations.waitUntilStarted(1)
        await firstReload.value

        #expect(viewModel.articles.map(\.id) == ["baseline"])
        #expect(viewModel.isImporting)
        #expect(viewModel.errorMessage == nil)

        operations.release(1)
        await secondReload.value

        #expect(viewModel.articles.map(\.id) == ["latest"])
        #expect(viewModel.isImporting == false)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func olderReloadCannotResurrectArticleAfterLogicalDeletion() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let captureID = "00000000-0000-0000-0000-000000000001"
        let package = try fixture.createOwnedPackage(id: captureID)
        try fixture.captureDAO.saveCapture(
            fixture.capture(id: captureID, packagePath: package.path))
        let stale = fixture.inboxItem(id: captureID)
        let operations = SequencedReloadOperations(results: [
            ArticleInboxReloadResult(articles: [stale], anthologies: []),
            ArticleInboxReloadResult(articles: [], anthologies: []),
        ])
        let deletionCommitted = DeletionCommitSignal()
        let service = fixture.makeService { point, _ in
            if point == .beforeQuarantineCleanup {
                deletionCommitted.signal()
            }
        }
        let viewModel = ArticleInboxViewModel(
            service: service,
            reloadWorker: ArticleInboxReloadWorker(operation: operations.next)
        )
        viewModel.articles = [stale]
        viewModel.selectedIDs = [captureID]

        let oldReload = Task { @MainActor in await viewModel.reload() }
        await operations.waitUntilStarted(0)
        let deletion = Task { @MainActor in await viewModel.delete(id: captureID) }
        await deletionCommitted.wait()
        while viewModel.articles.isEmpty == false {
            await Task.yield()
        }

        operations.release(0)
        await operations.waitUntilStarted(1)
        await oldReload.value

        #expect(viewModel.articles.isEmpty)
        #expect(viewModel.selectedIDs.isEmpty)
        #expect(viewModel.isImporting)

        operations.release(1)
        await deletion.value
        #expect(viewModel.articles.isEmpty)
        #expect(viewModel.selectedIDs.isEmpty)
        #expect(viewModel.isImporting == false)
    }

    @Test func cancelledOlderReloadCannotPublishErrorOrClearLatestImportingState() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let baseline = fixture.inboxItem(id: "baseline")
        let cancelled = fixture.inboxItem(id: "cancelled")
        let latest = fixture.inboxItem(id: "latest")
        let operations = SequencedReloadOperations(results: [
            ArticleInboxReloadResult(articles: [cancelled], anthologies: []),
            ArticleInboxReloadResult(articles: [latest], anthologies: []),
        ])
        let viewModel = ArticleInboxViewModel(
            service: fixture.service,
            reloadWorker: ArticleInboxReloadWorker(operation: operations.next)
        )
        viewModel.articles = [baseline]

        let cancelledReload = Task { @MainActor in await viewModel.reload() }
        await operations.waitUntilStarted(0)
        let latestReload = Task { @MainActor in await viewModel.reload() }
        await MainActor.run {}
        cancelledReload.cancel()
        operations.release(0)
        await operations.waitUntilStarted(1)
        await cancelledReload.value

        #expect(viewModel.articles.map(\.id) == ["baseline"])
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.isImporting)

        operations.release(1)
        await latestReload.value
        #expect(viewModel.articles.map(\.id) == ["latest"])
        #expect(viewModel.errorMessage == nil)
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
        try fixture.saveBuildEligibleCapture(
            id: oldest, capturedAt: "2026-07-28T12:01:00Z")
        try fixture.saveBuildEligibleCapture(
            id: newest, capturedAt: "2026-07-28T12:02:00Z")
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

    @Test func failedInboxRowsCannotEnterAnthologySelection() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.removeFiles() }
        let ready = "00000000-0000-0000-0000-000000000001"
        let failed = "00000000-0000-0000-0000-000000000002"
        try fixture.captureDAO.saveCapture(fixture.capture(id: ready))
        var failedCapture = fixture.capture(id: failed)
        failedCapture.contentState = ArticleContentState.captureFailed.rawValue
        try fixture.captureDAO.saveCapture(failedCapture)
        let viewModel = ArticleInboxViewModel(service: fixture.service, drainStaging: {})
        await viewModel.reload()

        viewModel.toggleSelection(failed)
        #expect(viewModel.selectedIDs.isEmpty)

        viewModel.selectAll()
        #expect(viewModel.selectedIDs == [ready])
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
            makeID: UUID.init
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

    func makeService(
        deletionHook: @escaping @Sendable (ArticleInboxService.DeletionPoint, URL) throws -> Void
    ) -> ArticleInboxService {
        ArticleInboxService(
            captureDAO: captureDAO,
            anthologyDAO: anthologyDAO,
            fileStore: fileStore,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            makeID: UUID.init,
            deletionHook: deletionHook
        )
    }

    func inboxItem(id: String) -> ArticleInboxItem {
        ArticleInboxItem(
            id: id,
            title: "Article \(id)",
            author: nil,
            siteName: "Example",
            sourceURL: "https://example.com/articles/\(id)",
            canonicalURL: nil,
            capturedAt: "2026-07-28T12:01:00Z",
            state: .ready,
            warnings: [],
            isPossibleDuplicate: false,
            keepBothAvailable: true
        )
    }

    func capture(
        id: String,
        capturedAt: String = "2026-07-28T12:01:00Z",
        packagePath: String? = nil,
        contentSHA256: String? = nil
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
            contentSHA256: contentSHA256 ?? "digest-\(id)",
            extractorVersion: "1",
            contentState: "ready",
            warningsJSON: "[]",
            currentRevisionID: nil,
            createdAt: capturedAt,
            modifiedAt: capturedAt
        )
    }

    func saveBuildEligibleCapture(id: String, capturedAt: String) throws {
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
                byline: nil,
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
                capturedAt: capturedAt,
                packagePath: imported.snapshotURL.deletingLastPathComponent().path,
                contentSHA256: imported.sha256))
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

private nonisolated final class SequencedReloadOperations: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [ArticleInboxReloadResult]
    private let started: [DispatchSemaphore]
    private let releases: [DispatchSemaphore]
    private var nextIndex = 0

    init(results: [ArticleInboxReloadResult]) {
        self.results = results
        started = results.map { _ in DispatchSemaphore(value: 0) }
        releases = results.map { _ in DispatchSemaphore(value: 0) }
    }

    func next() throws -> ArticleInboxReloadResult {
        let index = lock.withLock {
            defer { nextIndex += 1 }
            return nextIndex
        }
        started[index].signal()
        releases[index].wait()
        return results[index]
    }

    func waitUntilStarted(_ index: Int) async {
        await Task.detached {
            self.blockingWaitUntilStarted(index)
        }.value
    }

    func release(_ index: Int) {
        releases[index].signal()
    }

    private func blockingWaitUntilStarted(_ index: Int) {
        started[index].wait()
    }
}

private nonisolated final class DeletionCommitSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() async {
        await Task.detached {
            self.blockingWait()
        }.value
    }

    private func blockingWait() {
        semaphore.wait()
    }
}
