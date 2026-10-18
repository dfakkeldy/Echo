// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct DeckSummary: Identifiable, Sendable {
    let id: String
    let name: String
    let cardCount: Int
    let dueCount: Int
}

struct DeckLibrarySnapshot: Sendable {
    let namedDecks: [DeckSummary]
    let unassignedCardCount: Int
    let unassignedDueCount: Int

    static let empty = DeckLibrarySnapshot(
        namedDecks: [],
        unassignedCardCount: 0,
        unassignedDueCount: 0
    )

    var isEmpty: Bool {
        namedDecks.isEmpty && unassignedCardCount == 0
    }

    var totalCardCount: Int {
        namedDecks.reduce(unassignedCardCount) { $0 + $1.cardCount }
    }

    var totalDueCount: Int {
        namedDecks.reduce(unassignedDueCount) { $0 + $1.dueCount }
    }

    nonisolated static func fetch(
        in db: Database,
        now: Date = .now
    ) throws -> DeckLibrarySnapshot {
        let nowString = now.ISO8601Format()
        let rows = try Row.fetchCursor(db, sql: """
            SELECT d.id, d.name,
                   COUNT(f.id) AS card_count,
                   SUM(CASE WHEN f.next_review_date <= ? AND f.is_enabled = 1
                            THEN 1 ELSE 0 END) AS due_count
            FROM deck d
            LEFT JOIN flashcard f ON f.deck_id = d.id
            GROUP BY d.id, d.name
            ORDER BY d.name
            """, arguments: [nowString])
        var namedDecks: [DeckSummary] = []
        while let row = try rows.next() {
            namedDecks.append(DeckSummary(
                id: row["id"],
                name: row["name"],
                cardCount: row["card_count"] ?? 0,
                dueCount: row["due_count"] ?? 0
            ))
        }

        let unassigned = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS card_count,
                   SUM(CASE WHEN next_review_date <= ? AND is_enabled = 1
                            THEN 1 ELSE 0 END) AS due_count
            FROM flashcard
            WHERE deck_id IS NULL
            """, arguments: [nowString])

        return DeckLibrarySnapshot(
            namedDecks: namedDecks,
            unassignedCardCount: unassigned?["card_count"] ?? 0,
            unassignedDueCount: unassigned?["due_count"] ?? 0
        )
    }
}

enum DeckCardScope: Hashable, Sendable {
    case all
    case unassigned
    case deck(id: String)

    nonisolated func fetchCards(in db: Database) throws -> [Flashcard] {
        let request = Flashcard.order(Column("created_at").desc)
        switch self {
        case .all:
            return try request.fetchAll(db)
        case .unassigned:
            return try request
                .filter(Column("deck_id") == nil)
                .fetchAll(db)
        case .deck(let id):
            return try request
                .filter(Column("deck_id") == id)
                .fetchAll(db)
        }
    }
}
