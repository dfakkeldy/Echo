// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct ArticleWebsiteCaptureCoordinatorTests {
    private let captureID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    private let capturedAt = Date(timeIntervalSince1970: 1_775_000_000)

    @Test func validURLIsNormalizedCapturedAndStagedAsURLFetch() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let capture = CaptureStub(results: [.success(payload())])
        let stage = StageStub()
        let inbox = fixture.inbox(articles: [inboxItem(id: captureID.uuidString)])
        let coordinator = makeCoordinator(inbox: inbox, capture: capture, stage: stage)
        coordinator.urlText = "HTTPS://example.com/articles/one#comments"

        #expect(coordinator.canSubmit)
        #expect(coordinator.validationMessage == nil)

        await coordinator.submit()

        #expect(capture.urls == [URL(string: "https://example.com/articles/one")!])
        let envelope = try #require(await stage.envelopes.first)
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.captureID == captureID)
        #expect(envelope.capturedAt == capturedAt)
        #expect(envelope.method == .urlFetch)
        #expect(envelope.sourceApplication == "com.echo.audiobooks")
        #expect(envelope.payload == payload())
        #expect(coordinator.phase == .success)
    }

    @Test func invalidURLShowsImmediateFeedbackWithoutStartingCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let capture = CaptureStub(results: [.success(payload())])
        let stage = StageStub()
        let inbox = fixture.inbox(articles: [])
        let coordinator = makeCoordinator(inbox: inbox, capture: capture, stage: stage)

        coordinator.urlText = "file:///private/article.html"

        #expect(coordinator.canSubmit == false)
        #expect(coordinator.validationMessage?.contains("HTTP") == true)
        await coordinator.submit()
        #expect(capture.urls.isEmpty)
        #expect(await stage.envelopes.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test func captureFailureIsActionableAndRetryable() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let capture = CaptureStub(results: [
            .failure(ArticleURLCaptureService.Error.authenticationRequired(message: "Sign in."))
        ])
        let stage = StageStub()
        let inbox = fixture.inbox(articles: [])
        let coordinator = makeCoordinator(inbox: inbox, capture: capture, stage: stage)
        coordinator.urlText = "https://example.com/members/article"

        await coordinator.submit()

        guard case .failure(let failureStage, let message) = coordinator.phase else {
            Issue.record("Expected capture failure state")
            return
        }
        #expect(failureStage == .capture)
        #expect(message.localizedCaseInsensitiveContains("public"))
        #expect(coordinator.retryAvailable)
        #expect(await stage.envelopes.isEmpty)
    }

    @Test func stagingFailureIsReportedWithoutReloadingInbox() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let capture = CaptureStub(results: [.success(payload())])
        let stage = StageStub(failures: [.staging])
        let reload = ReloadPlan(steps: [.success([])])
        let inbox = fixture.inbox(reloadPlan: reload)
        let coordinator = makeCoordinator(inbox: inbox, capture: capture, stage: stage)
        coordinator.urlText = "https://example.com/article"

        await coordinator.submit()

        guard case .failure(let failureStage, let message) = coordinator.phase else {
            Issue.record("Expected staging failure state")
            return
        }
        #expect(failureStage == .staging)
        #expect(message.localizedCaseInsensitiveContains("staging"))
        #expect(coordinator.retryAvailable)
        #expect(await reload.callCount == 0)
    }

    @Test func successfulReloadSelectsOnlyTheImportedCaptureByID() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let existingID = "00000000-0000-0000-0000-000000000001"
        let existing = inboxItem(id: existingID)
        let imported = inboxItem(id: captureID.uuidString)
        let capture = CaptureStub(results: [.success(payload())])
        let stage = StageStub()
        let inbox = fixture.inbox(articles: [existing, imported])
        inbox.articles = [existing]
        inbox.selectedIDs = [existingID]
        let coordinator = makeCoordinator(inbox: inbox, capture: capture, stage: stage)
        coordinator.urlText = "https://example.com/article"

        await coordinator.submit()

        #expect(inbox.articles.map(\.id) == [existingID, captureID.uuidString])
        #expect(inbox.selectedIDs == [existingID, captureID.uuidString])
        #expect(coordinator.phase == .success)
    }

    @Test func ingestionRetryDoesNotRecaptureOrRestageDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let existingID = "00000000-0000-0000-0000-000000000001"
        let existing = inboxItem(id: existingID, isPossibleDuplicate: true)
        let imported = inboxItem(id: captureID.uuidString, isPossibleDuplicate: true)
        let capture = CaptureStub(results: [.success(payload())])
        let stage = StageStub()
        let reload = ReloadPlan(steps: [
            .failure(.ingestion),
            .success([existing, imported]),
        ])
        let inbox = fixture.inbox(reloadPlan: reload)
        inbox.articles = [existing]
        let coordinator = makeCoordinator(inbox: inbox, capture: capture, stage: stage)
        coordinator.urlText = "https://example.com/article"

        await coordinator.submit()

        guard case .failure(let failureStage, _) = coordinator.phase else {
            Issue.record("Expected ingestion failure state")
            return
        }
        #expect(failureStage == .ingestion)
        #expect(coordinator.retryAvailable)

        await coordinator.retry()

        #expect(capture.urls.count == 1)
        #expect(await stage.envelopes.count == 1)
        #expect(await reload.callCount == 2)
        #expect(inbox.articles.map(\.isPossibleDuplicate) == [true, true])
        #expect(inbox.selectedIDs == [captureID.uuidString])
        #expect(coordinator.phase == .success)
    }

    private func makeCoordinator(
        inbox: ArticleInboxViewModel,
        capture: CaptureStub,
        stage: StageStub
    ) -> ArticleWebsiteCaptureCoordinator {
        ArticleWebsiteCaptureCoordinator(
            inbox: inbox,
            capture: { try await capture.capture(url: $0) },
            stage: { try await stage.stage($0) },
            now: { capturedAt },
            makeCaptureID: { captureID },
            sourceApplication: "com.echo.audiobooks")
    }

    private func payload() -> ReadabilityCapturePayload {
        ReadabilityCapturePayload(
            sourceURL: "https://example.com/article",
            canonicalURL: "https://example.com/article",
            title: "Example Article",
            byline: "Author",
            siteName: "Example",
            language: "en",
            publishedTime: nil,
            excerpt: "Summary",
            contentXHTML: "<article><p>Readable text.</p></article>",
            textContent: "Readable text.",
            imageURLs: [])
    }

    private func inboxItem(
        id: String,
        isPossibleDuplicate: Bool = false
    ) -> ArticleInboxItem {
        ArticleInboxItem(
            id: id,
            title: "Article",
            author: nil,
            siteName: "Example",
            sourceURL: "https://example.com/article",
            canonicalURL: "https://example.com/article",
            capturedAt: "2026-08-03T12:00:00Z",
            state: .ready,
            warnings: [],
            isPossibleDuplicate: isPossibleDuplicate,
            keepBothAvailable: true)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let database: DatabaseService
    let service: ArticleInboxService

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ArticleWebsiteCaptureCoordinatorTests-\(UUID().uuidString)",
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try DatabaseService(inMemory: ())
        service = ArticleInboxService(
            captureDAO: ArticleCaptureDAO(db: database.writer),
            anthologyDAO: AnthologyDAO(db: database.writer),
            fileStore: ArticleWorkshopFileStore(
                root: root.appending(path: "Workshop", directoryHint: .isDirectory)))
    }

    func inbox(articles: [ArticleInboxItem]) -> ArticleInboxViewModel {
        ArticleInboxViewModel(
            service: service,
            reloadWorker: ArticleInboxReloadWorker {
                ArticleInboxReloadResult(articles: articles, anthologies: [])
            })
    }

    func inbox(reloadPlan: ReloadPlan) -> ArticleInboxViewModel {
        ArticleInboxViewModel(
            service: service,
            reloadWorker: ArticleInboxReloadWorker {
                try await reloadPlan.next()
            })
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class CaptureStub {
    private var results: [Result<ReadabilityCapturePayload, Swift.Error>]
    private(set) var urls: [URL] = []

    init(results: [Result<ReadabilityCapturePayload, Swift.Error>]) {
        self.results = results
    }

    func capture(url: URL) async throws -> ReadabilityCapturePayload {
        urls.append(url)
        return try results.removeFirst().get()
    }
}

private actor StageStub {
    private var failures: [StubFailure]
    private(set) var envelopes: [ArticleCaptureEnvelope] = []

    init(failures: [StubFailure] = []) {
        self.failures = failures
    }

    func stage(_ envelope: ArticleCaptureEnvelope) throws {
        envelopes.append(envelope)
        if failures.isEmpty == false {
            throw failures.removeFirst()
        }
    }
}

private actor ReloadPlan {
    enum Step: Sendable {
        case success([ArticleInboxItem])
        case failure(StubFailure)
    }

    private var steps: [Step]
    private(set) var callCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func next() throws -> ArticleInboxReloadResult {
        callCount += 1
        switch steps.removeFirst() {
        case .success(let articles):
            return ArticleInboxReloadResult(articles: articles, anthologies: [])
        case .failure(let error):
            throw error
        }
    }
}

private enum StubFailure: Swift.Error, LocalizedError, Sendable {
    case staging
    case ingestion

    var errorDescription: String? {
        switch self {
        case .staging: "The staging folder is unavailable."
        case .ingestion: "The Inbox could not import the staged capture."
        }
    }
}
