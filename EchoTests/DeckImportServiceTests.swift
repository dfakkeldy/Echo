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

    // MARK: - vNext anchor resolution tests

    @Test
    func importDeckVNextResolvesSourceAnchor() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s1-b2"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Anchored Deck",
              "targetMediaID": "book-a",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "startTime": 0,
                  "endTime": 5,
                  "sourceAnchor": "s1-b2",
                  "triggerTiming": "beginning"
                }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 1)
        #expect(result.warningCount == 0)

        let cards = try writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.count == 1)
        #expect(cards.first?.sourceBlockID == "epub-book-a-s1-b2")
    }

    @Test
    func importDeckVNextAllowsResolvedSourceAnchorWithoutTimestamps() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s1-b2"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Anchor Only Deck",
              "targetMediaID": "book-a",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "sourceAnchor": "s1-b2",
                  "triggerTiming": "manualOnly"
                }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 1)
        #expect(result.warningCount == 0)

        let card = try writer.read { db in try Flashcard.fetchOne(db) }
        #expect(card?.sourceBlockID == "epub-book-a-s1-b2")
        #expect(card?.mediaTimestamp == 0)
        #expect(card?.endTimestamp == nil)
    }

    @Test
    func importDeckVNextAllowsResolvedSourceAnchorWithDegenerateZeroRange() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s1-b2"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Builder Deck",
              "targetMediaID": "book-a",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "startTime": 0,
                  "endTime": 0,
                  "sourceAnchor": "s1-b2",
                  "triggerTiming": "manualOnly"
                }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 1)
        #expect(result.warningCount == 0)

        let card = try writer.read { db in try Flashcard.fetchOne(db) }
        #expect(card?.sourceBlockID == "epub-book-a-s1-b2")
        #expect(card?.mediaTimestamp == 0)
        #expect(card?.endTimestamp == nil)
    }

    @Test
    func importDeckVNextRejectsSourceOnlyCardWhenAnchorDoesNotResolve() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Unresolved Anchor Only Deck",
              "targetMediaID": "book-a",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "sourceAnchor": "s9-b9",
                  "triggerTiming": "manualOnly"
                }
              ]
            }
            """)

        #expect {
            try DeckImportService().importDeckVNext(from: url, db: writer)
        } throws: { error in
            guard case DeckImportError.invalidTimeRange(cardIndex: 0) = error else {
                return false
            }
            return true
        }
    }

    @Test
    func importDeckVNextRehomesFullLegacyBlockID() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-b", blockIDs: ["epub-book-b-s0-b0"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Rehomed Deck",
              "targetMediaID": "book-b",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "startTime": 0,
                  "endTime": 5,
                  "triggerTiming": "manualOnly",
                  "sourceAnchor": "epub-old-book-s0-b0"
                }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.anchoredCount == 1)
        #expect(result.importedCount == 1)
        #expect(result.warnings.isEmpty)
        let cards = try writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.first?.sourceBlockID == "epub-book-b-s0-b0")
    }

    @Test
    func importDeckVNextImportsUnresolvedAnchorWithWarning() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Partially Anchored Deck",
              "targetMediaID": "book-a",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "startTime": 0,
                  "endTime": 5,
                  "triggerTiming": "manualOnly",
                  "sourceAnchor": "s9-b9"
                }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 0)
        #expect(
            result.warnings == [
                .sourceAnchorUnresolved(cardReference: "json-card-0", sourceAnchor: "s9-b9")
            ])

        let cards = try writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.first?.sourceBlockID == nil)
    }

    @Test
    func importDeckVNextImportsMalformedAnchorWithWarning() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Malformed Anchor Deck",
              "targetMediaID": "book-a",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "startTime": 0,
                  "endTime": 5,
                  "triggerTiming": "manualOnly",
                  "sourceAnchor": "chapter-1-paragraph-2"
                }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 0)
        #expect(
            result.warnings == [
                .sourceAnchorMalformed(
                    cardReference: "json-card-0", sourceAnchor: "chapter-1-paragraph-2")
            ])

        let cards = try writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.first?.sourceBlockID == nil)
    }

    @Test
    func importDeckVNextImportsWrongBookAnchorWithWarning() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b0"])
        try seedBookWithBlocks(writer, targetID: "book-b", blockIDs: ["epub-book-b-s1-b1"])
        let url = try writeDeckJSON(
            """
            {
              "deckName": "Wrong Book Anchor Deck",
              "targetMediaID": "book-b",
              "cards": [
                {
                  "frontText": "Question",
                  "backText": "Answer",
                  "startTime": 0,
                  "endTime": 5,
                  "triggerTiming": "manualOnly",
                  "sourceAnchor": "epub-book-a-s0-b0"
                }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 0)
        #expect(
            result.warnings == [
                .sourceAnchorWrongBook(
                    cardReference: "json-card-0", sourceAnchor: "epub-book-a-s0-b0")
            ])

        let cards = try writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.first?.sourceBlockID == nil)
    }

    @Test
    func importDeckVNextReportsTargetWithoutEPUBBlocksOnce() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedAudiobook(writer, id: "book-without-blocks")
        let url = try writeDeckJSON(
            """
            {
              "deckName": "No Blocks Deck",
              "targetMediaID": "book-without-blocks",
              "cards": [
                { "frontText": "One", "backText": "Answer", "startTime": 0, "endTime": 5, "triggerTiming": "manualOnly", "sourceAnchor": "s0-b0" },
                { "frontText": "Two", "backText": "Answer", "startTime": 5, "endTime": 10, "triggerTiming": "manualOnly", "sourceAnchor": "s0-b1" }
              ]
            }
            """)

        let result = try DeckImportService().importDeckVNext(from: url, db: writer)

        #expect(result.importedCount == 2)
        #expect(result.anchoredCount == 0)
        #expect(
            result.warnings == [
                .targetAudiobookHasNoEPUBBlocks(targetMediaID: "book-without-blocks")
            ])

        let cards = try writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.map(\.sourceBlockID) == [nil, nil])
    }

    // MARK: - Seed helpers

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

    private func seedBookWithBlocks(_ writer: DatabaseWriter, targetID: String, blockIDs: [String])
        throws
    {
        try writer.write { db in
            var audiobook = AudiobookRecord(
                id: targetID,
                title: targetID,
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
            )
            try audiobook.insert(db)

            for (index, blockID) in blockIDs.enumerated() {
                var block = EPubBlockRecord(
                    id: blockID,
                    audiobookID: targetID,
                    spineHref: "Text/chapter.xhtml",
                    spineIndex: index,
                    blockIndex: index,
                    sequenceIndex: index,
                    blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                    text: "Block \(index)",
                    htmlContent: nil,
                    cardColor: nil,
                    chapterThemeColor: nil,
                    imagePath: nil,
                    chapterIndex: index,
                    isHidden: false,
                    hiddenReason: nil,
                    isFrontMatter: false,
                    wordCount: nil,
                    markers: nil,
                    textFormats: nil,
                    createdAt: nil,
                    modifiedAt: nil
                )
                try block.insert(db)
            }
        }
    }
}
