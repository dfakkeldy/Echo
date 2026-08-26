// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum StudyDeckCardKind: String, Sendable, Equatable {
    case basic
    case cloze
}

struct StudyDeckSource: Identifiable, Equatable, Sendable {
    let id: String
    let sourceBlockID: String
    let audiobookID: String
    let blockKind: String
    let text: String
    let chapterIndex: Int?
    let sequenceIndex: Int
    let spineIndex: Int
    let blockIndex: Int
}

enum StudyDeckGenerationSelection: Equatable, Sendable {
    case wholeBook
    case chapter(Int)
    case currentSourceBlockID(String)
    case explicitSourceBlockIDs([String])
}

struct StudyDeckGenerationSettings: Equatable, Sendable {
    let maximumCardCount: Int

    init(maximumCardCount: Int = 8) {
        self.maximumCardCount = max(0, maximumCardCount)
    }
}

nonisolated struct GeneratedStudyDeckDraft: Equatable, Sendable {
    let cards: [GeneratedStudyDeckCardDraft]

    init(cards: [GeneratedStudyDeckCardDraft], validSourceBlockIDs: Set<String>) {
        self.cards = cards.compactMap { card in
            card.validated(validSourceBlockIDs: validSourceBlockIDs)
        }
    }
}

nonisolated struct GeneratedStudyDeckCardDraft: Identifiable, Equatable, Sendable {
    static let maximumFrontTextCharacters = 160
    static let maximumBackTextCharacters = 240
    static let maximumClozeTextCharacters = 500

    let id: String
    let sourceBlockID: String
    let frontText: String
    let backText: String
    let tags: [String]
    let kind: StudyDeckCardKind
    let clozeText: String?

    init(
        id: String,
        sourceBlockID: String,
        frontText: String,
        backText: String,
        tags: [String] = ["generated", "fixture"],
        kind: StudyDeckCardKind = .basic,
        clozeText: String? = nil
    ) {
        self.id = id
        self.sourceBlockID = sourceBlockID
        self.frontText = frontText
        self.backText = backText
        self.tags = tags
        self.kind = kind
        self.clozeText = clozeText
    }

    fileprivate func validated(validSourceBlockIDs: Set<String>) -> Self? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSourceBlockID = sourceBlockID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty,
            !normalizedSourceBlockID.isEmpty,
            validSourceBlockIDs.contains(normalizedSourceBlockID),
            let normalizedFrontText = Self.normalizedText(
                frontText,
                maximumCharacters: Self.maximumFrontTextCharacters
            ),
            let normalizedBackText = Self.normalizedText(
                backText,
                maximumCharacters: Self.maximumBackTextCharacters
            )
        else {
            return nil
        }

        if kind == .cloze {
            let trimmedCloze = clozeText?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmedCloze,
                !trimmedCloze.isEmpty,
                trimmedCloze.count <= Self.maximumClozeTextCharacters,
                studyDeckHasValidClozeMarkers(trimmedCloze)
            else {
                return nil
            }
        }

        return Self(
            id: normalizedID,
            sourceBlockID: normalizedSourceBlockID,
            frontText: normalizedFrontText,
            backText: normalizedBackText,
            tags: Self.normalizedTags(tags),
            kind: kind,
            clozeText: clozeText
        )
    }

    private static func normalizedText(_ text: String, maximumCharacters: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumCharacters else {
            return nil
        }
        return trimmed
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var normalizedTags: [String] = []
        for tag in tags {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !normalizedTags.contains(normalized) else {
                continue
            }
            normalizedTags.append(normalized)
        }
        return normalizedTags
    }
}
