// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct FixtureStudyDeckGenerator: StudyDeckGenerating {
    private static let maximumKeywordsPerCard = 4
    private static let maximumKeywordCharacters = 24

    func generate(
        sources: [StudyDeckSource],
        settings: StudyDeckGenerationSettings = StudyDeckGenerationSettings()
    ) -> GeneratedStudyDeckDraft {
        let validSourceBlockIDs = Set(sources.map(\.sourceBlockID))
        let cards =
            sources
            .prefix(settings.maximumCardCount)
            .map(Self.cardDraft)

        return GeneratedStudyDeckDraft(
            cards: cards,
            validSourceBlockIDs: validSourceBlockIDs
        )
    }

    private static func cardDraft(for source: StudyDeckSource) -> GeneratedStudyDeckCardDraft {
        let location = sourceLocation(for: source)
        let keywords = keywords(from: source.text).prefix(maximumKeywordsPerCard)
        let keywordText =
            keywords.isEmpty ? "no compact keywords" : keywords.joined(separator: ", ")

        return GeneratedStudyDeckCardDraft(
            id: "fixture-\(source.sourceBlockID)",
            sourceBlockID: source.sourceBlockID,
            frontText: "What key idea appears in \(location)?",
            backText: "Keywords: \(keywordText). Source: \(location)."
        )
    }

    private static func sourceLocation(for source: StudyDeckSource) -> String {
        let kind = normalizedBlockKind(source.blockKind)
        if let chapterIndex = source.chapterIndex {
            return "chapter \(chapterIndex + 1), \(kind) block \(source.blockIndex)"
        }
        return "spine \(source.spineIndex), \(kind) block \(source.blockIndex)"
    }

    private static func normalizedBlockKind(_ blockKind: String) -> String {
        let normalized =
            blockKind
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .first
            .map(String.init)?
            .prefix(maximumKeywordCharacters)

        guard let normalized, !normalized.isEmpty else {
            return "text"
        }
        return String(normalized)
    }

    private static func keywords(from text: String) -> [String] {
        var seen: Set<String> = []
        var keywords: [String] = []

        for token in normalizedTokens(from: text) {
            guard token.count >= 3, !stopWords.contains(token), !seen.contains(token) else {
                continue
            }
            seen.insert(token)
            keywords.append(token)
        }

        return keywords
    }

    private static func normalizedTokens(from text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { token in
                String(token.prefix(maximumKeywordCharacters))
            }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "in", "into", "is", "it", "of", "on", "or", "that", "the", "this",
        "to", "with", "your", "you", "we", "our", "their", "they", "them",
        "was", "were", "will", "would", "can", "could", "should", "may",
        "might", "has", "have", "had", "do", "does", "did", "using", "use",
        "key", "idea", "source", "chapter", "section", "block", "text",
    ]
}
