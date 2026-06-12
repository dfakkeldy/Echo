import Foundation
import GRDB

/// Exports flashcards to the `.echodeck.json` format (superset of the existing JSON import format).
struct DeckExportService {

    /// Exports all cards for a given deck (or all cards if deckID is nil).
    func export(deckID: String?, reader: DatabaseReader) throws -> URL {
        let cards = try reader.read { db -> [Flashcard] in
            if let deckID {
                return try Flashcard
                    .filter(Column("deck_id") == deckID)
                    .filter(Column("is_enabled") == true)
                    .fetchAll(db)
            } else {
                return try Flashcard
                    .filter(Column("is_enabled") == true)
                    .fetchAll(db)
            }
        }

        let deckName: String
        if let deckID {
            deckName = try reader.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM deck WHERE id = ?", arguments: [deckID]) ?? "Unknown"
            }
        } else {
            deckName = "All Cards"
        }

        let cardsDTO = cards.map { card in
            FlashcardCardDTO(
                frontText: card.frontText,
                backText: card.backText,
                startTime: card.mediaTimestamp,
                endTime: card.endTimestamp ?? (card.mediaTimestamp + 10),
                triggerTiming: card.triggerTiming
            )
        }

        let export = FlashcardDeckExport(
            formatVersion: 1,
            exportedAt: Date().ISO8601Format(),
            deckName: deckName,
            targetMediaID: cards.first?.audiobookID ?? "",
            cards: cardsDTO
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(deckName.replacingOccurrences(of: " ", with: "_")).echodeck.json")
        try data.write(to: tmp)
        return tmp
    }
}

/// Top-level export container.
struct FlashcardDeckExport: Codable {
    let formatVersion: Int
    let exportedAt: String
    let deckName: String
    let targetMediaID: String
    let cards: [FlashcardCardDTO]
}

/// Individual card DTO (matches the import format).
struct FlashcardCardDTO: Codable {
    let frontText: String
    let backText: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let triggerTiming: FlashcardTriggerTiming
}
