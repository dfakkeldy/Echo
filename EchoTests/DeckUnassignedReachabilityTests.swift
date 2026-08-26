// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct DeckUnassignedReachabilityTests {
    @Test func deckSnapshotIncludesUnassignedCardsInTotals() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let service = try makeService(now: now, includeNamedCard: false)

        let snapshot = try service.read { db in
            try DeckLibrarySnapshot.fetch(in: db, now: now)
        }

        #expect(snapshot.namedDecks.isEmpty)
        #expect(!snapshot.isEmpty)
        #expect(snapshot.unassignedCardCount == 1)
        #expect(snapshot.unassignedDueCount == 1)
        #expect(snapshot.totalCardCount == 1)
        #expect(snapshot.totalDueCount == 1)
    }

    @Test func deckCardScopesSeparateNamedAndUnassignedCards() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let service = try makeService(now: now, includeNamedCard: true)

        let all = try service.read { db in try DeckCardScope.all.fetchCards(in: db) }
        let unassigned = try service.read { db in
            try DeckCardScope.unassigned.fetchCards(in: db)
        }
        let named = try service.read { db in
            try DeckCardScope.deck(id: "deck-1").fetchCards(in: db)
        }

        #expect(Set(all.map(\.id)) == ["card-named", "card-unassigned"])
        #expect(unassigned.map(\.id) == ["card-unassigned"])
        #expect(named.map(\.id) == ["card-named"])
    }

    private func makeService(
        now: Date,
        includeNamedCard: Bool
    ) throws -> DatabaseService {
        let service = try DatabaseService(inMemory: ())
        try service.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book', 'Book', 100, '2026-06-01T00:00:00Z')
                """)
            try insertCard(
                id: "card-unassigned",
                deckID: nil,
                nextReviewDate: now.addingTimeInterval(-3_600).ISO8601Format(),
                in: db
            )
            if includeNamedCard {
                try db.execute(sql: """
                    INSERT INTO deck (id, name, source, created_at, modified_at)
                    VALUES ('deck-1', 'Named', 'manual',
                            '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
                    """)
                try insertCard(
                    id: "card-named",
                    deckID: "deck-1",
                    nextReviewDate: now.addingTimeInterval(86_400).ISO8601Format(),
                    in: db
                )
            }
        }
        return service
    }

    private func insertCard(
        id: String,
        deckID: String?,
        nextReviewDate: String,
        in db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO flashcard (
                id, audiobook_id, front_text, back_text, media_timestamp,
                trigger_timing, next_review_date, interval_days, ease_factor,
                repetitions, is_enabled, deck_id, created_at, modified_at
            )
            VALUES (?, 'book', ?, 'Back', 0, 'manualOnly', ?, 0, 2.5,
                    0, 1, ?, '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z')
            """, arguments: [id, id, nextReviewDate, deckID])
    }
}
