// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
import Foundation
import Observation
import UIKit
import WatchConnectivity

/// The phone owns webhook credentials and file-backed background uploads. Watch
/// captures are acknowledged only after local persistence, then again after 2xx.
@Observable @MainActor
final class WatchInboxRelay: NSObject, URLSessionTaskDelegate {
    static let shared = WatchInboxRelay()
    static let sessionIdentifier = "com.echo.audiobooks.watch-inbox"

    nonisolated private struct ConfigurationHistory: Codable {
        var currentID: UUID?
        var destinations: [WatchInboxWebhookConfiguration] = []
        var current: WatchInboxWebhookConfiguration? {
            destinations.first { $0.id == currentID }
        }
    }

    private(set) var pendingCount = 0
    private(set) var lastAcceptedAt: Date?
    private(set) var lastError: String?
    private(set) var isConfigured = false
    @ObservationIgnored private var history = ConfigurationHistory()
    @ObservationIgnored private var outbox: WatchInboxDeliveryQueue?
    @ObservationIgnored private var isScheduling = false
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        reloadConfiguration()
    }

    private func reloadConfiguration() {
        do {
            if let data = KeychainStore.data(for: .watchInboxWebhook) {
                history = try JSONDecoder().decode(ConfigurationHistory.self, from: data)
            }
            isConfigured = history.current != nil
        } catch {
            lastError = "Inbox setup could not be read. Your queued messages are kept."
        }
    }

    var configuredURL: String { history.current?.url.absoluteString ?? "" }

    func saveConfiguration(url: String, key: String) throws {
        let effectiveKey = key.isEmpty && url == configuredURL ? history.current?.key ?? "" : key
        let validated = try WatchInboxWebhookConfiguration(url: url, key: effectiveKey)
        // Credential repair stays attached to the same endpoint. A different URL
        // gets a new identity; captures already bound to an old URL never move.
        let existing = history.destinations.first { $0.url == validated.url }
        let configuration = try WatchInboxWebhookConfiguration(
            id: existing?.id ?? validated.id, url: url, key: effectiveKey)
        var next = history
        next.destinations.removeAll { $0.id == configuration.id }
        next.destinations.append(configuration)
        next.currentID = configuration.id
        guard KeychainStore.set(try JSONEncoder().encode(next), for: .watchInboxWebhook) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        history = next
        isConfigured = true
        lastError = nil
        try queue().bindUnconfigured(to: configuration.id)
        start()
    }

    /// Returns true when this is an inbox message, including a malformed one:
    /// malformed captures must never fall through to playback command handling.
    func receive(_ message: [String: Any], reply: (([String: Any]) -> Void)? = nil) -> Bool {
        guard message[WatchMessageKey.command] as? String == WatchInboxMessage.capture else { return false }
        do {
            guard let data = message[WatchInboxMessage.data] as? Data else {
                throw WatchInboxError.emptyText
            }
            let capture = try JSONDecoder().decode(WatchInboxCapture.self, from: data).validated()
            let queue = try queue()
            try queue.enqueue(capture, configurationID: history.currentID)
            let accepted = queue.hasAccepted(capture.id)
            let receipt = receipt(for: capture.id, accepted: accepted)
            reply?(receipt)
            sendReceipt(receipt)
            updateStatus()
            start()
        } catch {
            lastError = "A watch message could not be saved. It remains on your watch."
            reply?(["inboxError": true])
        }
        return true
    }

    func start() {
        guard !isScheduling,
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        // A background launch can precede the first device unlock. Retry the
        // Keychain read on later activation instead of keeping an empty setup.
        reloadConfiguration()
        isScheduling = true
        Task { @MainActor in
            defer { isScheduling = false }
            do {
                let queue = try queue()
                if let id = history.currentID { try queue.bindUnconfigured(to: id) }
                updateStatus()
                guard !queue.pending.isEmpty else { return }
                let tasks = await session.allTasks
                let activeIDs = Set(tasks.filter { $0.state != .completed && $0.state != .canceling }.compactMap(\.taskDescription))
                for entry in queue.pending where !activeIDs.contains(entry.id.uuidString) {
                    guard let configuration = history.destinations.first(where: { $0.id == entry.configurationID }) else { continue }
                    let file = try uploadURL(for: entry.id)
                    try entry.capture.webhookData().write(to: file, options: .atomic)
                    let task = session.uploadTask(with: try configuration.request(for: entry.capture), fromFile: file)
                    task.taskDescription = entry.id.uuidString
                    task.earliestBeginDate = max(.now, entry.nextAttemptAt)
                    task.resume()
                }
            } catch {
                lastError = "Inbox delivery is waiting. Your queued messages are kept."
            }
        }
    }

    private func queue() throws -> WatchInboxDeliveryQueue {
        if let outbox { return outbox }
        let queue = try WatchInboxDeliveryQueue(fileURL: WatchInboxDeliveryQueue.storageURL())
        outbox = queue
        return queue
    }

    private func uploadURL(for id: UUID) throws -> URL {
        let directory = try WatchInboxDeliveryQueue.storageURL().deletingLastPathComponent()
            .appendingPathComponent("Uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func updateStatus() {
        pendingCount = outbox?.pending.count ?? 0
        lastAcceptedAt = outbox?.lastAcceptedAt
    }

    private func receipt(for id: UUID, accepted: Bool) -> [String: Any] {
        [WatchMessageKey.command: WatchInboxMessage.receipt,
         WatchInboxMessage.id: id.uuidString, WatchInboxMessage.accepted: accepted]
    }

    private func sendReceipt(_ receipt: [String: Any]) {
        let connectivity = WCSession.default
        guard connectivity.activationState == .activated else { return }
        let alreadyQueued = connectivity.outstandingUserInfoTransfers.contains {
            $0.userInfo[WatchInboxMessage.id] as? String == receipt[WatchInboxMessage.id] as? String
                && $0.userInfo[WatchInboxMessage.accepted] as? Bool == receipt[WatchInboxMessage.accepted] as? Bool
        }
        if !alreadyQueued { connectivity.transferUserInfo(receipt) }
        if connectivity.isReachable {
            connectivity.sendMessage(receipt, replyHandler: nil, errorHandler: { @Sendable _ in })
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription.flatMap(UUID.init(uuidString:))
        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let url = response?.url
        let method = task.currentRequest?.httpMethod
        let failed = error != nil
        Task { @MainActor [weak self] in
            guard let self, let id else { return }
            do {
                let queue = try queue()
                guard let entry = queue.pending.first(where: { $0.id == id }),
                    let configuration = history.destinations.first(where: { $0.id == entry.configurationID })
                else { return }
                if !failed && configuration.accepts(status: status, url: url, method: method) {
                    try queue.accept(id)
                    try? FileManager.default.removeItem(at: uploadURL(for: id))
                    lastError = nil
                    sendReceipt(receipt(for: id, accepted: true))
                } else {
                    try queue.recordFailure(id)
                    lastError = "Delivery will retry. Your message is kept."
                }
                updateStatus()
                start()
            } catch {
                lastError = "The delivery receipt could not be saved. Your message is kept."
            }
        }
    }

    func reconnectBackgroundSession(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session
        start()
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            let completion = self?.backgroundCompletion
            self?.backgroundCompletion = nil
            completion?()
        }
    }
}

final class WatchInboxAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == WatchInboxRelay.sessionIdentifier else {
            completionHandler()
            return
        }
        WatchInboxRelay.shared.reconnectBackgroundSession(completion: completionHandler)
    }
}
#endif
