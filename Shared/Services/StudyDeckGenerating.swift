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

enum StudyDeckGeneratorFactory {
    /// `anthropic` is a builder so we never construct the network generator (or read
    /// the key) when there is no key. Returns the fixture fallback otherwise.
    nonisolated static func make(
        hasKey: Bool,
        anthropic: @Sendable () -> any StudyDeckGenerating
    ) -> any StudyDeckGenerating {
        hasKey ? anthropic() : FixtureStudyDeckGenerator()
    }
}
