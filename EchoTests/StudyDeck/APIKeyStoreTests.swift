// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct APIKeyStoreTests {
    private final class MemoryKeychain {
        var storage: [String: Data] = [:]

        func store() -> APIKeyStore {
            APIKeyStore(
                service: "com.echo.test",
                readData: { key, _ in self.storage[key.rawValue] },
                writeData: { data, key, _ in
                    self.storage[key.rawValue] = data
                    return true
                },
                removeData: { key, _ in self.storage[key.rawValue] = nil }
            )
        }
    }

    @Test func perProviderTokensAreIsolated() {
        let keychain = MemoryKeychain()
        let store = keychain.store()
        store.setToken("sk-ant", for: .anthropic)
        store.setToken("sk-ds", for: .deepseek)

        #expect(store.token(for: .anthropic) == "sk-ant")
        #expect(store.token(for: .deepseek) == "sk-ds")
        #expect(store.token(for: .kimi) == nil)
        #expect(keychain.storage.keys.sorted() == ["aiProvider.anthropic", "aiProvider.deepseek"])
    }

    @Test func setTokenTrimsAndNilOrBlankRemoves() {
        let keychain = MemoryKeychain()
        let store = keychain.store()
        store.setToken("  sk-glm \n", for: .glm)

        #expect(store.token(for: .glm) == "sk-glm")
        store.setToken(nil, for: .glm)
        #expect(store.token(for: .glm) == nil)
        store.setToken("   ", for: .kimi)
        #expect(store.token(for: .kimi) == nil)
        #expect(keychain.storage.isEmpty)
    }

    @Test func legacyAccountIsDistinctFromPerProviderAccount() {
        let keychain = MemoryKeychain()
        let store = keychain.store()
        store.anthropicKey = "sk-legacy"

        #expect(store.token(for: .anthropic) == nil)
        #expect(keychain.storage.keys.sorted() == ["anthropicAPIKey"])
        store.anthropicKey = nil
        #expect(keychain.storage.isEmpty)
    }

    @Test func everyPresetHasAStableKeychainAccount() {
        #expect(AIProviderPreset.anthropic.keychainKey.rawValue == "aiProvider.anthropic")
        #expect(AIProviderPreset.deepseek.keychainKey.rawValue == "aiProvider.deepseek")
        #expect(AIProviderPreset.kimi.keychainKey.rawValue == "aiProvider.kimi")
        #expect(AIProviderPreset.glm.keychainKey.rawValue == "aiProvider.glm")
        #expect(AIProviderPreset.custom.keychainKey.rawValue == "aiProvider.custom")
    }
}
