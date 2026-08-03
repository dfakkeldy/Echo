// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

typealias ArticleWebsiteCaptureOperation =
    @MainActor @Sendable (URL) async throws -> ReadabilityCapturePayload
typealias ArticleWebsiteStagingOperation =
    @Sendable (ArticleCaptureEnvelope) async throws -> Void

actor ArticleWebsiteCaptureStagingWorker {
    private let operation: @Sendable (ArticleCaptureEnvelope) throws -> Void

    init(operation: @escaping @Sendable (ArticleCaptureEnvelope) throws -> Void) {
        self.operation = operation
    }

    func stage(_ envelope: ArticleCaptureEnvelope) throws {
        try Task.checkCancellation()
        try operation(envelope)
        try Task.checkCancellation()
    }
}

@MainActor
@Observable
final class ArticleWebsiteCaptureCoordinator {
    enum FailureStage: Equatable, Sendable {
        case capture
        case staging
        case ingestion
    }

    enum Phase: Equatable, Sendable {
        case idle
        case capturing
        case loading
        case success
        case failure(stage: FailureStage, message: String)
    }

    var urlText = "" {
        didSet {
            guard urlText != oldValue else { return }
            pendingEnvelope = nil
            isStaged = false
            if isBusy == false {
                phase = .idle
            }
        }
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let inbox: ArticleInboxViewModel
    @ObservationIgnored private let capture: ArticleWebsiteCaptureOperation
    @ObservationIgnored private let stage: ArticleWebsiteStagingOperation
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let makeCaptureID: @Sendable () -> UUID
    @ObservationIgnored private let sourceApplication: String?
    @ObservationIgnored private var pendingEnvelope: ArticleCaptureEnvelope?
    @ObservationIgnored private var isStaged = false

    var validationMessage: String? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, normalizedURL == nil else { return nil }
        return String(
            localized: "Enter a complete HTTP(S) website URL, such as https://example.com/article.")
    }

    var canSubmit: Bool {
        normalizedURL != nil && isBusy == false
    }

    var isBusy: Bool {
        switch phase {
        case .capturing, .loading:
            true
        case .idle, .success, .failure:
            false
        }
    }

    var retryAvailable: Bool {
        if case .failure = phase { return true }
        return false
    }

    init(
        inbox: ArticleInboxViewModel,
        capture: @escaping ArticleWebsiteCaptureOperation,
        stage: @escaping ArticleWebsiteStagingOperation,
        now: @escaping @Sendable () -> Date = Date.init,
        makeCaptureID: @escaping @Sendable () -> UUID = UUID.init,
        sourceApplication: String?
    ) {
        self.inbox = inbox
        self.capture = capture
        self.stage = stage
        self.now = now
        self.makeCaptureID = makeCaptureID
        self.sourceApplication = sourceApplication
    }

    convenience init(
        inbox: ArticleInboxViewModel,
        sourceApplication: String? = Bundle.main.bundleIdentifier
    ) {
        let captureService = ArticleURLCaptureService()
        let stagingWorker = ArticleWebsiteCaptureStagingWorker { envelope in
            let stagingRoot = try FileLocations.articleCaptureStagingDirectory()
            _ = try ArticleCaptureStagingWriter(root: stagingRoot).stage(envelope)
        }
        self.init(
            inbox: inbox,
            capture: { url in
                try await captureService.capture(url: url)
            },
            stage: { envelope in
                try await stagingWorker.stage(envelope)
            },
            sourceApplication: sourceApplication)
    }

    func submit() async {
        guard isBusy == false, let url = normalizedURL else { return }
        if retryAvailable == false {
            pendingEnvelope = nil
            isStaged = false
        }
        await run(url: url)
    }

    func retry() async {
        guard retryAvailable, isBusy == false, let url = normalizedURL else { return }
        await run(url: url)
    }

    private var normalizedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let url = URL(string: trimmed) else { return nil }
        return ArticleNetworkURLPolicy.normalized(url)
    }

    private func run(url: URL) async {
        let envelope: ArticleCaptureEnvelope
        if let pendingEnvelope {
            envelope = pendingEnvelope
        } else {
            phase = .capturing
            do {
                let payload = try await capture(url)
                try Task.checkCancellation()
                envelope = ArticleCaptureEnvelope(
                    schemaVersion: 1,
                    captureID: makeCaptureID(),
                    capturedAt: now(),
                    method: .urlFetch,
                    sourceApplication: sourceApplication,
                    payload: payload)
                pendingEnvelope = envelope
            } catch is CancellationError {
                phase = .idle
                return
            } catch {
                phase = .failure(stage: .capture, message: Self.captureMessage(for: error))
                return
            }
        }

        phase = .loading
        if isStaged == false {
            do {
                try await stage(envelope)
                try Task.checkCancellation()
                isStaged = true
            } catch is CancellationError {
                phase = .idle
                return
            } catch {
                phase = .failure(stage: .staging, message: Self.stagingMessage(for: error))
                return
            }
        }

        await inbox.reload()
        guard Task.isCancelled == false else {
            phase = .idle
            return
        }
        if let message = inbox.errorMessage {
            phase = .failure(
                stage: .ingestion,
                message: Self.ingestionMessage(detail: message))
            return
        }

        let captureID = envelope.captureID.uuidString
        guard let imported = inbox.articles.first(where: { $0.id == captureID }) else {
            phase = .failure(
                stage: .ingestion,
                message: Self.ingestionMessage(
                    detail: String(localized: "The staged capture was not found after reloading.")))
            return
        }
        guard imported.isAnthologyEligible else {
            phase = .failure(
                stage: .ingestion,
                message: Self.ingestionMessage(
                    detail: String(
                        localized: "The imported capture needs attention before it can be selected."
                    )))
            return
        }
        if inbox.selectedIDs.contains(captureID) == false {
            inbox.toggleSelection(captureID)
        }
        pendingEnvelope = nil
        isStaged = false
        phase = .success
    }

    private static func captureMessage(for error: any Swift.Error) -> String {
        if let captureError = error as? ArticleURLCaptureService.Error,
            case .authenticationRequired = captureError
        {
            return String(
                localized: "This website requires sign-in. Add Website supports public pages only.")
        }
        return String(
            localized:
                "\(error.localizedDescription) Check that the URL is a public article and that your internet connection is available, then retry."
        )
    }

    private static func stagingMessage(for error: any Swift.Error) -> String {
        String(
            localized:
                "Echo could not publish this capture to staging. \(error.localizedDescription) Check that app storage is available, then retry."
        )
    }

    private static func ingestionMessage(detail: String) -> String {
        String(
            localized:
                "Echo staged the website, but the Inbox could not import it. \(detail) Retry to reload the Inbox without capturing it again."
        )
    }
}
