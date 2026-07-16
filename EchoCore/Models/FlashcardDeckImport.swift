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
    /// Portable-v2 marker. `nil` for legacy documents; `2` for the current
    /// portable contract. See `ValidatedDeckImport` for classification.
    let formatVersion: Int?
    /// Stable portable deck identity. `nil` for legacy documents.
    let deckID: String?
    let deckName: String
    /// Portable-v2 marker; must equal `"selectedBook"` when present.
    let targetBinding: String?
    let targetMediaID: String
    /// Portable-v2 marker binding this deck to the EPUB it was authored
    /// against. `nil` for legacy documents.
    let sourceSignature: EchoSourceSignature?
    let cards: [ImportedCard]

    init(
        formatVersion: Int? = nil,
        deckID: String? = nil,
        deckName: String,
        targetBinding: String? = nil,
        targetMediaID: String,
        sourceSignature: EchoSourceSignature? = nil,
        cards: [ImportedCard]
    ) {
        self.formatVersion = formatVersion
        self.deckID = deckID
        self.deckName = deckName
        self.targetBinding = targetBinding
        self.targetMediaID = targetMediaID
        self.sourceSignature = sourceSignature
        self.cards = cards
    }

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

    // MARK: - Portable-v2 classification and validation (ValidatedDeckImport)

    /// The v2 top-level markers (`formatVersion`, `deckID`, `targetBinding`,
    /// `sourceSignature`) are neither all absent (legacy) nor all present.
    case incompletePortableDeck
    case unsupportedPortableVersion(Int?)
    case emptyDeckName
    case invalidPortableBinding(String?)
    case invalidPortableDeckID(String)
    case invalidPortableTarget(String)
    case invalidSourceSignature
    case portableTextTooLong(cardIndex: Int)
    case portableTimestampsForbidden(cardIndex: Int)
    case portableTimingMustBeManualOnly(cardIndex: Int)
    case invalidPortableSourceAnchor(cardIndex: Int)
    case invalidPortableImageAnchor(cardIndex: Int)
    case invalidPortableImageFile(cardIndex: Int)

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
        case .incompletePortableDeck:
            "Portable study deck metadata is incomplete."
        case .unsupportedPortableVersion:
            "Portable study decks require formatVersion 2."
        case .emptyDeckName:
            "The portable deck name must not be empty."
        case .invalidPortableBinding:
            "Portable study decks require targetBinding selectedBook."
        case .invalidPortableDeckID:
            "deckID must be 1-128 ASCII letters, numbers, dots, underscores, or hyphens."
        case .invalidPortableTarget:
            "The portable targetMediaID sentinel is invalid."
        case .invalidSourceSignature:
            "The source signature is missing or malformed."
        case .portableTextTooLong(let index):
            "Card \(index + 1): frontText must be at most 160 Unicode scalars and backText at most 240 Unicode scalars."
        case .portableTimestampsForbidden(let index):
            "Card \(index + 1): startTime and endTime are not allowed for portable decks."
        case .portableTimingMustBeManualOnly(let index):
            "Card \(index + 1): triggerTiming must be manualOnly for portable decks."
        case .invalidPortableSourceAnchor(let index):
            "Card \(index + 1): sourceAnchor must match the pattern s<section>-b<block>."
        case .invalidPortableImageAnchor(let index):
            "Card \(index + 1): imageAnchor must match the pattern s<section>-b<block>."
        case .invalidPortableImageFile(let index):
            "Card \(index + 1): imageFile must be a safe relative path under deck-images/."
        }
    }
}
