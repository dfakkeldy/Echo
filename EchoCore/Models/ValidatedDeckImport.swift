// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Classifies a decoded `FlashcardDeckImport` as either a legacy (v1) or a
/// portable (v2) deck, and applies the full strict-validation contract for
/// portable decks. This is the single authoritative entry point for
/// distinguishing the two shapes; nothing else in Echo should re-derive that
/// decision from `FlashcardDeckImport`'s optional fields.
nonisolated enum ValidatedDeckImport: Sendable {
    case legacy(FlashcardDeckImport)
    case portable(PortableDeckImport)

    static func decode(_ data: Data) throws -> Self {
        let raw: FlashcardDeckImport
        do {
            raw = try JSONDecoder().decode(FlashcardDeckImport.self, from: data)
        } catch {
            throw DeckImportError.invalidJSON(error)
        }
        let v2Markers = [
            raw.formatVersion != nil,
            raw.deckID != nil,
            raw.targetBinding != nil,
            raw.sourceSignature != nil,
        ]
        guard v2Markers.contains(true) else { return .legacy(raw) }
        guard v2Markers.allSatisfy({ $0 }),
            let deckID = raw.deckID,
            let sourceSignature = raw.sourceSignature
        else {
            throw DeckImportError.incompletePortableDeck
        }
        guard raw.formatVersion == 2 else {
            throw DeckImportError.unsupportedPortableVersion(raw.formatVersion)
        }
        guard !raw.deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeckImportError.emptyDeckName
        }
        guard raw.targetBinding == "selectedBook" else {
            throw DeckImportError.invalidPortableBinding(raw.targetBinding)
        }
        guard matches("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", deckID),
            deckID.unicodeScalars.allSatisfy(\.isASCII)
        else {
            throw DeckImportError.invalidPortableDeckID(deckID)
        }
        guard
            matches(
                "^echo-portable:[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9.-]*$",
                raw.targetMediaID
            )
        else {
            throw DeckImportError.invalidPortableTarget(raw.targetMediaID)
        }
        guard sourceSignature.algorithm == EchoSourceSignature.currentAlgorithm,
            matches("^sha256:[0-9a-f]{64}$", sourceSignature.value)
        else {
            throw DeckImportError.invalidSourceSignature
        }
        guard !raw.cards.isEmpty else { throw DeckImportError.emptyDeck }
        for (index, card) in raw.cards.enumerated() {
            try validatePortableCard(card, index: index)
        }
        return .portable(
            PortableDeckImport(
                deckID: deckID,
                deckName: raw.deckName,
                targetMediaID: raw.targetMediaID,
                sourceSignature: sourceSignature,
                cards: raw.cards
            ))
    }

    private static func validatePortableCard(
        _ card: FlashcardDeckImport.ImportedCard,
        index: Int
    ) throws {
        let front = card.frontText.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = card.backText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !back.isEmpty else {
            throw DeckImportError.emptyCardText(cardIndex: index)
        }
        guard card.frontText.unicodeScalars.count <= 160,
            card.backText.unicodeScalars.count <= 240
        else {
            throw DeckImportError.portableTextTooLong(cardIndex: index)
        }
        guard card.startTime == nil, card.endTime == nil else {
            throw DeckImportError.portableTimestampsForbidden(cardIndex: index)
        }
        guard card.triggerTiming == FlashcardTriggerTiming.manualOnly.rawValue else {
            throw DeckImportError.portableTimingMustBeManualOnly(cardIndex: index)
        }
        guard let sourceAnchor = card.sourceAnchor,
            matches("^s[0-9]+-b[0-9]+$", sourceAnchor)
        else {
            throw DeckImportError.invalidPortableSourceAnchor(cardIndex: index)
        }
        if let imageAnchor = card.imageAnchor,
            !matches("^s[0-9]+-b[0-9]+$", imageAnchor)
        {
            throw DeckImportError.invalidPortableImageAnchor(cardIndex: index)
        }
        if card.imageAnchor != nil, card.imageFile != nil {
            throw DeckImportError.conflictingImageFields(cardIndex: index)
        }
        if let imageFile = card.imageFile {
            let parts = imageFile.split(separator: "/", omittingEmptySubsequences: false)
            guard imageFile.hasPrefix("deck-images/"),
                !imageFile.hasPrefix("/"),
                !imageFile.contains("\\"),
                !parts.contains(where: { $0 == ".." || $0.isEmpty })
            else {
                throw DeckImportError.invalidPortableImageFile(cardIndex: index)
            }
        }
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// A fully validated portable (v2) study deck: every top-level field and
/// every card has passed `ValidatedDeckImport.decode(_:)`'s strict contract.
/// Non-optional/narrowed types here (versus `FlashcardDeckImport`) let
/// downstream import code skip re-checking what has already been proven.
nonisolated struct PortableDeckImport: Sendable {
    let deckID: String
    let deckName: String
    let targetMediaID: String
    let sourceSignature: EchoSourceSignature
    let cards: [FlashcardDeckImport.ImportedCard]
}
