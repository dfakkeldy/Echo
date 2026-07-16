// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Proves the selected-target `importDeckVNext(from:targetAudiobookID:db:)`
/// overload's write step (`DeckImportService.persistPortable`) is a single
/// atomic replacement keyed by the portable deck's stable `deckID`: a
/// successful call replaces exactly that deck's name/cards/timeline rows in
/// one transaction, and any failure — a collision, a mid-transaction fault,
/// or a source snapshot that changed underneath the import — leaves
/// whatever was there before completely unchanged.
@MainActor
@Suite struct PortableDeckPersistenceTests {

    // MARK: - Fixture helpers (mirrors PortableDeckPreflightTests)

    private func seedSelectedAudiobook(
        _ writer: DatabaseWriter, id: String, blocks: [EPubBlockRecord]
    ) throws {
        try writer.write { db in
            var audiobook = AudiobookRecord(
                id: id,
                title: id,
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
            )
            try audiobook.insert(db)
            for var block in blocks {
                try block.insert(db)
            }
        }
    }

    private func seedAudiobook(_ writer: DatabaseWriter, id: String) throws {
        try writer.write { db in
            var audiobook = AudiobookRecord(
                id: id,
                title: id,
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
            )
            try audiobook.insert(db)
        }
    }

    private func makeBlock(
        suffix: String,
        audiobookID: String,
        sequenceIndex: Int,
        text: String = "Block text"
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-\(audiobookID)-\(suffix)",
            audiobookID: audiobookID,
            spineHref: "Text/chapter.xhtml",
            spineIndex: sequenceIndex,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func makePortableCard(
        sourceAnchor: String?, frontText: String = "Question"
    ) -> FlashcardDeckImport.ImportedCard {
        FlashcardDeckImport.ImportedCard(
            frontText: frontText,
            backText: "Answer",
            startTime: nil,
            endTime: nil,
            triggerTiming: FlashcardTriggerTiming.manualOnly.rawValue,
            sourceAnchor: sourceAnchor,
            imageAnchor: nil,
            imageFile: nil
        )
    }

    private func makePortableDeckDocument(
        deckID: String,
        deckName: String,
        targetMediaID: String = "echo-portable:test-slug:core",
        sourceSignature: EchoSourceSignature,
        cards: [FlashcardDeckImport.ImportedCard]
    ) -> FlashcardDeckImport {
        FlashcardDeckImport(
            formatVersion: 2,
            deckID: deckID,
            deckName: deckName,
            targetBinding: "selectedBook",
            targetMediaID: targetMediaID,
            sourceSignature: sourceSignature,
            cards: cards
        )
    }

    private func writeDeckFile(_ deck: FlashcardDeckImport) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-deck-persist_\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(deck)
        try data.write(to: url)
        return url
    }

    // MARK: - Stable deck identity

    @Test
    func reimportSameDeckIDRenamesDeckAndReplacesCards() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.test.deck"

        let firstDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Core Review", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", frontText: "Old front")]
        )
        let firstURL = try writeDeckFile(firstDeck)
        defer { try? FileManager.default.removeItem(at: firstURL) }
        _ = try DeckImportService().importDeckVNext(
            from: firstURL, targetAudiobookID: "local-book", db: writer)

        let secondDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Renamed Core Review", sourceSignature: signature,
            cards: [
                makePortableCard(sourceAnchor: "s0-b0", frontText: "New front 1"),
                makePortableCard(sourceAnchor: "s0-b0", frontText: "New front 2"),
            ]
        )
        let secondURL = try writeDeckFile(secondDeck)
        defer { try? FileManager.default.removeItem(at: secondURL) }
        let replacementCardCount = secondDeck.cards.count
        _ = try DeckImportService().importDeckVNext(
            from: secondURL, targetAudiobookID: "local-book", db: writer)

        try writer.read { database in
            let name = try String.fetchOne(
                database, sql: "SELECT name FROM deck WHERE id = ?", arguments: [deckID])
            let deckCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM deck WHERE id = ?", arguments: [deckID])
            let cardCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
                arguments: [deckID])
            let staleCardCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE front_text = 'Old front'")
            #expect(name == "Renamed Core Review")
            #expect(deckCount == 1)
            #expect(cardCount == replacementCardCount)
            #expect(staleCardCount == 0)
        }
    }

    @Test
    func sameNameDifferentDeckIDsCoexist() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])

        let deckA = makePortableDeckDocument(
            deckID: "com.echo.deck.a", deckName: "Shared Name", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")])
        let deckB = makePortableDeckDocument(
            deckID: "com.echo.deck.b", deckName: "Shared Name", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")])
        let urlA = try writeDeckFile(deckA)
        let urlB = try writeDeckFile(deckB)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        _ = try DeckImportService().importDeckVNext(
            from: urlA, targetAudiobookID: "local-book", db: writer)
        _ = try DeckImportService().importDeckVNext(
            from: urlB, targetAudiobookID: "local-book", db: writer)

        try writer.read { database in
            let deckCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM deck WHERE name = ?",
                arguments: ["Shared Name"])
            let cardCountA = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
                arguments: ["com.echo.deck.a"])
            let cardCountB = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
                arguments: ["com.echo.deck.b"])
            #expect(deckCount == 2)
            #expect(cardCountA == 1)
            #expect(cardCountB == 1)
        }
    }

    /// A "different selected local copy" is a second local audiobook id whose
    /// canonical block content is identical (same signature) — e.g. the user
    /// re-imported the same EPUB under a fresh audiobook row. Reimporting the
    /// same portable deck against that copy must rebind the existing deck's
    /// cards to the new audiobook id, not create a duplicate deck.
    @Test
    func reimportToDifferentSelectedLocalCopyRebindsSameDeck() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block1 = makeBlock(suffix: "s0-b0", audiobookID: "local-book-1", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book-1", blocks: [block1])
        let block2 = makeBlock(suffix: "s0-b0", audiobookID: "local-book-2", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book-2", blocks: [block2])
        let signature = EchoSourceSignature.make(records: [block1])
        // Sanity: the two local copies really do share a canonical signature,
        // since only device-local ids differ between them.
        #expect(signature == EchoSourceSignature.make(records: [block2]))

        let deckID = "com.echo.rebind.deck"
        let deck = makePortableDeckDocument(
            deckID: deckID, deckName: "Rebind Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")])
        let url = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try DeckImportService().importDeckVNext(
            from: url, targetAudiobookID: "local-book-1", db: writer)
        _ = try DeckImportService().importDeckVNext(
            from: url, targetAudiobookID: "local-book-2", db: writer)

        try writer.read { database in
            let deckCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM deck WHERE id = ?", arguments: [deckID])
            let cardCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
                arguments: [deckID])
            let cardCountOnCopy2 = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ? AND audiobook_id = ?",
                arguments: [deckID, "local-book-2"])
            let cardCountOnCopy1 = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ? AND audiobook_id = ?",
                arguments: [deckID, "local-book-1"])
            #expect(deckCount == 1)
            #expect(cardCount == 1)
            #expect(cardCountOnCopy2 == 1)
            #expect(cardCountOnCopy1 == 0)
        }
    }

    // MARK: - Collision with a foreign deck id

    @Test
    func deckIDCollisionWithNonPortableDeckFails() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.collision.deck"

        // A pre-existing, non-portable deck (manual, or legacy json_import)
        // already occupies this id.
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO deck (id, name, source, created_at, modified_at)
                    VALUES (?, 'Manual Deck', 'manual', ?, ?)
                    """,
                arguments: [deckID, Date().ISO8601Format(), Date().ISO8601Format()])
        }

        let deck = makePortableDeckDocument(
            deckID: deckID, deckName: "Portable Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")])
        let url = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect {
            try DeckImportService().importDeckVNext(
                from: url, targetAudiobookID: "local-book", db: writer)
        } throws: { error in
            guard case DeckImportError.deckIDCollision(let id) = error else { return false }
            return id == deckID
        }

        try writer.read { database in
            let name = try String.fetchOne(
                database, sql: "SELECT name FROM deck WHERE id = ?", arguments: [deckID])
            let deckCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM deck WHERE id = ?", arguments: [deckID])
            let cardCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
                arguments: [deckID])
            #expect(name == "Manual Deck")
            #expect(deckCount == 1)
            #expect(cardCount == 0)
        }
    }

    // MARK: - Mid-transaction fault injection

    /// A database trigger raises `ABORT` when a flashcard's `front_text` is
    /// the sentinel `FAIL-SECOND-INSERT`, simulating a failure partway
    /// through the per-card insert loop. Fault injection stays entirely in
    /// this test database — production code has no matching hook. This
    /// proves `persistPortable`'s single write transaction really is atomic:
    /// the first card of the replacement set inserts fine, the second aborts
    /// the whole transaction, and the prior deck/cards/timeline survive
    /// byte-identical.
    @Test
    func faultDuringSecondCardInsertRollsBackAndLeavesOldDeckUnchanged() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.fault.deck"

        let firstDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Fault Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", frontText: "Original")]
        )
        let firstURL = try writeDeckFile(firstDeck)
        defer { try? FileManager.default.removeItem(at: firstURL) }
        _ = try DeckImportService().importDeckVNext(
            from: firstURL, targetAudiobookID: "local-book", db: writer)

        // Snapshot the surviving card's full row (not just front_text) before
        // the fault-injected reimport, so "unchanged" below proves it's the
        // literal same row untouched — not merely a different row that
        // happens to carry the same front text.
        let originalRow = try writer.read { database in
            try Row.fetchOne(
                database, sql: "SELECT * FROM flashcard WHERE deck_id = ?", arguments: [deckID])
        }

        try writer.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER fail_second_insert
                    BEFORE INSERT ON flashcard
                    WHEN NEW.front_text = 'FAIL-SECOND-INSERT'
                    BEGIN
                        SELECT RAISE(ABORT, 'fault injection: forced failure on card insert');
                    END
                    """)
        }

        let secondDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Fault Deck Replacement", sourceSignature: signature,
            cards: [
                makePortableCard(sourceAnchor: "s0-b0", frontText: "Replacement 1"),
                makePortableCard(sourceAnchor: "s0-b0", frontText: "FAIL-SECOND-INSERT"),
            ]
        )
        let secondURL = try writeDeckFile(secondDeck)
        defer { try? FileManager.default.removeItem(at: secondURL) }

        #expect {
            try DeckImportService().importDeckVNext(
                from: secondURL, targetAudiobookID: "local-book", db: writer)
        } throws: { error in
            error is GRDB.DatabaseError
        }

        try writer.read { database in
            let name = try String.fetchOne(
                database, sql: "SELECT name FROM deck WHERE id = ?", arguments: [deckID])
            let deckCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM deck WHERE id = ?", arguments: [deckID])
            let cardCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
                arguments: [deckID])
            let survivingRow = try Row.fetchOne(
                database, sql: "SELECT * FROM flashcard WHERE deck_id = ?", arguments: [deckID])
            let timelineCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM timeline_item WHERE source_table = 'flashcard'")
            #expect(name == "Fault Deck")
            #expect(deckCount == 1)
            #expect(cardCount == 1)
            // Every column of the surviving card's row — id, timestamps,
            // media, SRS fields, everything — is byte-identical to before
            // the failed reimport, not just its front text.
            #expect(survivingRow == originalRow)
            #expect(timelineCount == 1)
        }
    }

    // MARK: - Source-snapshot race

    /// Simulates the TOCTOU window `verifySourceSnapshot` exists to close.
    /// This installs a SQL trace on the reimporting connection that, the
    /// moment it observes the reimport's *preflight* read of `epub_block`,
    /// uses a second, independent writer against the same on-disk database
    /// to mutate that audiobook's canonical block text — as if a concurrent
    /// reimport or re-alignment job landed in the window between preflight
    /// and this reimport's own write-time revalidation. Preflight's
    /// transaction snapshot is already established before the trace fires,
    /// so it still succeeds against the pre-mutation data; the write-time
    /// re-check moments later opens a fresh transaction, observes the
    /// mutation, and must fail closed — leaving the earlier successful
    /// import's deck/cards/timeline untouched.
    @Test
    func writeTimeRevalidationCatchesConcurrentEditAndLeavesOldDeckUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-deck-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("echo.sqlite")

        // Fully migrate the file once via the app's real migration path, so
        // this test never has to duplicate the private migrator's
        // registration list.
        _ = try DatabaseService(databaseURL: dbURL)

        // `intruder` simulates a second, independent writer racing against
        // the reimport below (another import, or a re-alignment job).
        let intruder = try DatabaseService(databaseURL: dbURL).writer

        // `app` is opened as one dedicated connection (not a pool) so every
        // access it makes — preflight's read and persistPortable's write
        // alike — shares the single connection whose SQL trace is installed
        // below.
        var appConfig = Configuration()
        appConfig.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        let app: DatabaseWriter = try DatabaseQueue(path: dbURL.path, configuration: appConfig)
        // Close both connections before the directory-removal `defer` above
        // runs (defers unwind in reverse declaration order), so the file
        // isn't unlinked while still memory-mapped by an open connection.
        defer {
            try? app.close()
            try? intruder.close()
        }

        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(app, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deckID = "com.echo.race.deck"

        let baselineDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Race Deck", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let baselineURL = try writeDeckFile(baselineDeck)
        defer { try? FileManager.default.removeItem(at: baselineURL) }
        _ = try DeckImportService().importDeckVNext(
            from: baselineURL, targetAudiobookID: "local-book", db: app)

        let (baselineName, baselineFrontTexts, baselineTimelineCount) = try app.read { db in
            (
                try String.fetchOne(
                    db, sql: "SELECT name FROM deck WHERE id = ?", arguments: [deckID]),
                try String.fetchAll(
                    db,
                    sql: "SELECT front_text FROM flashcard WHERE deck_id = ? ORDER BY id",
                    arguments: [deckID]),
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM timeline_item WHERE source_table = 'flashcard'"
                ) ?? 0
            )
        }

        var hasFired = false
        try app.write { db in
            db.trace(options: .statement) { event in
                guard case .statement(let statement) = event, !hasFired else { return }
                let sql = statement.sql.lowercased()
                guard sql.contains("epub_block"), sql.contains("select") else { return }
                hasFired = true
                try? intruder.write { intruderDB in
                    try intruderDB.execute(
                        sql: "UPDATE epub_block SET text = ? WHERE audiobook_id = ?",
                        arguments: ["RACE-MUTATED", "local-book"])
                }
            }
        }

        let reimportDeck = makePortableDeckDocument(
            deckID: deckID, deckName: "Race Deck Renamed", sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let reimportURL = try writeDeckFile(reimportDeck)
        defer { try? FileManager.default.removeItem(at: reimportURL) }

        #expect {
            try DeckImportService().importDeckVNext(
                from: reimportURL, targetAudiobookID: "local-book", db: app)
        } throws: { error in
            guard case DeckImportError.sourceChangedDuringImport = error else { return false }
            return true
        }
        #expect(hasFired)

        try app.read { db in
            let name = try String.fetchOne(
                db, sql: "SELECT name FROM deck WHERE id = ?", arguments: [deckID])
            let deckCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM deck WHERE id = ?", arguments: [deckID])
            let frontTexts = try String.fetchAll(
                db,
                sql: "SELECT front_text FROM flashcard WHERE deck_id = ? ORDER BY id",
                arguments: [deckID])
            let timelineCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM timeline_item WHERE source_table = 'flashcard'")
            #expect(name == baselineName)
            #expect(deckCount == 1)
            #expect(frontTexts == baselineFrontTexts)
            #expect(timelineCount == baselineTimelineCount)
        }
    }

    // MARK: - FlashcardDAO in-transaction insertion seam (regression)

    /// `FlashcardDAO.insert(_:in:)` is the existing in-transaction boundary
    /// `persistPortable` relies on: calling it inside one writer transaction
    /// must insert both the flashcard row and its synced timeline row,
    /// without nesting a second transaction.
    @Test
    func flashcardDAOInsertInTransactionInsertsFlashcardAndTimelineRow() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedAudiobook(writer, id: "book-a")
        let now = Date().ISO8601Format()
        let card = Flashcard(
            id: "card-1",
            audiobookID: "book-a",
            frontText: "Front",
            backText: "Back",
            mediaTimestamp: 0,
            endTimestamp: nil,
            triggerTiming: .manualOnly,
            nextReviewDate: now,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: nil,
            tags: nil,
            mediaJSON: nil,
            sourceBlockID: nil,
            playlistPosition: nil,
            createdAt: now,
            modifiedAt: now
        )

        try writer.write { database in
            try FlashcardDAO.insert(card, in: database)
        }

        try writer.read { database in
            let flashcardCount = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM flashcard WHERE id = ?",
                arguments: ["card-1"])
            let timelineCount = try Int.fetchOne(
                database,
                sql:
                    "SELECT COUNT(*) FROM timeline_item WHERE source_table = 'flashcard' AND source_rowid = ?",
                arguments: ["card-1"])
            #expect(flashcardCount == 1)
            #expect(timelineCount == 1)
        }
    }
}
