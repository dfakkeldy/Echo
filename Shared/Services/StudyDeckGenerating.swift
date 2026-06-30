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

/// Controls which generator the 3-way factory selects when both a BYO key and on-device
/// Foundation Models are available.
enum StudyDeckGeneratorPreference: String, Sendable {
    /// Let the factory decide: cloud key wins, then on-device FM, then fixture.
    case auto
    /// Always prefer the cloud (Anthropic) generator; fixture when no key.
    case cloud
    /// Always prefer on-device Foundation Models; fixture when FM is unavailable.
    case onDevice
}

enum StudyDeckGeneratorFactory {
    /// `anthropic` is a builder so we never construct the network generator (or read
    /// the key) when there is no key. Returns the fixture fallback otherwise.
    /// Kept for the existing call site in BookSettingsView (Task 5 will rewire it).
    nonisolated static func make(
        hasKey: Bool,
        anthropic: @Sendable () -> any StudyDeckGenerating
    ) -> any StudyDeckGenerating {
        hasKey ? anthropic() : FixtureStudyDeckGenerator()
    }

    /// 3-way provider selection by preference, key presence, and runtime FM availability.
    /// Selection matrix:
    ///   .auto  + key    → anthropic()
    ///   .auto  + no key + fm → on-device FM (or fixture when SDK < 26)
    ///   .auto  + no key + no fm → fixture
    ///   .cloud + key    → anthropic()
    ///   .cloud + no key → fixture
    ///   .onDevice + fm  → on-device FM (or fixture when SDK < 26)
    ///   .onDevice + no fm → fixture
    nonisolated static func make(
        preference: StudyDeckGeneratorPreference,
        hasKey: Bool,
        fmAvailable: Bool,
        anthropic: @Sendable () -> any StudyDeckGenerating
    ) -> any StudyDeckGenerating {
        switch preference {
        case .cloud:
            return hasKey ? anthropic() : FixtureStudyDeckGenerator()
        case .onDevice:
            return onDevice(ifAvailable: fmAvailable) ?? FixtureStudyDeckGenerator()
        case .auto:
            if hasKey { return anthropic() }
            if let fm = onDevice(ifAvailable: fmAvailable) { return fm }
            return FixtureStudyDeckGenerator()
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
