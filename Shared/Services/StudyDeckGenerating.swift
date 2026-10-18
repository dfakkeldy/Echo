// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Justified DI seam: two real implementations (deterministic fixture fallback,
/// model-backed Anthropic). Mirrors DivergenceClassifier. The async requirement is
/// satisfied by FixtureStudyDeckGenerator's synchronous method (Swift allows a
/// sync witness for an async requirement).
protocol StudyDeckGenerating: Sendable {
    func generate(
        sources: [StudyDeckSource],
        settings: StudyDeckGenerationSettings
    ) async -> GeneratedStudyDeckDraft
}

/// Controls which generator the 3-way factory selects when cloud and on-device
/// Foundation Models are available.
enum StudyDeckGeneratorPreference: String, Sendable {
    /// Let the factory decide: configured cloud wins, then on-device FM.
    case auto
    /// Always prefer the configured cloud generator.
    case cloud
    /// Always prefer on-device Foundation Models.
    case onDevice
}

enum StudyDeckGeneratorFactory {
    /// UI-facing provider resolution. A nil result means no AI provider is available,
    /// so the sheet shows an explicit empty state instead of fixture cards.
    /// Selection matrix:
    ///   .auto + cloud -> cloud()
    ///   .auto + no cloud -> on-device FM when available, else nil
    ///   .cloud -> cloud(), else nil
    ///   .onDevice -> on-device FM when available, else nil
    nonisolated static func makeForUI(
        preference: StudyDeckGeneratorPreference,
        fmAvailable: Bool,
        cloud: (@Sendable () -> any StudyDeckGenerating)?
    ) -> (any StudyDeckGenerating)? {
        switch preference {
        case .cloud:
            return cloud?()
        case .onDevice:
            return onDevice(ifAvailable: fmAvailable)
        case .auto:
            if let cloud {
                return cloud()
            }
            return onDevice(ifAvailable: fmAvailable)
        }
    }

    /// Returns a `FoundationModelsStudyDeckGenerator` when `ifAvailable` is true AND the
    /// current SDK/OS supports Foundation Models; otherwise `nil`.
    private nonisolated static func onDevice(ifAvailable: Bool) -> (any StudyDeckGenerating)? {
        guard ifAvailable else { return nil }
        #if canImport(FoundationModels) && (os(iOS) || os(macOS))
            if #available(iOS 26, macOS 26, *) {
                return FoundationModelsStudyDeckGenerator()
            }
        #endif
        return nil
    }
}
