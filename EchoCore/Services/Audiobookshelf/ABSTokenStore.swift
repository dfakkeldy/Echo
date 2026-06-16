// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Per-server token storage: the access token lives in memory (cleared on restart),
/// while the refresh token is persisted in the Keychain. Both are tied to a
/// server UUID so a future multi-server world keeps tokens apart.
@MainActor
final class ABSTokenStore {
    let serverID: String
    private var _accessToken: String?

    var accessToken: String? { _accessToken }
    var refreshToken: String? {
        guard let data = KeychainStore.data(for: .absRefreshToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init(serverID: String) {
        self.serverID = serverID
    }

    /// Called after successful login or token refresh.
    func setTokens(access: String, refresh: String?) {
        _accessToken = access
        if let refresh, let data = refresh.data(using: .utf8) {
            KeychainStore.set(data, for: .absRefreshToken)
        }
    }

    /// Apply a rotated access token from a refresh response.
    func updateAccessToken(_ token: String) {
        _accessToken = token
    }

    /// Discard all tokens — sign-out.
    func clear() {
        _accessToken = nil
        KeychainStore.remove(.absRefreshToken)
    }
}
