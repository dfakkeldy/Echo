// SPDX-License-Identifier: GPL-3.0-or-later
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
            guard validTriggerTimings.contains(card.triggerTiming.rawValue) else {
                throw DeckImportError.invalidTriggerTiming(
                    card.triggerTiming.rawValue, cardIndex: i)
            }
        }

        let deckID: String
        if let existingID = try findDeck(named: deck.deckName, db: db) {
            deckID = existingID
        } else {
            deckID = UUID().uuidString
            try db.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO deck (id, name, source, created_at, modified_at)
                        VALUES (?, ?, 'json_import', ?, ?)
                        """,
                    arguments: [
                        deckID, deck.deckName, Date().ISO8601Format(), Date().ISO8601Format(),
                    ])
            }
        }

        // Ensure the target audiobook row exists: flashcard.audiobook_id is a
        // NOT NULL FK, and an imported deck may target a book not yet on this
        // device. INSERT OR IGNORE is a no-op when the book already exists, so
        // it never clobbers a real title. (Mirrors ApkgImportService.)
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO audiobook (id, title, author, duration, added_at)
                    VALUES (?, ?, 'json_import', 0, ?)
                    """,
                arguments: [deck.targetMediaID, deck.deckName, Date().ISO8601Format()])
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
                deckID: deckID,
                tags: nil,
                mediaJSON: nil,
                sourceBlockID: nil,
                playlistPosition: nil,
                createdAt: Date().ISO8601Format(),
                modifiedAt: Date().ISO8601Format()
            )
            try dao.insert(flashcard)
        }

        return deck.cards.count
    }

    private func findDeck(named name: String, db: DatabaseWriter) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM deck WHERE name = ?", arguments: [name])
        }
    }
}
