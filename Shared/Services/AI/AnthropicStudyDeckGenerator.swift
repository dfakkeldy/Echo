// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

nonisolated struct AnthropicStudyDeckGenerator: StudyDeckGenerating {
    private struct Output: Decodable {
        let cards: [Card]
        struct Card: Decodable {
            let sourceBlockID: String
            let frontText: String
            let backText: String
        }
    }

    let client: AnthropicMessagesClient
    private let logger = Logger(category: "AnthropicStudyDeckGenerator")

    init(client: AnthropicMessagesClient) { self.client = client }

    func generate(
        sources: [StudyDeckSource],
        settings: StudyDeckGenerationSettings
    ) async -> GeneratedStudyDeckDraft {
        let valid = Set(sources.map(\.sourceBlockID))
        guard !sources.isEmpty else {
            return GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: valid)
        }
        do {
            let text = try await client.complete(
                systemPrompt: StudyDeckPromptBuilder.systemPrompt,
                userPrompt: StudyDeckPromptBuilder.userPrompt(
                    sources: sources, maxCards: settings.maximumCardCount),
                schema: StudyDeckPromptBuilder.cardSchema(),
                maxTokens: 4096)
            let output = try JSONDecoder().decode(Output.self, from: Data(text.utf8))
            let drafts = output.cards.map {
                GeneratedStudyDeckCardDraft(
                    id: "ai-\($0.sourceBlockID)",
                    sourceBlockID: $0.sourceBlockID,
                    frontText: $0.frontText,
                    backText: $0.backText,
                    tags: ["generated", "ai"])
            }
            return GeneratedStudyDeckDraft(cards: drafts, validSourceBlockIDs: valid)
        } catch {
            logger.error("AI study-deck generation failed: \(String(describing: error))")
            return GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: valid)
        }
    }
}
