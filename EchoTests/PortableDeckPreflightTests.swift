// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Every *failure*-path scenario here is a zero-mutation test:
/// `PortableDeckPreflight` and the write-time revalidation only read the
/// database before any row is written, so `audiobook`, `deck`, `flashcard`,
/// and `timeline_item` row counts must be identical before and after every
/// failing call. `importDeckVNextNeverPersistsSentinelAsAudiobookID` below is
/// the one success path, and is the exception: since atomic replacement
/// landed, a successful selected-target import really does persist the
/// deck's cards, so that test asserts the specific rows written instead of
/// an unchanged snapshot.
@MainActor
@Suite struct PortableDeckPreflightTests {

    // MARK: - Fixture helpers

    private struct DatabaseCounts: Equatable {
        let audiobooks: Int
        let decks: Int
        let flashcards: Int
        let timelineItems: Int
    }

    private func databaseCounts(_ writer: DatabaseWriter) throws -> DatabaseCounts {
        try writer.read { db in
            DatabaseCounts(
                audiobooks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audiobook") ?? 0,
                decks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deck") ?? 0,
                flashcards: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM flashcard") ?? 0,
                timelineItems: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM timeline_item") ?? 0
            )
        }
    }

    private func seedSelectedAudiobook(_ writer: DatabaseWriter, id: String) throws {
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

    private func makeBlock(
        suffix: String,
        audiobookID: String,
        sequenceIndex: Int,
        kind: EPubBlockRecord.Kind = .paragraph,
        text: String = "Block text",
        isFrontMatter: Bool = false,
        imagePath: String? = nil,
        wordCount: Int? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-\(audiobookID)-\(suffix)",
            audiobookID: audiobookID,
            spineHref: "Text/chapter.xhtml",
            spineIndex: sequenceIndex,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: kind.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: isFrontMatter,
            wordCount: wordCount,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func makePortableCard(
        sourceAnchor: String?,
        imageAnchor: String? = nil,
        imageFile: String? = nil
    ) -> FlashcardDeckImport.ImportedCard {
        FlashcardDeckImport.ImportedCard(
            frontText: "Question",
            backText: "Answer",
            startTime: nil,
            endTime: nil,
            triggerTiming: FlashcardTriggerTiming.manualOnly.rawValue,
            sourceAnchor: sourceAnchor,
            imageAnchor: imageAnchor,
            imageFile: imageFile
        )
    }

    private func makePortableDeckDocument(
        deckID: String = "com.echo.test.deck",
        deckName: String = "Preflight Deck",
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
            .appendingPathComponent("portable-deck_\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(deck)
        try data.write(to: url)
        return url
    }

    private let mismatchedSignature = EchoSourceSignature(
        algorithm: EchoSourceSignature.currentAlgorithm,
        value: "sha256:" + String(repeating: "a", count: 64)
    )

    // MARK: - Wrong signature (exact brief shape)

    @Test
    func importDeckVNextThrowsSourceSignatureMismatchAndMutatesNothing() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let deck = makePortableDeckDocument(
            sourceSignature: mismatchedSignature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.sourceSignatureMismatch = error else { return false }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    // MARK: - Selected-book resolution failures

    @Test
    func importDeckVNextThrowsWhenSelectedAudiobookIDIsMissing() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let deck = makePortableDeckDocument(
            sourceSignature: mismatchedSignature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "   ",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedAudiobookIDMissing = error else { return false }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    @Test
    func importDeckVNextThrowsWhenSelectedAudiobookDoesNotExist() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let deck = makePortableDeckDocument(
            sourceSignature: mismatchedSignature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "ghost-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedAudiobookNotFound("ghost-book") = error else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    @Test
    func importDeckVNextThrowsWhenSelectedAudiobookHasNoCanonicalBlocks() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        try seedSelectedAudiobook(writer, id: "local-book")
        let deck = makePortableDeckDocument(
            sourceSignature: mismatchedSignature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedAudiobookHasNoCanonicalBlocks("local-book") = error
            else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    // MARK: - Source anchor resolution failures

    @Test
    func importDeckVNextThrowsWhenSourceAnchorUnresolved() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deck = makePortableDeckDocument(
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s9-b9")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedSourceAnchorUnresolved(cardIndex: 0) = error else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    @Test
    func importDeckVNextThrowsWhenSourceAnchorResolvesToImage() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(
            suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0, kind: .image,
            text: "Figure", imagePath: "OEBPS/figure.png")
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deck = makePortableDeckDocument(
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedSourceAnchorResolvesToImage(cardIndex: 0) = error
            else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    @Test
    func importDeckVNextThrowsWhenSourceAnchorResolvesToFrontMatter() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(
            suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0,
            text: "Praise page", isFrontMatter: true)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deck = makePortableDeckDocument(
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedSourceAnchorResolvesToFrontMatter(cardIndex: 0) =
                error
            else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    /// Decode-time validation (`ValidatedDeckImport`) already rejects a
    /// malformed `sourceAnchor` for any real JSON document, so this exercises
    /// `PortableDeckPreflight.prepare` directly with a hand-built
    /// `PortableDeckImport` to cover the defensive re-check.
    @Test
    func preflightThrowsWhenSourceAnchorIsMalformed() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deck = PortableDeckImport(
            deckID: "com.echo.test.deck",
            deckName: "Preflight Deck",
            targetMediaID: "echo-portable:test-slug:core",
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "chapter-two")]
        )
        let deckURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-\(UUID().uuidString).json")

        let before = try databaseCounts(writer)
        #expect {
            try PortableDeckPreflight.prepare(
                deck: deck,
                targetAudiobookID: "local-book",
                deckURL: deckURL,
                dbReader: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedSourceAnchorMalformed(cardIndex: 0) = error else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    // MARK: - Image anchor resolution failures

    @Test
    func importDeckVNextThrowsWhenImageAnchorUnresolved() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let deck = makePortableDeckDocument(
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageAnchor: "s9-b9")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedImageAnchorUnresolved(cardIndex: 0) = error else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    @Test
    func importDeckVNextThrowsWhenImageAnchorResolvesToImageBlockWithoutStoredPath() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let sourceBlock = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        let imageBlock = makeBlock(
            suffix: "s0-b1", audiobookID: "local-book", sequenceIndex: 1, kind: .image,
            text: "Figure", imagePath: nil)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [sourceBlock, imageBlock])
        let signature = EchoSourceSignature.make(records: [sourceBlock, imageBlock])
        let deck = makePortableDeckDocument(
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageAnchor: "s0-b1")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedImageAnchorUnresolved(cardIndex: 0) = error else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    @Test
    func importDeckVNextThrowsWhenImageAnchorResolvesToText() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let sourceBlock = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        let textBlock = makeBlock(
            suffix: "s0-b1", audiobookID: "local-book", sequenceIndex: 1, text: "Not an image")
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [sourceBlock, textBlock])
        let signature = EchoSourceSignature.make(records: [sourceBlock, textBlock])
        let deck = makePortableDeckDocument(
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0", imageAnchor: "s0-b1")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        #expect {
            try DeckImportService().importDeckVNext(
                from: deckURL,
                targetAudiobookID: "local-book",
                db: writer
            )
        } throws: { error in
            guard case DeckImportError.selectedImageAnchorResolvesToNonImage(cardIndex: 0) = error
            else {
                return false
            }
            return true
        }
        #expect(try databaseCounts(writer) == before)
    }

    // MARK: - Sentinel isolation

    /// The regression this guards against: a naive selected-target import
    /// reusing the legacy path's "ensure the target audiobook exists" step
    /// would insert `deck.targetMediaID` (the portable sentinel, e.g.
    /// `echo-portable:test-slug:core`) into `audiobook.id`. That id must
    /// never appear there — only the caller-supplied `targetAudiobookID`.
    @Test
    func importDeckVNextNeverPersistsSentinelAsAudiobookID() throws {
        let writer = try DatabaseService(inMemory: ()).writer
        let block = makeBlock(suffix: "s0-b0", audiobookID: "local-book", sequenceIndex: 0)
        try seedSelectedAudiobook(writer, id: "local-book", blocks: [block])
        let signature = EchoSourceSignature.make(records: [block])
        let sentinel = "echo-portable:test-slug:core"
        let deck = makePortableDeckDocument(
            targetMediaID: sentinel,
            sourceSignature: signature,
            cards: [makePortableCard(sourceAnchor: "s0-b0")]
        )
        let deckURL = try writeDeckFile(deck)
        defer { try? FileManager.default.removeItem(at: deckURL) }

        let before = try databaseCounts(writer)
        let result = try DeckImportService().importDeckVNext(
            from: deckURL,
            targetAudiobookID: "local-book",
            db: writer
        )
        let after = try databaseCounts(writer)

        // The import persists the deck and its one card/timeline row against
        // the caller-supplied `targetAudiobookID`; the audiobook table (which
        // this import never writes to) is the only one left untouched.
        #expect(after.audiobooks == before.audiobooks)
        #expect(after.decks == before.decks + 1)
        #expect(after.flashcards == before.flashcards + 1)
        #expect(after.timelineItems == before.timelineItems + 1)

        // The counts are derived from rows actually written, not copied from
        // the plan's card count: this deck has exactly one card, and it
        // resolves to a real source block, so both counts are 1.
        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 1)

        try writer.read { db in
            let sentinelCount =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM audiobook WHERE id = ?", arguments: [sentinel])
                ?? 0
            #expect(sentinelCount == 0)
        }
    }
}
