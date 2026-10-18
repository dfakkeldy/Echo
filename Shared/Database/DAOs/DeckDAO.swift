// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

enum DeckDAOError: Error, LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "Deck names cannot be empty.")
        case .duplicateName(let name):
            return String(localized: "A deck named \"\(name)\" already exists.")
        case .notFound:
            return String(localized: "The deck could not be found.")
        }
    }
}

nonisolated struct DeckDAO {
    let db: DatabaseWriter

    func all() throws -> [Deck] {
        try db.read { db in
            try Deck
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    func findOrCreateManualDeck(named rawName: String, now: Date = Date()) throws -> Deck {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DeckDAOError.emptyName }

        return try db.write { db in
            if let existing = try Deck
                .filter(Column("name") == name)
                .fetchOne(db)
            {
                return existing
            }

            let timestamp = now.ISO8601Format()
            let deck = Deck(
                id: UUID().uuidString,
                name: name,
                source: "manual",
                ankiDeckID: nil,
                createdAt: timestamp,
                modifiedAt: timestamp
            )
            try deck.insert(db)
            return deck
        }
    }

    func renameDeck(id: String, to rawName: String, now: Date = Date()) throws -> Deck {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DeckDAOError.emptyName }

        return try db.write { db in
            guard let existing = try Deck.fetchOne(db, key: id) else {
                throw DeckDAOError.notFound
            }
            if let duplicate = try Deck
                .filter(Column("name") == name)
                .fetchOne(db),
                duplicate.id != id
            {
                throw DeckDAOError.duplicateName(name)
            }

            let timestamp = now.ISO8601Format()
            try db.execute(
                sql: "UPDATE deck SET name = ?, modified_at = ? WHERE id = ?",
                arguments: [name, timestamp, id]
            )
            return Deck(
                id: id,
                name: name,
                source: existing.source,
                ankiDeckID: existing.ankiDeckID,
                createdAt: existing.createdAt,
                modifiedAt: timestamp
            )
        }
    }

    func deleteDeck(id: String) throws {
        try db.write { db in
            guard try Deck.fetchOne(db, key: id) != nil else {
                throw DeckDAOError.notFound
            }
            try db.execute(sql: "DELETE FROM deck WHERE id = ?", arguments: [id])
        }
    }
}
