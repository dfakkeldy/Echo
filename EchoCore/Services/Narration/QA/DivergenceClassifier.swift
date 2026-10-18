// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The single justified DI seam in M3 (two real impls: deterministic always-on,
/// Foundation Models gated). Given an already-detected `DivergenceWindow`, return
/// a label + optional suggested fix. Classification never *detects* — detection
/// is `NarrationQADetector`'s deterministic job.
protocol DivergenceClassifier: Sendable {
    func classify(_ window: DivergenceWindow) async -> DivergenceClassification
}

/// Rule-based, always-available classifier. Pure + `Sendable` (no stored state),
/// so the QA issue *set and labels* are reproducible across devices and CI.
struct DeterministicDivergenceClassifier: DivergenceClassifier {
    func classify(_ window: DivergenceWindow) async -> DivergenceClassification {
        let issueType = Self.label(for: window)
        // For pronunciation issues, the expected text IS the corrected spelling.
        let spokenForm: String? =
            issueType == .pronunciation ? window.expectedText : nil
        return DivergenceClassification(
            issueType: issueType, suggestedSpokenForm: spokenForm, suggestedIPA: nil,
            confidence: window.confidence)
    }

    static func label(for window: DivergenceWindow) -> NarrationQAIssueType {
        if window.confidence < 0.5 { return .lowConfidence }
        let expected = window.expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = window.heardText.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty, !expected.isEmpty { return .omission }
        if expected.isEmpty, !heard.isEmpty { return .insertion }
        if looksLikeProperNounOrAcronym(expected) { return .pronunciation }
        return .substitution
    }

    private static func looksLikeProperNounOrAcronym(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count == 1, let word = words.first else { return false }
        // All-caps acronym (>=2 letters) or interior capital (CamelCase proper noun).
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if letters.allSatisfy(\.isUppercase) { return true }
        if letters.first?.isUppercase == true { return true }
        let interior = letters.dropFirst()
        return interior.contains(where: \.isUppercase)
    }
}
