// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

#if canImport(FoundationModels)
    import FoundationModels

    /// Structured output for the FM classifier. Constrained decoding fills these —
    /// no manual JSON parsing. `kind` is validated back into `NarrationQAIssueType`;
    /// an unknown string falls through to the deterministic label.
    @available(iOS 26, macOS 26, *)
    @Generable
    struct IssueClassification {
        @Guide(
            description:
                "One of: pronunciation, omission, insertion, substitution, normalization, timingDrift, lowConfidence"
        )
        let kind: String
        let suggestedSpokenForm: String?
        let suggestedIPA: String?
        @Guide(.range(0...1))
        let confidence: Double
    }

    /// Gated enrichment classifier. Re-labels and suggests fixes for an
    /// already-detected window; wraps the deterministic classifier as a per-issue
    /// fallback so any FM error degrades to the deterministic label (never a crash).
    @available(iOS 26, macOS 26, *)
    struct FoundationModelsDivergenceClassifier: DivergenceClassifier {
        let fallback: DivergenceClassifier
        private static let logger = Logger(category: "NarrationQA.FM")

        private static let instructions =
            "You classify a single text-to-speech narration mistake. You are given the expected "
            + "source words and what an automatic transcriber heard. Choose the single best kind. "
            + "When kind is pronunciation, you MUST provide suggestedSpokenForm (the correct "
            + "spelling of the mispronounced word). suggestedIPA is optional. "
            + "Never invent words that are not implied by the inputs."

        func classify(_ window: DivergenceWindow) async -> DivergenceClassification {
            let det = await fallback.classify(window)
            // Only book/transcript-derived text goes in the PROMPT, never instructions.
            let prompt =
                "Expected: \"\(window.expectedText)\"\nHeard: \"\(window.heardText)\"\n"
                + "Deterministic guess: \(det.issueType.rawValue)."
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(
                    to: prompt, generating: IssueClassification.self,
                    options: GenerationOptions(sampling: .greedy))
                let content = response.content
                let kind = NarrationQAIssueType(rawValue: content.kind) ?? det.issueType
                return DivergenceClassification(
                    issueType: kind,
                    suggestedSpokenForm: content.suggestedSpokenForm,
                    suggestedIPA: content.suggestedIPA,
                    confidence: content.confidence)
            } catch {
                Self.logger.error("FM classify fell back: \(error.localizedDescription)")
                return det
            }
        }
    }
#endif
