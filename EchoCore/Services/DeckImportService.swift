// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Parses, validates, and inserts flashcard decks from JSON import files.
struct DeckImportService {

    let validTriggerTimings = Set(FlashcardTriggerTiming.allCases.map(\.rawValue))

    /// Imports a deck from a JSON file URL, resolves EPUB source anchors, and
    /// inserts cards with their `sourceBlockID` populated where possible.
    /// - Parameters:
    ///   - url: The JSON file URL to import.
    ///   - db: A GRDB DatabaseWriter for FlashcardDAO.
    /// - Returns: An `ImportDeckResult` with counts and any anchor warnings.
    func importDeckVNext(from url: URL, db writer: DatabaseWriter) throws -> ImportDeckResult {
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

        for (index, card) in deck.cards.enumerated() {
            guard !card.frontText.isEmpty, !card.backText.isEmpty else {
                throw DeckImportError.emptyCardText(cardIndex: index)
            }
            guard validTriggerTimings.contains(card.triggerTiming) else {
                throw DeckImportError.invalidTriggerTiming(
                    card.triggerTiming, cardIndex: index)
            }
        }

        var warnings: [ImportDeckWarning] = []
        var anchoredCount = 0
        var resolvedSourceBlockIDs = [String?](repeating: nil, count: deck.cards.count)

        let resolver = EPUBSourceAnchorResolver(dbReader: writer)
        let targetHasBlocks = try resolver.hasBlocks(for: deck.targetMediaID)
        if !targetHasBlocks {
            warnings.append(.targetAudiobookHasNoEPUBBlocks(targetMediaID: deck.targetMediaID))
        }

        if targetHasBlocks {
            for (index, importedCard) in deck.cards.enumerated() {
                let cardReference = "json-card-\(index)"
                switch try resolver.resolve(
                    sourceAnchor: importedCard.sourceAnchor,
                    targetMediaID: deck.targetMediaID,
                    cardReference: cardReference
                ) {
                case .none:
                    resolvedSourceBlockIDs[index] = nil
                case .resolved(let blockID):
                    resolvedSourceBlockIDs[index] = blockID
                    anchoredCount += 1
                case .unresolved(let warning):
                    resolvedSourceBlockIDs[index] = nil
                    warnings.append(warning)
                }
            }
        }

        for (index, card) in deck.cards.enumerated() {
            guard hasValidTimeRange(card) || resolvedSourceBlockIDs[index] != nil else {
                throw DeckImportError.invalidTimeRange(cardIndex: index)
            }
        }

        let deckID: String
        if let existingID = try findDeck(named: deck.deckName, db: writer) {
            deckID = existingID
        } else {
            deckID = UUID().uuidString
            try writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO deck (id, name, source, created_at, modified_at)
                        VALUES (?, ?, 'json_import', ?, ?)
                        """,
                    arguments: [
                        deckID, deck.deckName, Date().ISO8601Format(), Date().ISO8601Format(),
                    ]
                )
            }
        }

        // Ensure the target audiobook row exists: flashcard.audiobook_id is a
        // NOT NULL FK, and an imported deck may target a book not yet on this
        // device. INSERT OR IGNORE is a no-op when the book already exists, so
        // it never clobbers a real title. (Mirrors ApkgImportService.)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO audiobook (id, title, author, duration, added_at)
                    VALUES (?, ?, 'json_import', 0, ?)
                    """,
                arguments: [deck.targetMediaID, deck.deckName, Date().ISO8601Format()]
            )
        }

        // Idempotent re-import: the deck row is reused by name (non-unique by
        // design), so cards must dedupe too — otherwise re-importing the same
        // .echo-deck.json duplicates every card (and its timeline row). Skip any
        // card already present in this deck, keyed on front/back text.
        let existingKeys: Set<String> = try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql:
                    "SELECT front_text, back_text FROM flashcard WHERE deck_id = ? AND audiobook_id = ?",
                arguments: [deckID, deck.targetMediaID])
            return Set(
                rows.map {
                    Self.cardKey(
                        ($0["front_text"] as String?) ?? "", ($0["back_text"] as String?) ?? "")
                })
        }

        let dao = FlashcardDAO(db: writer)
        var importedCount = 0
        for (index, card) in deck.cards.enumerated() {
            guard !existingKeys.contains(Self.cardKey(card.frontText, card.backText)) else {
                continue
            }
            let flashcard = Flashcard(
                id: UUID().uuidString,
                audiobookID: deck.targetMediaID,
                frontText: card.frontText,
                backText: card.backText,
                mediaTimestamp: startTimestamp(for: card),
                endTimestamp: endTimestamp(for: card),
                triggerTiming: FlashcardTriggerTiming(rawValue: card.triggerTiming) ?? .beginning,
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
                sourceBlockID: resolvedSourceBlockIDs[index],
                playlistPosition: nil,
                createdAt: Date().ISO8601Format(),
                modifiedAt: Date().ISO8601Format()
            )
            try dao.insert(flashcard)
            importedCount += 1
        }

        return ImportDeckResult(
            importedCount: importedCount,
            anchoredCount: anchoredCount,
            warnings: warnings
        )
    }

    /// Imports a deck from a JSON file URL, validates every card, and inserts
    /// into the database via FlashcardDAO.
    /// - Parameters:
    ///   - url: The JSON file URL to import.
    ///   - db: A GRDB DatabaseWriter for FlashcardDAO.
    /// - Returns: The number of cards successfully imported.
    func importDeck(from url: URL, db: DatabaseWriter) throws -> Int {
        try importDeckVNext(from: url, db: db).importedCount
    }

    /// Content key for card-level dedupe on re-import (unit separator joins the
    /// two fields so distinct front/back pairs can't collide).
    private static func cardKey(_ front: String, _ back: String) -> String {
        "\(front)\u{1f}\(back)"
    }

    private func findDeck(named name: String, db: DatabaseWriter) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM deck WHERE name = ?", arguments: [name])
        }
    }

    private func hasValidTimeRange(_ card: FlashcardDeckImport.ImportedCard) -> Bool {
        guard let startTime = card.startTime, let endTime = card.endTime else {
            return false
        }
        return startTime >= 0 && endTime > startTime
    }

    private func startTimestamp(for card: FlashcardDeckImport.ImportedCard) -> Double {
        guard hasValidTimeRange(card), let startTime = card.startTime else {
            return 0
        }
        return startTime
    }

    private func endTimestamp(for card: FlashcardDeckImport.ImportedCard) -> Double? {
        guard hasValidTimeRange(card) else {
            return nil
        }
        return card.endTime
    }
}
