// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Persistence facade for AI provider config, per-provider token access, and
/// one-time migration of the legacy single-key Anthropic setup.
@MainActor
final class AIProviderSettingsStore {
    static let configKey = "ai.provider.config"
    static let preferenceKey = "ai.provider.preference"
    static let legacyModelKey = "ai.cardgen.model"
    static let legacyProviderKey = "ai.cardgen.provider"

    private let defaults: UserDefaults
    private let keyStore: APIKeyStore
    private let logger = Logger(category: "AIProviderSettingsStore")

    init(defaults: UserDefaults = .standard, keyStore: APIKeyStore = APIKeyStore()) {
        self.defaults = defaults
        self.keyStore = keyStore
    }

    var config: AIProviderConfig? {
        get {
            migrateLegacyIfNeeded()
            guard let data = defaults.data(forKey: Self.configKey) else { return nil }
            return try? JSONDecoder().decode(AIProviderConfig.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.configKey)
                return
            }
            defaults.set(data, forKey: Self.configKey)
        }
    }

    var generatorPreference: StudyDeckGeneratorPreference {
        get {
            StudyDeckGeneratorPreference(
                rawValue: defaults.string(forKey: Self.preferenceKey) ?? "auto"
            ) ?? .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Self.preferenceKey) }
    }

    func token(for preset: AIProviderPreset) -> String? {
        keyStore.token(for: preset)
    }

    func setToken(_ token: String?, for preset: AIProviderPreset) {
        keyStore.setToken(token, for: preset)
    }

    var hasConfiguredCloudProvider: Bool {
        guard let config,
            config.consented,
            !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !config.primaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            keyStore.token(for: config.preset) != nil
        else {
            return false
        }
        return true
    }

    func migrateLegacyIfNeeded() {
        if let legacyPreference = defaults.string(forKey: Self.legacyProviderKey) {
            if defaults.string(forKey: Self.preferenceKey) == nil {
                defaults.set(legacyPreference, forKey: Self.preferenceKey)
            }
            defaults.removeObject(forKey: Self.legacyProviderKey)
        }

        guard let legacyKey = keyStore.anthropicKey else {
            defaults.removeObject(forKey: Self.legacyModelKey)
            return
        }

        if defaults.data(forKey: Self.configKey) == nil {
            var migrated = AIProviderConfig.defaults(for: .anthropic)
            if let legacyModel = defaults.string(forKey: Self.legacyModelKey) {
                migrated.primaryModel = legacyModel
            }
            migrated.consented = true
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: Self.configKey)
            }
            logger.info("Migrated legacy Anthropic key into AIProviderConfig")
        }

        if keyStore.token(for: .anthropic) == nil {
            keyStore.setToken(legacyKey, for: .anthropic)
        }
        keyStore.anthropicKey = nil
        defaults.removeObject(forKey: Self.legacyModelKey)
    }
}
