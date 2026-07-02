// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The supported provider presets. All speak the Anthropic Messages dialect;
/// non-Anthropic presets point the same client at a compatible endpoint.
nonisolated enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case deepseek
    case kimi
    case glm
    case custom

    var id: String { rawValue }

    /// User-facing provider name; also interpolated into the 5.1.2(i) consent string.
    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .deepseek: "DeepSeek"
        case .kimi: "Kimi (Moonshot)"
        case .glm: "GLM (Z.ai)"
        case .custom: "Custom"
        }
    }
}

/// How the token is presented to the endpoint. Exactly one credential style is sent.
nonisolated enum AIProviderAuthStyle: String, Codable, Equatable, Sendable {
    case xAPIKey
    case bearer
}

/// What the endpoint implements beyond the Messages request envelope.
nonisolated struct AIProviderCapabilities: Codable, Equatable, Sendable {
    var supportsStructuredOutput: Bool
    var supportsThinking: Bool

    static let full = AIProviderCapabilities(
        supportsStructuredOutput: true,
        supportsThinking: true
    )

    static let conservative = AIProviderCapabilities(
        supportsStructuredOutput: false,
        supportsThinking: false
    )
}

/// Non-secret provider configuration. Tokens live in the Keychain via `APIKeyStore`.
nonisolated struct AIProviderConfig: Codable, Equatable, Sendable {
    var preset: AIProviderPreset
    /// Endpoint root; `/v1/messages` is appended by the client.
    var baseURL: String
    var authStyle: AIProviderAuthStyle
    /// Free-form model ID passed to the wire verbatim.
    var primaryModel: String
    /// Optional cheaper model for the Pass-1 book brief; nil/empty means use `primaryModel`.
    var lightModel: String?
    var capabilities: AIProviderCapabilities
    /// Per-provider App Store 5.1.2(i) consent.
    var consented: Bool

    /// Shipped starting points; every field remains editable in Settings.
    static func defaults(for preset: AIProviderPreset) -> AIProviderConfig {
        switch preset {
        case .anthropic:
            AIProviderConfig(
                preset: .anthropic,
                baseURL: "https://api.anthropic.com",
                authStyle: .xAPIKey,
                primaryModel: "claude-opus-4-8",
                lightModel: "claude-haiku-4-5",
                capabilities: .full,
                consented: false
            )
        case .deepseek:
            AIProviderConfig(
                preset: .deepseek,
                baseURL: "https://api.deepseek.com/anthropic",
                authStyle: .bearer,
                primaryModel: "deepseek-v4-pro[1m]",
                lightModel: "deepseek-v4-flash",
                capabilities: .conservative,
                consented: false
            )
        case .kimi:
            AIProviderConfig(
                preset: .kimi,
                baseURL: "https://api.moonshot.ai/anthropic",
                authStyle: .bearer,
                primaryModel: "kimi-k2.5",
                lightModel: nil,
                capabilities: .conservative,
                consented: false
            )
        case .glm:
            AIProviderConfig(
                preset: .glm,
                baseURL: "https://api.z.ai/api/anthropic",
                authStyle: .bearer,
                primaryModel: "glm-5",
                lightModel: nil,
                capabilities: .conservative,
                consented: false
            )
        case .custom:
            AIProviderConfig(
                preset: .custom,
                baseURL: "",
                authStyle: .bearer,
                primaryModel: "",
                lightModel: nil,
                capabilities: .conservative,
                consented: false
            )
        }
    }
}
