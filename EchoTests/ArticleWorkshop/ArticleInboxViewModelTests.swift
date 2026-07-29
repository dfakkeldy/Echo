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
        let viewModel = ArticleInboxViewModel(
            service: fixture.service,
            drainStaging: {
                try fixture.captureDAO.saveCapture(fixture.capture(id: stagedID))
            }
        )

        await viewModel.reload()

        #expect(viewModel.articles.map(\.id) == [stagedID])
        #expect(viewModel.isImporting == false)
        #expect(viewModel.errorMessage == nil)
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
        var shouldFail = false
        let viewModel = ArticleInboxViewModel(
            service: fixture.service,
            drainStaging: {
                if shouldFail { throw ReloadFailure.expected }
            }
        )
        await viewModel.reload()
        shouldFail = true

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

    func capture(id: String, capturedAt: String = "2026-07-28T12:01:00Z") -> ArticleCaptureRecord {
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
            packagePath: fileStore.root
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

private enum ReloadFailure: Error {
    case expected
}
