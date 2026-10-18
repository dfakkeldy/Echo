// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct MarkedPassageDAOTests {
    @Test func insertStoresInboxPassageForBook() throws {
        let writer = try makeWriter()
        let dao = MarkedPassageDAO(db: writer)

        let inserted = try dao.insert(
            audiobookID: "book-1",
            mediaTimestamp: 42,
            endTimestamp: 58,
            transcriptSnippet: "A useful line",
            note: "make a card"
        )

        let inbox = try dao.fetchInbox(for: "book-1")
        let passage = try #require(inbox.first)
        #expect(inbox.count == 1)
        #expect(passage.id == inserted.id)
        #expect(passage.status == "inbox")
        #expect(passage.mediaTimestamp == 42)
        #expect(passage.endTimestamp == 58)
        #expect(passage.transcriptSnippet == "A useful line")
        #expect(passage.note == "make a card")
        #expect(try dao.inboxCount() == 1)
    }

    @Test func fetchInboxScopesByBook() throws {
        let writer = try makeWriter()
        let dao = MarkedPassageDAO(db: writer)

        _ = try dao.insert(
            audiobookID: "book-1",
            mediaTimestamp: 12,
            endTimestamp: nil,
            transcriptSnippet: "Book one",
            note: nil
        )
        _ = try dao.insert(
            audiobookID: "book-2",
            mediaTimestamp: 24,
            endTimestamp: nil,
            transcriptSnippet: "Book two",
            note: nil
        )

        let bookOneInbox = try dao.fetchInbox(for: "book-1")
        let bookTwoInbox = try dao.fetchInbox(for: "book-2")

        #expect(bookOneInbox.map(\.audiobookID) == ["book-1"])
        #expect(bookTwoInbox.map(\.audiobookID) == ["book-2"])
        #expect(try dao.inboxCount() == 2)
    }

    @Test func convertedAndDismissedPassagesLeaveInbox() throws {
        let writer = try makeWriter()
        let dao = MarkedPassageDAO(db: writer)

        let converted = try dao.insert(
            audiobookID: "book-1",
            mediaTimestamp: 10,
            endTimestamp: 20,
            transcriptSnippet: "Convert me",
            note: nil
        )
        let dismissed = try dao.insert(
            audiobookID: "book-1",
            mediaTimestamp: 30,
            endTimestamp: 40,
            transcriptSnippet: "Dismiss me",
            note: nil
        )

        try dao.markConverted(id: converted.id, cardID: "card-1")
        try dao.dismiss(id: dismissed.id)

        #expect(try dao.fetchAllInbox().isEmpty)
        #expect(try dao.inboxCount() == 0)

        let rows = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, status, converted_card_id
                FROM marked_passage
                ORDER BY media_timestamp
                """)
        }

        #expect(rows.map { $0["status"] as String } == ["converted", "dismissed"])
        #expect(rows[0]["converted_card_id"] as String? == "card-1")
        #expect(rows[1]["converted_card_id"] as String? == nil)
    }

    private func makeWriter() throws -> DatabaseWriter {
        let writer = try DatabaseService(inMemory: ()).writer
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, author, duration, added_at)
                    VALUES
                        ('book-1', 'Book One', NULL, 3600, ?),
                        ('book-2', 'Book Two', NULL, 1800, ?)
                    """,
                arguments: [Date().ISO8601Format(), Date().ISO8601Format()]
            )
        }
        return writer
    }
}
