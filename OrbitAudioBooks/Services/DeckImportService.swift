import Foundation
import GRDB

/// Parses, validates, and inserts flashcard decks from JSON import files.
struct DeckImportService {

    let validTriggerTimings = Set(FlashcardTriggerTiming.allCases.map(\.rawValue))

    /// Imports a deck from a JSON file URL, validates every card, and inserts
    /// into the database via FlashcardDAO.
    /// - Parameters:
    ///   - url: The JSON file URL to import.
    ///   - db: A GRDB DatabaseWriter for FlashcardDAO.
    /// - Returns: The number of cards successfully imported.
    func importDeck(from url: URL, db: DatabaseWriter) throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DeckImportError.fileReadFailed(error)
        }

        let deck: FlashcardDeckImport
        do {
            deck = try JSONDecoder().decode(FlashcardDeckImport.self, from: data)
        } catch {
            throw DeckImportError.invalidJSON(error)
        }

        guard !deck.cards.isEmpty else {
            throw DeckImportError.emptyDeck
        }

        for (i, card) in deck.cards.enumerated() {
            guard !card.frontText.isEmpty, !card.backText.isEmpty else {
                throw DeckImportError.emptyCardText(cardIndex: i)
            }
            guard card.startTime >= 0, card.endTime > card.startTime else {
                throw DeckImportError.invalidTimeRange(cardIndex: i)
            }
            guard validTriggerTimings.contains(card.triggerTiming) else {
                throw DeckImportError.invalidTriggerTiming(card.triggerTiming, cardIndex: i)
            }
        }

        let dao = FlashcardDAO(db: db)
        for card in deck.cards {
            let flashcard = Flashcard(
                id: UUID().uuidString,
                audiobookID: deck.targetMediaID,
                frontText: card.frontText,
                backText: card.backText,
                mediaTimestamp: card.startTime,
                endTimestamp: card.endTime,
                triggerTiming: card.triggerTiming,
                nextReviewDate: Date().ISO8601Format(),
                intervalDays: 0,
                easeFactor: 2.5,
                repetitions: 0,
                lastReviewedAt: nil,
                lastGrade: nil,
                isEnabled: true,
                playlistPosition: nil,
                createdAt: Date().ISO8601Format(),
                modifiedAt: Date().ISO8601Format()
            )
            try dao.insert(flashcard)
        }

        return deck.cards.count
    }
}
