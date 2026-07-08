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
///       "sourceAnchor": "s1-b2",
///       "startTime": 45.0,
///       "endTime": 52.0,
///       "triggerTiming": "beginning"
///     }
///   ]
/// }
/// ```
///
/// `startTime` and `endTime` are optional when `sourceAnchor` resolves to an
/// EPUB block for the target audiobook.
nonisolated struct FlashcardDeckImport: Codable, Sendable {
    let deckName: String
    let targetMediaID: String
    let cards: [ImportedCard]

    nonisolated struct ImportedCard: Codable, Sendable {
        let frontText: String
        let backText: String
        let startTime: Double?
        let endTime: Double?
        /// Raw string (not the enum) so an unknown value is caught by the
        /// dedicated `invalidTriggerTiming` validation with a card-numbered
        /// message, rather than failing decode as a generic `invalidJSON`.
        let triggerTiming: String
        let sourceAnchor: String?
        /// Portable `s<i>-b<j>` anchor of an in-book figure block (an extracted
        /// PDF figure). Mutually exclusive with `imageFile`.
        var imageAnchor: String?
        /// Path (relative to the deck bundle's folder) of a bundled image file,
        /// e.g. a Codex-generated mnemonic. Mutually exclusive with `imageAnchor`.
        var imageFile: String?
    }
}

enum DeckImportError: LocalizedError {
    case fileReadFailed(Error)
    case invalidJSON(Error)
    case invalidTriggerTiming(String, cardIndex: Int)
    case emptyDeck
    case emptyCardText(cardIndex: Int)
    case invalidTimeRange(cardIndex: Int)
    case conflictingImageFields(cardIndex: Int)

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
            "Card \(index + 1): startTime must be less than endTime and both must be non-negative unless sourceAnchor resolves to an EPUB block."
        case .conflictingImageFields(let index):
            "Card \(index + 1): imageAnchor and imageFile are mutually exclusive; set at most one."
        }
    }
}
