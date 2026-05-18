import Foundation
import GRDB

struct FlashcardDAO {
    let db: DatabaseWriter

    func flashcards(for audiobookID: String) throws -> [Flashcard] {
        try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .fetchAll(db)
        }
    }

    /// Cards due for review (next_review_date <= now).
    func dueCards(for audiobookID: String) throws -> [Flashcard] {
        try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("next_review_date") <= Date().ISO8601Format())
                .order(Column("next_review_date"))
                .fetchAll(db)
        }
    }

    /// All due cards across all audiobooks.
    func allDueCards() throws -> [Flashcard] {
        try db.read { db in
            try Flashcard
                .filter(Column("next_review_date") <= Date().ISO8601Format())
                .order(Column("next_review_date"))
                .fetchAll(db)
        }
    }

    func insert(_ card: Flashcard) throws {
        var copy = card
        try db.write { db in try copy.insert(db) }
    }

    func update(_ card: Flashcard) throws {
        var copy = card
        try db.write { db in try copy.update(db) }
    }

    /// Apply SM-2 grade and update scheduling.
    func grade(cardID: String, grade: Int, now: Date = Date()) throws {
        try db.write { db in
            guard let card = try Flashcard.fetchOne(db, key: cardID) else { return }
            let result = SpacedRepetitionService.apply(grade: grade, to: card)
            var updated = result
            try updated.update(db)
        }
    }
}
