// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// JSON format for importing pre-made flashcard decks.
///
/// Example:
/// ```json
/// {
///   "deckName": "Chapter 1 Vocabulary",
///   "targetMediaID": "my-audiobook.m4b",
///   "cards": [
///     {
///       "frontText": "What does 'ephemeral' mean?",
///       "backText": "Lasting for a very short time.",
///       "startTime": 45.0,
///       "endTime": 52.0,
///       "triggerTiming": "beginning"
///     }
///   ]
/// }
/// ```
struct FlashcardDeckImport: Codable, Sendable {
    let deckName: String
    let targetMediaID: String
    let cards: [ImportedCard]

    struct ImportedCard: Codable, Sendable {
        let frontText: String
        let backText: String
        let startTime: Double
        let endTime: Double
        let triggerTiming: FlashcardTriggerTiming
        let sourceAnchor: String?
    }
}

enum DeckImportError: LocalizedError {
    case fileReadFailed(Error)
    case invalidJSON(Error)
    case invalidTriggerTiming(String, cardIndex: Int)
    case emptyDeck
    case emptyCardText(cardIndex: Int)
    case invalidTimeRange(cardIndex: Int)

    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let error):
            "Failed to read file: \(error.localizedDescription)"
        case .invalidJSON(let error):
            "Invalid JSON format: \(error.localizedDescription)"
        case .invalidTriggerTiming(let value, let index):
            "Card \(index + 1): invalid triggerTiming \"\(value)\". Must be \"beginning\", \"end\", or \"manualOnly\"."
        case .emptyDeck:
            "The deck contains no cards."
        case .emptyCardText(let index):
            "Card \(index + 1): frontText and backText must not be empty."
        case .invalidTimeRange(let index):
            "Card \(index + 1): startTime must be less than endTime and both must be non-negative."
        }
    }
}
