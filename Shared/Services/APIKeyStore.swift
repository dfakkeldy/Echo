// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keychain-backed storage of per-provider AI tokens (BYO-token). The closure seams
/// default to `KeychainStore` and are overridden with an in-memory dictionary in tests.
@MainActor
final class APIKeyStore {
    private let service: String
    private let readData: (KeychainStore.Key, String) -> Data?
    private let writeData: (Data, KeychainStore.Key, String) -> Bool
    private let removeData: (KeychainStore.Key, String) -> Void

    init(
        service: String = "com.echo.audiobooks",
        readData: @escaping (KeychainStore.Key, String) -> Data? = {
            KeychainStore.data(for: $0, service: $1)
        },
        writeData: @escaping (Data, KeychainStore.Key, String) -> Bool = {
            KeychainStore.set($0, for: $1, service: $2)
        },
        removeData: @escaping (KeychainStore.Key, String) -> Void = {
            KeychainStore.remove($0, service: $1)
        }
    ) {
        self.service = service
        self.readData = readData
        self.writeData = writeData
        self.removeData = removeData
    }

    func token(for preset: AIProviderPreset) -> String? {
        string(for: preset.keychainKey)
    }

    /// Trims the token; nil/blank removes the entry.
    func setToken(_ token: String?, for preset: AIProviderPreset) {
        setString(token, for: preset.keychainKey)
    }

    /// The pre-provider-expansion `anthropicAPIKey` account. Migration-only.
    var anthropicKey: String? {
        get { string(for: .anthropicAPIKey) }
        set { setString(newValue, for: .anthropicAPIKey) }
    }

    private func string(for key: KeychainStore.Key) -> String? {
        readData(key, service)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private func setString(_ value: String?, for key: KeychainStore.Key) {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            let data = value.data(using: .utf8)
        {
            _ = writeData(data, key, service)
        } else {
            removeData(key, service)
        }
    }
}

extension AIProviderPreset {
    /// Keychain account for this provider's token (`aiProvider.<preset>`).
    var keychainKey: KeychainStore.Key {
        switch self {
        case .anthropic: .aiProviderAnthropic
        case .deepseek: .aiProviderDeepSeek
        case .kimi: .aiProviderKimi
        case .glm: .aiProviderGLM
        case .custom: .aiProviderCustom
        }
    }
}
