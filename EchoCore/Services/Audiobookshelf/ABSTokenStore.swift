// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Per-server token storage for Audiobookshelf.
/// - accessToken: short-lived JWT, memory-only (lost on relaunch; re-minted via refresh).
/// - refreshToken: long-lived, persisted in the Keychain, namespaced per server via `service:`.
@MainActor
final class ABSTokenStore {
    let serverID: String
    private let service: String

    init(serverID: String) {
        self.serverID = serverID
        self.service = "com.echo.abs.\(serverID)"
    }

    /// In-memory only. Not persisted.
    var accessToken: String?

    var refreshToken: String? {
        get {
            KeychainStore.data(for: .absRefreshToken, service: service)
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        set {
            if let token = newValue, let data = token.data(using: .utf8) {
                KeychainStore.set(data, for: .absRefreshToken, service: service)
            } else {
                KeychainStore.remove(.absRefreshToken, service: service)
            }
        }
    }

    func clear() {
        accessToken = nil
        KeychainStore.remove(.absRefreshToken, service: service)
    }
}
