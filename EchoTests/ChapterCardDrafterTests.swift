// SPDX-License-Identifier: GPL-3.0-or-later

import GRDB
import Testing

@testable import Echo

struct ChapterCardDrafterTests {
    let drafter = ChapterCardDrafter()

    func makeDB() async throws -> DatabaseWriter {
        let db = try DatabaseQueue()
        try await db.write { db in
            try db.create(table: "audiobook") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
            }
            try db.create(table: "deck") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("source", .text).notNull()
                t.column("created_at", .text)
                t.column("modified_at", .text)
            }
            try db.create(table: "flashcard") { t in
                t.column("id", .text).primaryKey()
                t.column("audiobook_id", .text).notNull()
                t.column("front_text", .text).notNull()
                t.column("back_text", .text).notNull()
                t.column("media_timestamp", .double)
                t.column("trigger_timing", .text).notNull()
                t.column("interval_days", .integer)
                t.column("ease_factor", .double)
                t.column("repetitions", .integer)
                t.column("is_enabled", .boolean)
                t.column("card_type", .text).notNull().defaults(to: "normal")
                t.column("source_block_id", .text)
                t.column("deck_id", .text).references("deck")
                t.column("next_review_date", .text)
                t.column("last_reviewed_at", .text)
                t.column("last_grade", .integer)
                t.column("tags", .text)
                t.column("media_json", .text)
                t.column("stability", .double)
                t.column("difficulty", .double)
                t.column("cloze_index", .integer)
                t.column("playlist_position", .double)
                t.column("end_timestamp", .double)
                t.column("created_at", .text)
                t.column("modified_at", .text)
            }
            try db.create(table: "epub_block") { t in
                t.column("id", .text).primaryKey()
                t.column("audiobook_id", .text).notNull()
                t.column("text", .text)
                t.column("block_kind", .text).notNull()
                t.column("chapter_index", .integer)
                t.column("sequence_index", .integer)
                t.column("is_front_matter", .boolean).defaults(to: false)
                t.column("is_hidden", .boolean).defaults(to: false)
            }
        }
        return db
    }

    @Test func draftsCardsForHeadings() async throws {
        let db = try await makeDB()
        let bookID = "test-book"
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)",
                arguments: [bookID, "Test Book"])
            for i in 0..<3 {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index, is_front_matter)
                        VALUES (?, ?, ?, 'heading', ?, ?, 0)
                        """, arguments: ["h\(i)", bookID, "Chapter \(i+1)", i, i])
            }
        }

        let count = try await drafter.draftCards(for: bookID, bookTitle: "Test Book", db: db)
        #expect(count == 3)
    }

    @Test func skipsFrontMatter() async throws {
        let db = try await makeDB()
        let bookID = "test-book2"
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)", arguments: [bookID, "Test"])
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index, is_front_matter)
                    VALUES ('h0', ?, 'Preface', 'heading', 0, 0, 1)
                    """, arguments: [bookID])
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index, is_front_matter)
                    VALUES ('h1', ?, 'Chapter 1', 'heading', 1, 1, 0)
                    """, arguments: [bookID])
        }

        let count = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: db)
        #expect(count == 1)
    }

    @Test func skipsHiddenHeadings() async throws {
        let db = try await makeDB()
        let bookID = "test-book-hidden"
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)", arguments: [bookID, "Test"])
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index, is_front_matter, is_hidden)
                    VALUES ('h0', ?, 'Visible Chapter', 'heading', 0, 0, 0, 0)
                    """, arguments: [bookID])
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index, is_front_matter, is_hidden)
                    VALUES ('h1', ?, 'Hidden Chapter', 'heading', 1, 1, 0, 1)
                    """, arguments: [bookID])
        }

        let count = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: db)
        #expect(count == 1)  // only the visible heading is drafted
    }

    @Test func idempotentReRunDoesNotDuplicate() async throws {
        let db = try await makeDB()
        let bookID = "test-book3"
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)", arguments: [bookID, "Test"])
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index)
                    VALUES ('h0', ?, 'Ch1', 'heading', 0, 0)
                    """, arguments: [bookID])
        }

        _ = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: db)
        let second = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: db)
        #expect(second == 0)
    }

    @Test func createsDeckNamedAfterBook() async throws {
        let db = try await makeDB()
        let bookID = "test-book4"
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)",
                arguments: [bookID, "The Scarlet Letter"])
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index)
                    VALUES ('h0', ?, 'The Prison Door', 'heading', 0, 0)
                    """, arguments: [bookID])
        }

        _ = try await drafter.draftCards(for: bookID, bookTitle: "The Scarlet Letter", db: db)
        let deckName = try await db.read { db in
            try String.fetchOne(
                db, sql: "SELECT name FROM deck WHERE name = ?", arguments: ["The Scarlet Letter"])
        }
        #expect(deckName == "The Scarlet Letter")
    }

    @Test func emptyBookReturnsZero() async throws {
        let db = try await makeDB()
        let count = try await drafter.draftCards(for: "no-book", bookTitle: "Nothing", db: db)
        #expect(count == 0)
    }
}
