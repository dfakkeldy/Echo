// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated enum WatchInboxError: LocalizedError {
    case emptyText, textTooLong, invalidWebhook, conflictingCapture, invalidContext

    var errorDescription: String? {
        switch self {
        case .emptyText: "No dictation was captured."
        case .textTooLong: "This message is too long. Please send a shorter thought."
        case .invalidWebhook: "Enter an HTTPS webhook URL and its key."
        case .conflictingCapture: "A different message already uses this capture ID."
        case .invalidContext: "The listening position could not be saved. Please try dictation again."
        }
    }
}

/// The text and listening context are frozen before delivery can be deferred.
/// Context is optional: inbox capture never requires an active book.
nonisolated struct WatchInboxCapture: Codable, Equatable, Sendable, Identifiable {
    struct Context: Codable, Equatable, Sendable {
        let title: String
        let position: TimeInterval
    }

    let id: UUID
    let text: String
    let capturedAt: Date
    let utcOffset: Int
    let context: Context?

    init(
        id: UUID = UUID(), text: String, capturedAt: Date = .now,
        utcOffset: Int = TimeZone.current.secondsFromGMT(), context: Context? = nil
    ) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WatchInboxError.emptyText
        }
        // Leaves ample room inside WatchConnectivity's user-info payload limit.
        guard text.utf8.count <= 32_768 else { throw WatchInboxError.textTooLong }
        guard capturedAt.timeIntervalSince1970.isFinite, (-86_400...86_400).contains(utcOffset),
            context.map({ $0.position.isFinite && $0.position >= 0 && $0.title.utf8.count <= 4096 }) ?? true
        else { throw WatchInboxError.invalidContext }
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.utcOffset = utcOffset
        self.context = context
    }

    func validated() throws -> Self {
        try Self(id: id, text: text, capturedAt: capturedAt, utcOffset: utcOffset, context: context)
    }

    func webhookData() throws -> Data {
        struct Body: Encodable {
            let id: String
            let text: String
            let capturedAt: String
            let source = "echo-watch"
            let context: Context?
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffset) ?? .gmt
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Body(
            id: id.uuidString, text: text, capturedAt: formatter.string(from: capturedAt),
            context: context))
    }

    func fingerprint() throws -> String {
        // Hash the complete immutable capture; receipts need not retain note text.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum WatchInboxMessage {
    static let capture = "captureInbox"
    static let receipt = "inboxReceipt"
    static let data = "inboxCapture"
    static let id = "inboxCaptureID"
    static let accepted = "inboxAccepted"
}

nonisolated struct WatchInboxWebhookConfiguration: Codable, Sendable {
    let id: UUID
    let url: URL
    let key: String

    init(id: UUID = UUID(), url: String, key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
            endpoint.scheme?.lowercased() == "https", endpoint.host != nil,
            endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
            !key.isEmpty, !key.contains("\n"), !key.contains("\r")
        else { throw WatchInboxError.invalidWebhook }
        self.id = id
        self.url = endpoint
        self.key = key
    }

    func request(for capture: WatchInboxCapture) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(capture.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    func accepts(status: Int, url: URL?, method: String?) -> Bool {
        (200..<300).contains(status) && url == self.url && method == "POST"
    }
}

/// Reconcile background requests with the latest credentials before uploading.
/// Replacements retain the capture's UUID, payload and original destination.
nonisolated struct WatchInboxUploadPlan {
    struct ScheduledTask: Sendable {
        let identifier: Int
        let captureID: UUID?
        let request: URLRequest?
        let isActive: Bool
    }

    struct Upload: Sendable {
        let entry: WatchInboxDeliveryQueue.Pending
        let request: URLRequest
        let sendImmediately: Bool
    }

    let taskIdentifiersToCancel: Set<Int>
    let uploads: [Upload]

    init(
        pending: [WatchInboxDeliveryQueue.Pending],
        configurations: [WatchInboxWebhookConfiguration],
        tasks: [ScheduledTask], retrying: Set<UUID> = []
    ) throws {
        var cancelled: Set<Int> = []
        var uploads: [Upload] = []
        for entry in pending {
            guard
                let configuration = configurations.first(where: { $0.id == entry.configurationID })
            else { continue }
            let request = try configuration.request(for: entry.capture)
            let active = tasks.filter { $0.isActive && $0.captureID == entry.id }
            let obsolete = active.filter { task in
                retrying.contains(entry.id)
                    || task.request?.url != request.url
                    || task.request?.httpMethod != request.httpMethod
                    || task.request?.value(forHTTPHeaderField: "Authorization")
                        != request.value(forHTTPHeaderField: "Authorization")
            }
            cancelled.formUnion(obsolete.map(\.identifier))
            guard active.allSatisfy({ cancelled.contains($0.identifier) }) else { continue }
            uploads.append(
                Upload(
                    entry: entry, request: request,
                    sendImmediately: retrying.contains(entry.id) || !obsolete.isEmpty))
        }
        taskIdentifiersToCancel = cancelled
        self.uploads = uploads
    }
}

/// Both devices keep a durable copy until the configured endpoint accepts it.
/// The phone's receipt history prevents a delayed watch retry from sending again.
@MainActor
final class WatchInboxDeliveryQueue {
    nonisolated struct Pending: Codable, Equatable, Sendable, Identifiable {
        let capture: WatchInboxCapture
        var configurationID: UUID?
        var isOnPhone = false
        var attempts = 0
        var nextAttemptAt = Date.distantPast
        var id: UUID { capture.id }
    }

    private struct State: Codable {
        var pending: [Pending] = []
        var receipts: [String: String] = [:]
        var lastAcceptedAt: Date?
    }

    private let fileURL: URL
    private var state: State
    var pending: [Pending] { state.pending }
    var lastAcceptedAt: Date? { state.lastAcceptedAt }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
        } else {
            state = State()
        }
    }

    static func storageURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("WatchInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("outbox.json")
    }

    @discardableResult
    func enqueue(_ capture: WatchInboxCapture, configurationID: UUID? = nil) throws -> Bool {
        _ = try capture.validated()
        if let fingerprint = state.receipts[capture.id.uuidString] {
            guard fingerprint == (try capture.fingerprint()) else { throw WatchInboxError.conflictingCapture }
            return false
        }
        if let existing = pending.first(where: { $0.id == capture.id }) {
            guard existing.capture == capture else { throw WatchInboxError.conflictingCapture }
            return false
        }
        try update { $0.pending.append(Pending(capture: capture, configurationID: configurationID)) }
        return true
    }

    func hasAccepted(_ id: UUID) -> Bool { state.receipts[id.uuidString] != nil }

    func markOnPhone(_ id: UUID) throws {
        try update { state in
            if let index = state.pending.firstIndex(where: { $0.id == id }) {
                state.pending[index].isOnPhone = true
            }
        }
    }

    func bindUnconfigured(to id: UUID) throws {
        try update { state in
            for index in state.pending.indices where state.pending[index].configurationID == nil {
                state.pending[index].configurationID = id
            }
        }
    }

    func recordFailure(_ id: UUID, at date: Date = .now) throws {
        try update { state in
            guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return }
            state.pending[index].attempts += 1
            let delay = min(3600, 5 * pow(2, Double(min(state.pending[index].attempts, 10))))
            state.pending[index].nextAttemptAt = date.addingTimeInterval(delay)
        }
    }

    @discardableResult
    func retryPending(configurationID: UUID? = nil, at date: Date = .now) throws -> Set<UUID> {
        var ids: Set<UUID> = []
        try update { state in
            for index in state.pending.indices
            where configurationID == nil || state.pending[index].configurationID == configurationID
            {
                state.pending[index].nextAttemptAt = date
                ids.insert(state.pending[index].id)
            }
        }
        return ids
    }

    func accept(_ id: UUID, at date: Date = .now) throws {
        try update { state in
            guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return }
            let capture = state.pending.remove(at: index).capture
            state.receipts[id.uuidString] = try capture.fingerprint()
            state.lastAcceptedAt = date
        }
    }

    private func update(_ change: (inout State) throws -> Void) throws {
        var next = state
        try change(&next)
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        state = next
    }
}
