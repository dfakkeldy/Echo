// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct DeckDAOTests {
    @Test func createManualDeckTrimsNameAndSetsSource() throws {
        let service = try DatabaseService(inMemory: ())
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let deck = try DeckDAO(db: service.writer)
            .findOrCreateManualDeck(named: "  Memory Palace  ", now: now)

        #expect(deck.name == "Memory Palace")
        #expect(deck.source == "manual")
        #expect(deck.ankiDeckID == nil)
        #expect(deck.createdAt == now.ISO8601Format())
        #expect(deck.modifiedAt == now.ISO8601Format())

        let count = try service.read { db in try Deck.fetchCount(db) }
        #expect(count == 1)
    }

    @Test func createManualDeckRejectsBlankNames() throws {
        let service = try DatabaseService(inMemory: ())

        #expect(throws: DeckDAOError.self) {
            try DeckDAO(db: service.writer).findOrCreateManualDeck(named: " \n ")
        }
    }

    @Test func createManualDeckReusesExistingName() throws {
        let service = try DatabaseService(inMemory: ())
        let existing = Deck(
            id: "existing",
            name: "Philosophy",
            source: "apkg_import",
            ankiDeckID: 42,
            createdAt: "2026-06-01T00:00:00Z",
            modifiedAt: "2026-06-01T00:00:00Z"
        )
        try service.write { db in
            try existing.insert(db)
        }

        let deck = try DeckDAO(db: service.writer).findOrCreateManualDeck(named: "Philosophy")

        #expect(deck.id == existing.id)
        #expect(deck.source == "apkg_import")
        #expect(deck.ankiDeckID == 42)

        let count = try service.read { db in try Deck.fetchCount(db) }
        #expect(count == 1)
    }

    @Test func renameDeckUpdatesNameAndModifiedAt() throws {
        let service = try DatabaseService(inMemory: ())
        let original = try DeckDAO(db: service.writer).findOrCreateManualDeck(named: "Old")
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        let renamed = try DeckDAO(db: service.writer)
            .renameDeck(id: original.id, to: "  New  ", now: now)

        #expect(renamed.name == "New")
        #expect(renamed.createdAt == original.createdAt)
        #expect(renamed.modifiedAt == now.ISO8601Format())

        let stored = try service.read { db in try Deck.fetchOne(db, key: original.id) }
        #expect(stored?.name == "New")
    }

    @Test func renameDeckRejectsDuplicateName() throws {
        let service = try DatabaseService(inMemory: ())
        let first = try DeckDAO(db: service.writer).findOrCreateManualDeck(named: "First")
        _ = try DeckDAO(db: service.writer).findOrCreateManualDeck(named: "Second")

        #expect(throws: DeckDAOError.self) {
            try DeckDAO(db: service.writer).renameDeck(id: first.id, to: "Second")
        }
    }

    @Test func deleteDeckUnassignsCardsWithoutDeletingThem() throws {
        let service = try DatabaseService(inMemory: ())
        let deck = try DeckDAO(db: service.writer).findOrCreateManualDeck(named: "Cards")
        try seedAudiobookAndCard(service: service, deckID: deck.id)

        try DeckDAO(db: service.writer).deleteDeck(id: deck.id)

        try service.read { db in
            #expect(try Deck.fetchCount(db) == 0)
            let card = try Flashcard.fetchOne(db, key: "card-1")
            #expect(card?.deckID == nil)
        }
    }

    private func seedAudiobookAndCard(service: DatabaseService, deckID: String) throws {
        try service.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book', 'Book', 100, '2026-06-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO flashcard (
                    id, audiobook_id, front_text, back_text, media_timestamp,
                    trigger_timing, next_review_date, interval_days, ease_factor,
                    repetitions, is_enabled, deck_id, created_at, modified_at
                )
                VALUES (
                    'card-1', 'book', 'Front', 'Back', 0,
                    'manualOnly', '2026-06-01T00:00:00Z', 0, 2.5,
                    0, 1, ?, '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z'
                )
                """, arguments: [deckID])
        }
    }
}
