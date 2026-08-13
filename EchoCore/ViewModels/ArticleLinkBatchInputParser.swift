// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

nonisolated enum ArticleLinkBatchInputParser {
    struct Row: Equatable, Sendable {
        let lineNumber: Int
        let originalText: String
        let validation: Validation
    }

    enum Validation: Equatable, Sendable {
        case valid(URL)
        case duplicate(URL, firstLineNumber: Int)
        case invalid
    }

    static func parse(_ text: String) -> [Row] {
        var firstLineByURL: [String: Int] = [:]
        var rows: [Row] = []

        for (offset, rawLine) in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let lineNumber = offset + 1
            let value = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty == false else { continue }

            let validation: Validation
            if let url = URL(string: value),
                let normalized = ArticleNetworkURLPolicy.normalized(url)
            {
                let key = normalized.absoluteString
                if let firstLineNumber = firstLineByURL[key] {
                    validation = .duplicate(normalized, firstLineNumber: firstLineNumber)
                } else {
                    firstLineByURL[key] = lineNumber
                    validation = .valid(normalized)
                }
            } else {
                validation = .invalid
            }

            rows.append(
                Row(
                    lineNumber: lineNumber,
                    originalText: value,
                    validation: validation))
        }

        return rows
    }
}

@MainActor
@Observable
final class ArticleLinkBatchCoordinator {
    enum CaptureOutcome: Equatable, Sendable {
        case success(captureID: String)
        case failure(message: String)
        case cancelled
    }

    struct CaptureAttempt {
        private let operation: @MainActor @Sendable () async -> CaptureOutcome

        init(_ operation: @escaping @MainActor @Sendable () async -> CaptureOutcome) {
            self.operation = operation
        }

        func run() async -> CaptureOutcome {
            await operation()
        }
    }

    struct Row: Equatable, Identifiable, Sendable {
        let id: Int
        let lineNumber: Int
        let originalText: String
        let url: URL?
        var status: Status
    }

    enum Status: Equatable, Sendable {
        case queued
        case capturing
        case succeeded(captureID: String)
        case failed(message: String)
        case duplicate(firstLineNumber: Int)
        case invalid
    }

    typealias CaptureFactory = @MainActor @Sendable (URL) -> CaptureAttempt

    var title = ""
    var linkText = "" {
        didSet {
            guard linkText != oldValue, isRunning == false else { return }
            rebuildRows()
        }
    }

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var createdAnthology: AnthologyRecord?
    private(set) var creationError: String?

    @ObservationIgnored private let inbox: ArticleInboxViewModel
    @ObservationIgnored private let captureFactory: CaptureFactory
    @ObservationIgnored private var attempts: [Int: CaptureAttempt] = [:]

    var canStart: Bool {
        isRunning == false
            && trimmedTitle.isEmpty == false
            && rows.contains(where: { $0.status == .queued })
            && rows.contains(where: { $0.status == .invalid }) == false
    }

    init(
        inbox: ArticleInboxViewModel,
        captureFactory: @escaping CaptureFactory
    ) {
        self.inbox = inbox
        self.captureFactory = captureFactory
    }

    convenience init(inbox: ArticleInboxViewModel) {
        self.init(
            inbox: inbox,
            captureFactory: { url in
                let coordinator = ArticleWebsiteCaptureCoordinator(
                    inbox: inbox,
                    selectOnSuccess: false)
                coordinator.urlText = url.absoluteString
                return CaptureAttempt {
                    let captureID: String?
                    if coordinator.retryAvailable {
                        captureID = await coordinator.retry()
                    } else {
                        captureID = await coordinator.submit()
                    }
                    if let captureID {
                        return .success(captureID: captureID)
                    }
                    if case .failure(_, let message) = coordinator.phase {
                        return .failure(message: message)
                    }
                    return .cancelled
                }
            })
    }

    func captureAndCreate() async {
        guard canStart else { return }
        isRunning = true
        creationError = nil
        defer { isRunning = false }

        for index in rows.indices where rows[index].status == .queued {
            guard Task.isCancelled == false, let url = rows[index].url else { return }
            rows[index].status = .capturing
            let attempt = attempts[rows[index].id] ?? captureFactory(url)
            attempts[rows[index].id] = attempt

            switch await attempt.run() {
            case .success(let captureID):
                rows[index].status = .succeeded(captureID: captureID)
            case .failure(let message):
                rows[index].status = .failed(message: message)
            case .cancelled:
                rows[index].status = .queued
                return
            }
        }

        guard Task.isCancelled == false,
            rows.contains(where: {
                if case .failed = $0.status { return true }
                return false
            }) == false
        else { return }

        createAnthologyFromSuccesses()
    }

    func retryFailures() async {
        guard isRunning == false, createdAnthology == nil else { return }
        let failedRowIDs = rows.compactMap { row -> Int? in
            guard case .failed = row.status else { return nil }
            return row.id
        }
        guard failedRowIDs.isEmpty == false else { return }

        isRunning = true
        creationError = nil
        defer { isRunning = false }

        for rowID in failedRowIDs {
            guard Task.isCancelled == false,
                let index = rows.firstIndex(where: { $0.id == rowID }),
                let url = rows[index].url,
                case .failed(let previousMessage) = rows[index].status
            else { return }

            rows[index].status = .capturing
            let attempt = attempts[rowID] ?? captureFactory(url)
            attempts[rowID] = attempt

            switch await attempt.run() {
            case .success(let captureID):
                rows[index].status = .succeeded(captureID: captureID)
            case .failure(let message):
                rows[index].status = .failed(message: message)
            case .cancelled:
                rows[index].status = .failed(message: previousMessage)
                return
            }
        }

        guard Task.isCancelled == false else { return }
        createAnthologyFromSuccesses()
    }

    func createWithSuccesses() {
        guard isRunning == false,
            createdAnthology == nil,
            rows.contains(where: {
                if case .succeeded = $0.status { return true }
                return false
            })
        else { return }

        creationError = nil
        createAnthologyFromSuccesses()
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildRows() {
        attempts.removeAll()
        createdAnthology = nil
        creationError = nil
        rows = ArticleLinkBatchInputParser.parse(linkText).map { input in
            switch input.validation {
            case .valid(let url):
                Row(
                    id: input.lineNumber,
                    lineNumber: input.lineNumber,
                    originalText: input.originalText,
                    url: url,
                    status: .queued)
            case .duplicate(let url, let firstLineNumber):
                Row(
                    id: input.lineNumber,
                    lineNumber: input.lineNumber,
                    originalText: input.originalText,
                    url: url,
                    status: .duplicate(firstLineNumber: firstLineNumber))
            case .invalid:
                Row(
                    id: input.lineNumber,
                    lineNumber: input.lineNumber,
                    originalText: input.originalText,
                    url: nil,
                    status: .invalid)
            }
        }
    }

    private func createAnthologyFromSuccesses() {
        let captureIDs = rows.compactMap { row -> String? in
            guard case .succeeded(let captureID) = row.status else { return nil }
            return captureID
        }
        guard captureIDs.isEmpty == false else { return }
        do {
            createdAnthology = try inbox.createAnthology(
                title: trimmedTitle,
                orderedCaptureIDs: captureIDs)
        } catch {
            creationError = error.localizedDescription
        }
    }
}
