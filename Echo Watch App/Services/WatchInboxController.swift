// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import WatchConnectivity

@Observable @MainActor
final class WatchInboxController {
    private(set) var pendingCount = 0
    private(set) var lastAcceptedAt: Date?
    private(set) var lastError: String?
    @ObservationIgnored private var outbox: WatchInboxDeliveryQueue?

    func save(_ capture: WatchInboxCapture) throws {
        let queue = try queue()
        try queue.enqueue(capture)
        lastError = nil
        updateStatus()
        flush()
    }

    func flush() {
        do {
            let queue = try queue()
            updateStatus()
            let session = WCSession.default
            guard session.activationState == .activated else { return }
            for entry in queue.pending {
                let payload: [String: Any] = [
                    WatchMessageKey.command: WatchInboxMessage.capture,
                    WatchInboxMessage.id: entry.id.uuidString,
                    WatchInboxMessage.data: try JSONEncoder().encode(entry.capture),
                ]
                let alreadyQueued = session.outstandingUserInfoTransfers.contains {
                    $0.userInfo[WatchInboxMessage.id] as? String == entry.id.uuidString
                }
                if !alreadyQueued { session.transferUserInfo(payload) }
                if session.isReachable {
                    session.sendMessage(payload, replyHandler: { @Sendable [weak self] reply in
                        // Snapshot only Sendable receipt values before crossing actors.
                        let id = reply[WatchInboxMessage.id] as? String
                        let accepted = reply[WatchInboxMessage.accepted] as? Bool
                        Task { @MainActor [weak self] in
                            guard let id, let accepted else { return }
                            self?.receive(id: id, accepted: accepted)
                        }
                    }, errorHandler: { @Sendable _ in })
                }
            }
        } catch {
            lastError = "Inbox is waiting. Your saved messages are kept."
        }
    }

    @discardableResult
    func receive(_ message: [String: Any]) -> Bool {
        guard message[WatchMessageKey.command] as? String == WatchInboxMessage.receipt else { return false }
        if let id = message[WatchInboxMessage.id] as? String,
            let accepted = message[WatchInboxMessage.accepted] as? Bool
        {
            receive(id: id, accepted: accepted)
        }
        return true
    }

    private func receive(id: String, accepted: Bool) {
        guard let uuid = UUID(uuidString: id) else { return }
        do {
            let queue = try queue()
            guard queue.pending.contains(where: { $0.id == uuid }) else { return }
            if accepted { try queue.accept(uuid) } else { try queue.markOnPhone(uuid) }
            // The phone has persisted this capture. Cancel redundant transfers;
            // retain the local copy until the webhook's acceptance arrives.
            for transfer in WCSession.default.outstandingUserInfoTransfers
            where transfer.userInfo[WatchInboxMessage.id] as? String == id {
                transfer.cancel()
            }
            lastError = nil
            updateStatus()
        } catch {
            lastError = "The delivery receipt could not be saved. Your message is kept."
        }
    }

    private func queue() throws -> WatchInboxDeliveryQueue {
        if let outbox { return outbox }
        let queue = try WatchInboxDeliveryQueue(fileURL: WatchInboxDeliveryQueue.storageURL())
        outbox = queue
        return queue
    }

    private func updateStatus() {
        pendingCount = outbox?.pending.count ?? 0
        lastAcceptedAt = outbox?.lastAcceptedAt
    }
}
