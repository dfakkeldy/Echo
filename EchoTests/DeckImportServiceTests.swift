// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct DeckImportServiceTests {

    private func writeDeckJSON(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck_\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// §5.4: importing a deck whose `targetMediaID` names a book not yet on this
    /// device must succeed by creating a placeholder `audiobook` row, rather than
    /// aborting on the `flashcard.audiobook_id` NOT NULL foreign key.
    @Test func importCreatesPlaceholderAudiobookForUnknownTarget() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let targetID = "not-yet-imported-book.m4b"
        let json = """
            {
              "deckName": "Chapter 1 Vocabulary",
              "targetMediaID": "\(targetID)",
              "cards": [
                {"frontText": "Q1", "backText": "A1", "startTime": 0, "endTime": 5, "triggerTiming": "manualOnly"},
                {"frontText": "Q2", "backText": "A2", "startTime": 5, "endTime": 10, "triggerTiming": "manualOnly"}
              ]
            }
            """
        let url = try writeDeckJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try DeckImportService().importDeck(from: url, db: writer)
        #expect(count == 2)

        try writer.read { db in
            let bookExists =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM audiobook WHERE id = ?", arguments: [targetID])
                ?? 0
            #expect(bookExists == 1)
            let cardCount =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM flashcard WHERE audiobook_id = ?",
                    arguments: [targetID]) ?? 0
            #expect(cardCount == 2)
        }
    }

    /// When the target audiobook already exists, the INSERT OR IGNORE must not
    /// clobber its real title.
    @Test func importDoesNotOverwriteExistingAudiobookTitle() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let targetID = "real-book.m4b"
        try writer.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, author, duration, added_at) VALUES (?, 'Real Title', 'Real Author', 3600, ?)",
                arguments: [targetID, Date().ISO8601Format()])
        }
        let json = """
            {
              "deckName": "Deck",
              "targetMediaID": "\(targetID)",
              "cards": [
                {"frontText": "Q", "backText": "A", "startTime": 0, "endTime": 5, "triggerTiming": "manualOnly"}
              ]
            }
            """
        let url = try writeDeckJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try DeckImportService().importDeck(from: url, db: writer)

        let title = try writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT title FROM audiobook WHERE id = ?", arguments: [targetID])
        }
        #expect(title == "Real Title")
    }
}
