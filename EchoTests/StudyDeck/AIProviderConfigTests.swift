// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AIProviderConfigTests {
    @Test func anthropicPresetIsFullCapability() {
        let config = AIProviderConfig.defaults(for: .anthropic)
        #expect(config.baseURL == "https://api.anthropic.com")
        #expect(config.authStyle == .xAPIKey)
        #expect(config.capabilities == .full)
        #expect(config.primaryModel == "claude-opus-4-8")
        #expect(config.lightModel == "claude-haiku-4-5")
        #expect(!config.consented)
    }

    @Test(arguments: [AIProviderPreset.deepseek, .kimi, .glm, .custom])
    func compatPresetsAreConservativeBearer(preset: AIProviderPreset) {
        let config = AIProviderConfig.defaults(for: preset)
        #expect(config.authStyle == .bearer)
        #expect(config.capabilities == .conservative)
        #expect(!config.consented)
    }

    @Test func deepseekPresetPointsAtItsAnthropicEndpoint() {
        let config = AIProviderConfig.defaults(for: .deepseek)
        #expect(config.baseURL == "https://api.deepseek.com/anthropic")
        #expect(config.primaryModel == "deepseek-v4-pro[1m]")
        #expect(config.lightModel == "deepseek-v4-flash")
    }

    @Test func customPresetStartsEmpty() {
        let config = AIProviderConfig.defaults(for: .custom)
        #expect(config.baseURL.isEmpty)
        #expect(config.primaryModel.isEmpty)
        #expect(config.lightModel == nil)
    }

    @Test func codableRoundTrip() throws {
        var config = AIProviderConfig.defaults(for: .deepseek)
        config.primaryModel = "deepseek-v4-pro[1m]"
        config.consented = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AIProviderConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func displayNamesNameTheSpecificProvider() {
        #expect(AIProviderPreset.anthropic.displayName == "Anthropic")
        #expect(AIProviderPreset.deepseek.displayName == "DeepSeek")
        #expect(AIProviderPreset.kimi.displayName == "Kimi (Moonshot)")
        #expect(AIProviderPreset.glm.displayName == "GLM (Z.ai)")
        #expect(AIProviderPreset.custom.displayName == "Custom")
    }
}
