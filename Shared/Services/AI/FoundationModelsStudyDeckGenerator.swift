// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Pure model-field → draft mapping (no FoundationModels dependency, so it is unit-testable
/// off-device). The draft's own validation (anchor in batch, length caps, cloze markers) runs later.
enum StudyDeckFMCardMapper {
    nonisolated static func draft(
        sourceBlockID: String, frontText: String, backText: String,
        kind: String, clozeText: String, tags: [String]
    ) -> GeneratedStudyDeckCardDraft {
        let cardKind =
            StudyDeckCardKind(rawValue: kind.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .basic
        var merged = ["generated", "on-device"]
        for t in tags {
            let n = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty, !merged.contains(n) { merged.append(n) }
        }
        return GeneratedStudyDeckCardDraft(
            id: "fm-\(sourceBlockID)", sourceBlockID: sourceBlockID,
            frontText: frontText, backText: backText, tags: merged,
            kind: cardKind, clozeText: cardKind == .cloze ? clozeText : nil)
    }
}

#if canImport(FoundationModels) && (os(iOS) || os(macOS))
    import FoundationModels

    @available(iOS 26, macOS 26, *)
    @Generable
    struct StudyDeckGeneratedCard {
        @Guide(
            description:
                "A short quiz question. Use for a basic card; leave empty for a cloze card.")
        let frontText: String
        @Guide(description: "The concise answer for a basic card; leave empty for a cloze card.")
        let backText: String
        @Guide(.anyOf(["basic", "cloze"]))
        let kind: String
        @Guide(
            description:
                "A sentence with one or more {{c1::answer}} cloze deletions; only when kind is cloze."
        )
        let clozeText: String
        @Guide(.maximumCount(4))
        let tags: [String]
    }

    /// On-device Foundation Models study-card generator. One card per source (capped at
    /// settings.maximumCardCount), each its own session to fit the context window; any
    /// per-source error is logged and that source is skipped (never crashes). Output goes
    /// through the same GeneratedStudyDeckDraft validation as every other generator.
    @available(iOS 26, macOS 26, *)
    struct FoundationModelsStudyDeckGenerator: StudyDeckGenerating {
        let fallback: any StudyDeckGenerating
        private nonisolated static let logger = Logger(category: "StudyDeck.FM")
        private nonisolated static let instructions = """
            You generate one study flashcard from a private book excerpt. Use only the excerpt — \
            no outside facts. Paraphrase; do not copy long passages verbatim. Choose a basic \
            question/answer or a {{c1::cloze}} sentence, whichever fits. Keep it short and useful. \
            Return a few specific tags; avoid generic tags like book, chapter, or study.
            """
        private nonisolated static let maxExcerpt = 7_500

        nonisolated init(fallback: any StudyDeckGenerating = FixtureStudyDeckGenerator()) {
            self.fallback = fallback
        }

        nonisolated func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            let valid = Set(sources.map(\.sourceBlockID))
            let chosen = Array(sources.prefix(settings.maximumCardCount))
            var drafts: [GeneratedStudyDeckCardDraft] = []
            for source in chosen {
                if Task.isCancelled { break }
                let excerpt = String(
                    source.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(
                        Self.maxExcerpt))
                guard !excerpt.isEmpty else { continue }
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(
                        to: "Book excerpt:\n\(excerpt)",
                        generating: StudyDeckGeneratedCard.self,
                        options: GenerationOptions(sampling: .greedy))
                    let c = response.content
                    drafts.append(
                        StudyDeckFMCardMapper.draft(
                            sourceBlockID: source.sourceBlockID, frontText: c.frontText,
                            backText: c.backText,
                            kind: c.kind, clozeText: c.clozeText, tags: c.tags))
                } catch {
                    Self.logger.error(
                        "FM card generation skipped a source: \(error.localizedDescription)")
                }
            }
            return GeneratedStudyDeckDraft(cards: drafts, validSourceBlockIDs: valid)
        }
    }
#endif
