// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keeps an in-progress server connection in its own token namespace until login succeeds.
struct ABSServerConnectionIdentity {
    private(set) var activeServerID: String?
    private(set) var pendingServerID: String?
    private let makeID: () -> String

    init(
        activeServerID: String? = nil,
        makeID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.activeServerID = activeServerID
        self.makeID = makeID
    }

    mutating func prepareNewConnection() -> String {
        if let pendingServerID { return pendingServerID }
        let serverID = makeID()
        pendingServerID = serverID
        return serverID
    }

    @discardableResult
    mutating func activatePendingConnection() -> String? {
        guard let pendingServerID else { return nil }
        activeServerID = pendingServerID
        self.pendingServerID = nil
        return pendingServerID
    }

    mutating func activate(_ serverID: String) {
        activeServerID = serverID
        pendingServerID = nil
    }

    mutating func discardPendingConnection() {
        pendingServerID = nil
    }

    mutating func clearActiveConnection() {
        activeServerID = nil
    }
}

/// Performs the credential half of abandoning a failed pending connection while preserving the
/// already-active server identity. The caller remains responsible for invalidating its URL session.
@MainActor
enum ABSPendingConnectionCleanup {
    static func discard(
        identity: inout ABSServerConnectionIdentity,
        tokens: ABSTokenStore
    ) {
        guard identity.pendingServerID == tokens.serverID else { return }
        tokens.clear()
        identity.discardPendingConnection()
    }
}
