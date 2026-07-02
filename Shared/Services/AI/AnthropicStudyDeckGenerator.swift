// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Two-pass, model-backed study-deck generator.
///
/// Pass 1 (the *brief*) asks the model for a compact book summary that enriches every
/// later batch prompt. It is enrichment, not a hard requirement: if it throws we log and
/// continue with an empty brief rather than aborting the whole run.
///
/// Pass 2 batches the sources (spine-bounded, capped at ``batchSize``) and makes one
/// model call per batch. Each batch is independently recoverable — a batch whose call or
/// decoding throws is logged and skipped, preserving all previously-accumulated cards
/// (partial recovery). `Task.checkCancellation()` at the top of each batch lets a cancelled
/// surrounding task stop early and return the partial draft built so far.
nonisolated struct AnthropicStudyDeckGenerator: StudyDeckGenerating {
    /// EDB's default batch size. A batch is also split early on a spine boundary by
    /// ``StudyDeckBatcher``; this cap only bounds the *maximum* sources per batch.
    private static let batchSize = 12

    private struct Output: Decodable {
        let cards: [Card]
        struct Card: Decodable {
            let sourceBlockID: String
            let frontText: String
            let backText: String
            // M3 fields decoded as optional so missing keys are fine; not mapped into the
            // draft yet (kind/clozeText mapping is Task M3).
            let kind: String?
            let clozeText: String?
            let tags: [String]?
        }
    }

    let client: AnthropicMessagesClient
    /// Pass-1 book-brief client; defaults to `client` for single-model providers.
    let briefClient: AnthropicMessagesClient
    /// `(completedBatches, totalBatches)`, called after each batch completes.
    private let progress: (@Sendable (Int, Int) -> Void)?
    private let logger = Logger(category: "AnthropicStudyDeckGenerator")

    init(
        client: AnthropicMessagesClient,
        briefClient: AnthropicMessagesClient? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.client = client
        self.briefClient = briefClient ?? client
        self.progress = progress
    }

    func generate(
        sources: [StudyDeckSource],
        settings: StudyDeckGenerationSettings
    ) async -> GeneratedStudyDeckDraft {
        let valid = Set(sources.map(\.sourceBlockID))
        guard !sources.isEmpty else {
            return GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: valid)
        }

        // Pass 1 — book brief. Enrichment only: a failure degrades to an empty brief.
        let brief = await bookBrief(sources: sources)

        // Pass 2 — per-batch card generation with cancellation + partial recovery.
        let batches = StudyDeckBatcher().batches(from: sources, maxPerBatch: Self.batchSize)
        var accumulator: [GeneratedStudyDeckCardDraft] = []

        for (index, batch) in batches.enumerated() {
            do {
                try Task.checkCancellation()
            } catch {
                // Cancelled: return what we have so far rather than crashing.
                logger.info(
                    "Study-deck generation cancelled at batch \(index + 1, privacy: .public)")
                break
            }

            do {
                let cards = try await generateBatch(
                    batch, brief: brief, maxCards: settings.maximumCardCount)
                accumulator.append(contentsOf: cards)
            } catch {
                // Per-batch recovery: log and continue, keeping previously-accumulated cards.
                logger.warning(
                    "Study-deck batch \(index + 1, privacy: .public) failed (kept \(accumulator.count, privacy: .public) prior cards): \(String(describing: error))"
                )
            }
            progress?(index + 1, batches.count)
        }

        return GeneratedStudyDeckDraft(cards: accumulator, validSourceBlockIDs: valid)
    }

    /// Pass 1. Returns the raw brief JSON string, or `""` if the call/decoding throws.
    private func bookBrief(sources: [StudyDeckSource]) async -> String {
        do {
            return try await briefClient.complete(
                systemPrompt: StudyDeckPromptBuilder.systemPrompt,
                userPrompt: StudyDeckPromptBuilder.bookBriefPrompt(sources: sources),
                schema: StudyDeckPromptBuilder.briefSchema(),
                maxTokens: 1024)
        } catch {
            logger.warning(
                "Study-deck book-brief pass failed; continuing with empty brief: \(String(describing: error))"
            )
            return ""
        }
    }

    /// Pass 2, one batch. Throws on call/decoding failure so the caller can recover.
    /// Out-of-batch anchors and verbatim long-quote cards are dropped here.
    private func generateBatch(
        _ batch: [StudyDeckSource],
        brief: String,
        maxCards: Int
    ) async throws -> [GeneratedStudyDeckCardDraft] {
        let text = try await client.complete(
            systemPrompt: StudyDeckPromptBuilder.systemPrompt,
            userPrompt: StudyDeckPromptBuilder.batchPrompt(
                sources: batch, brief: brief, maxCards: maxCards),
            schema: StudyDeckPromptBuilder.cardSchema(),
            maxTokens: 4096)
        let output = try JSONDecoder().decode(Output.self, from: Data(text.utf8))

        var cards: [GeneratedStudyDeckCardDraft] = []
        for card in output.cards {
            // (a) Drop cards whose anchor is not in THIS batch (out-of-batch / hallucinated).
            guard let owner = batch.first(where: { $0.sourceBlockID == card.sourceBlockID }) else {
                continue
            }
            // (b) Drop cards that copy a long verbatim run from their source.
            // Include clozeText as a candidate so verbatim-copying cloze cards are also dropped.
            guard
                !studyDeckIsLongSourceQuotation(
                    [card.frontText, card.backText, card.clozeText ?? ""],
                    sourceText: owner.text)
            else {
                continue
            }
            // (c) Map kind; unknown raw values fall back to .basic.
            let kind = StudyDeckCardKind(rawValue: card.kind ?? "basic") ?? .basic
            // (d) Merge base tags with model-supplied tags (trimmed, non-empty, deduped).
            var tags = ["generated", "ai"]
            for tag in card.tags ?? [] {
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !tags.contains(trimmed) {
                    tags.append(trimmed)
                }
            }
            cards.append(
                GeneratedStudyDeckCardDraft(
                    id: "ai-\(card.sourceBlockID)",
                    sourceBlockID: card.sourceBlockID,
                    frontText: card.frontText,
                    backText: card.backText,
                    tags: tags,
                    kind: kind,
                    clozeText: card.clozeText))
        }
        return cards
    }
}
