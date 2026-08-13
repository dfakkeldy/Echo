// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AIProviderSettingsStoreTests {
    private final class MemoryKeychain {
        var storage: [String: Data] = [:]

        func keyStore() -> APIKeyStore {
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

    private func makeDefaults() throws -> UserDefaults {
        let suite = "ai-provider-store-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallHasNoConfigAndAutoPreference() throws {
        let store = AIProviderSettingsStore(
            defaults: try makeDefaults(),
            keyStore: MemoryKeychain().keyStore()
        )

        #expect(store.config == nil)
        #expect(store.generatorPreference == .auto)
        #expect(!store.hasConfiguredCloudProvider)
    }

    @Test func configRoundTripsAndNilClears() throws {
        let store = AIProviderSettingsStore(
            defaults: try makeDefaults(),
            keyStore: MemoryKeychain().keyStore()
        )
        var config = AIProviderConfig.defaults(for: .deepseek)
        config.consented = true
        store.config = config

        #expect(store.config == config)
        store.config = nil
        #expect(store.config == nil)
    }

    @Test func generatorPreferenceRoundTrips() throws {
        let store = AIProviderSettingsStore(
            defaults: try makeDefaults(),
            keyStore: MemoryKeychain().keyStore()
        )
        store.generatorPreference = .onDevice
        #expect(store.generatorPreference == .onDevice)
    }

    @Test func legacyAnthropicSetupMigratesOnFirstRead() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        keychain.storage["anthropicAPIKey"] = Data("sk-legacy".utf8)
        defaults.set("claude-sonnet-4-6", forKey: AIProviderSettingsStore.legacyModelKey)
        defaults.set("cloud", forKey: AIProviderSettingsStore.legacyProviderKey)

        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())
        let config = try #require(store.config)

        #expect(config.preset == .anthropic)
        #expect(config.primaryModel == "claude-sonnet-4-6")
        #expect(config.consented)
        #expect(store.generatorPreference == .cloud)
        #expect(store.token(for: .anthropic) == "sk-legacy")
        #expect(keychain.storage["anthropicAPIKey"] == nil)
        #expect(defaults.string(forKey: AIProviderSettingsStore.legacyModelKey) == nil)
        #expect(defaults.string(forKey: AIProviderSettingsStore.legacyProviderKey) == nil)
    }

    @Test func migrationNeverClobbersAnExistingPerProviderToken() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        keychain.storage["anthropicAPIKey"] = Data("sk-stale".utf8)
        keychain.storage["aiProvider.anthropic"] = Data("sk-current".utf8)

        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())
        _ = store.config

        #expect(store.token(for: .anthropic) == "sk-current")
        #expect(keychain.storage["anthropicAPIKey"] == nil)
    }

    @Test func migrationDoesNotOverwriteAnExistingNewStyleConfig() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        keychain.storage["anthropicAPIKey"] = Data("sk-legacy".utf8)
        var existing = AIProviderConfig.defaults(for: .deepseek)
        existing.consented = true
        defaults.set(try JSONEncoder().encode(existing), forKey: AIProviderSettingsStore.configKey)

        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())

        #expect(store.config == existing)
        #expect(store.token(for: .anthropic) == "sk-legacy")
        #expect(keychain.storage["anthropicAPIKey"] == nil)
    }

    @Test func hasConfiguredCloudProviderRequiresConsentAndToken() throws {
        let defaults = try makeDefaults()
        let keychain = MemoryKeychain()
        let store = AIProviderSettingsStore(defaults: defaults, keyStore: keychain.keyStore())
        var config = AIProviderConfig.defaults(for: .deepseek)
        config.consented = false
        store.config = config
        store.setToken("sk-ds", for: .deepseek)
        #expect(!store.hasConfiguredCloudProvider)

        config.consented = true
        store.config = config
        #expect(store.hasConfiguredCloudProvider)

        store.setToken(nil, for: .deepseek)
        #expect(!store.hasConfiguredCloudProvider)

        store.setToken("sk-ds", for: .deepseek)
        config.baseURL = "   "
        store.config = config
        #expect(!store.hasConfiguredCloudProvider)
    }
}
