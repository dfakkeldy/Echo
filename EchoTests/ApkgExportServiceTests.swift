import Testing
import Foundation
import GRDB
import ZIPFoundation
@testable import Echo

@MainActor
struct ApkgExportServiceTests {

    /// Creates an in-memory database with all schema migrations applied.
    private func makeTestDB() throws -> DatabaseWriter {
        try DatabaseService(inMemory: ()).writer
    }

    // MARK: - Helpers

    /// Inserts a test deck, audiobook, and a few flashcards into the database.
    private func populateDB(_ writer: DatabaseWriter, deckName: String = "Test Deck") throws -> String {
        let deckID = UUID().uuidString
        let audiobookID = "apkg-import-\(deckID.prefix(8))"
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, author, duration, added_at)
                VALUES (?, 'Test Book', 'Test Author', 3600, ?)
                """, arguments: [audiobookID, Date().ISO8601Format()])

            try db.execute(sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'manual', ?, ?)
                """, arguments: [
                deckID, deckName,
                Date().ISO8601Format(), Date().ISO8601Format()
            ])

            let cards: [(front: String, back: String)] = [
                ("What is mitosis?", "Cell division"),
                ("What is photosynthesis?", "Plants make food"),
                ("Capital of France?", "Paris"),
            ]

            for (front, back) in cards {
                let cardID = UUID().uuidString
                try db.execute(sql: """
                    INSERT INTO flashcard (id, audiobook_id, front_text, back_text,
                        media_timestamp, trigger_timing, next_review_date,
                        interval_days, ease_factor, repetitions, is_enabled, deck_id,
                        created_at, modified_at, card_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    cardID, audiobookID, front, back,
                    0, "manualOnly", Date().ISO8601Format(),
                    0, 2.5, 0, true, deckID,
                    Date().ISO8601Format(), Date().ISO8601Format(), "normal"
                ])
            }
        }
        return deckID
    }

    // MARK: - Export a single deck

    @Test func exportsSingleDeckAsApkg() throws {
        let writer = try makeTestDB()
        let deckID = try populateDB(writer)

        let service = ApkgExportService()
        let apkgURL = try service.export(deckID: deckID, db: writer)

        // The .apkg file must exist.
        #expect(FileManager.default.fileExists(atPath: apkgURL.path))

        // Validate it's a ZIP by opening with Archive.
        let archive = try Archive(url: apkgURL, accessMode: .read)
        let entryPaths = Set(archive.map(\.path))

        #expect(entryPaths.contains("collection.anki21"))
        // media file should also be present (even if empty)
        #expect(entryPaths.contains("media"))

        // Clean up
        try? FileManager.default.removeItem(at: apkgURL)
    }

    @Test func exportApkgContainsCorrectNoteCount() throws {
        let writer = try makeTestDB()
        let deckID = try populateDB(writer)

        let service = ApkgExportService()
        let apkgURL = try service.export(deckID: deckID, db: writer)
        defer { try? FileManager.default.removeItem(at: apkgURL) }

        // Extract and inspect the collection database
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_verify_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let archive = try Archive(url: apkgURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let dest = tmpDir.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: dest)
        }

        // Open the collection and verify
        let collectionURL = tmpDir.appendingPathComponent("collection.anki21")
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: collectionURL.path, configuration: config)

        let noteCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
        }
        let cardCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0
        }

        #expect(noteCount == 3)
        #expect(cardCount == 3)
    }

    @Test func exportThrowsForMissingDeck() throws {
        let writer = try makeTestDB()

        let service = ApkgExportService()
        #expect(throws: ApkgExportError.self) {
            try service.export(deckID: "nonexistent", db: writer)
        }
    }

    @Test func exportThrowsForEmptyDeck() throws {
        let writer = try makeTestDB()
        let deckID = UUID().uuidString
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'manual', ?, ?)
                """, arguments: [
                deckID, "Empty Deck",
                Date().ISO8601Format(), Date().ISO8601Format()
            ])
        }

        let service = ApkgExportService()
        #expect(throws: ApkgExportError.self) {
            try service.export(deckID: deckID, db: writer)
        }
    }

    // MARK: - Export all decks

    @Test func exportAllCombinesDecks() throws {
        let writer = try makeTestDB()
        _ = try populateDB(writer, deckName: "Deck A")
        _ = try populateDB(writer, deckName: "Deck B")

        let service = ApkgExportService()
        let apkgURL = try service.exportAll(db: writer)
        defer { try? FileManager.default.removeItem(at: apkgURL) }

        #expect(FileManager.default.fileExists(atPath: apkgURL.path))
    }

    // MARK: - Deck record

    @Test func deckRecordInsertsAndFetches() throws {
        let writer = try makeTestDB()
        let deckID = UUID().uuidString
        let now = Date().ISO8601Format()
        let deck = Echo.Deck(
            id: deckID,
            name: "Record Test",
            source: "test",
            ankiDeckID: 12345,
            createdAt: now,
            modifiedAt: now
        )

        try writer.write { db in
            var d = deck
            try d.insert(db)
        }

        let fetched = try writer.read { db in
            try Echo.Deck.fetchOne(db, key: deckID)
        }
        #expect(fetched != nil)
        #expect(fetched?.name == "Record Test")
        #expect(fetched?.ankiDeckID == 12345)
    }
}
