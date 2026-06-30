// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keychain-backed storage of the user's Anthropic API key (BYO-key). Mirrors
/// ABSTokenStore's per-service Keychain pattern.
@MainActor
final class APIKeyStore {
    private let service: String

    init(service: String = "com.echo.audiobooks") {
        self.service = service
    }

    var anthropicKey: String? {
        get {
            KeychainStore.data(for: .anthropicAPIKey, service: service)
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        set {
            if let key = newValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty, let data = key.data(using: .utf8)
            {
                KeychainStore.set(data, for: .anthropicAPIKey, service: service)
            } else {
                KeychainStore.remove(.anthropicAPIKey, service: service)
            }
        }
    }

    var hasKey: Bool { anthropicKey != nil }

    func clear() { KeychainStore.remove(.anthropicAPIKey, service: service) }
}
