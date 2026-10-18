// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct DeckImportImageTests {
    /// Insert one figure image block so an imageAnchor can resolve to it.
    /// Also seeds the parent `audiobook` row: `epub_block.audiobook_id` is a
    /// NOT NULL FK and `PRAGMA foreign_keys=ON` is set on the in-memory
    /// database (see `DatabaseService.init(inMemory:)`), so inserting the
    /// block alone throws "FOREIGN KEY constraint failed".
    private func seedFigureBlock(_ db: DatabaseService, audiobookID: String, imagePath: String)
        throws
    {
        try db.writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO audiobook (id, title, author, duration, added_at)
                    VALUES (?, ?, 'Test Author', 0, ?)
                    """,
                arguments: [audiobookID, audiobookID, Date().ISO8601Format()])
            try database.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index, sequence_index,
                       block_kind, text, image_path, is_hidden, is_front_matter)
                    VALUES (?, ?, 'pdf', 9, 0, 0, 'image', NULL, ?, 0, 0)
                    """,
                arguments: ["epub-\(audiobookID)-s9-b0", audiobookID, imagePath])
        }
    }

    private func writeDeckBundle(_ dir: URL, json: String, images: [String: Data]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("deck.echo-deck.json"))
        let imagesDir = dir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        for (name, bytes) in images { try bytes.write(to: imagesDir.appendingPathComponent(name)) }
    }

    @Test func imageAnchorResolvesToFigureBlockImagePath() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-1"
        try seedFigureBlock(db, audiobookID: book, imagePath: "/tmp/EPUBAssets/book-1/fig-0.png")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
            {"deckName":"D","targetMediaID":"\(book)","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly",
               "sourceAnchor":"s9-b0","imageAnchor":"s9-b0"}]}
            """
        try writeDeckBundle(dir, json: json, images: [:])
        let service = DeckImportService()
        _ = try service.importDeckVNext(
            from: dir.appendingPathComponent("deck.echo-deck.json"), db: db.writer)
        let media = try db.writer.read { d in
            try String.fetchOne(d, sql: "SELECT media_json FROM flashcard LIMIT 1")
        }
        // Decode rather than substring-match the raw JSON: JSONEncoder escapes
        // "/" as "\/" on this Foundation, so a raw `.contains()` on the path
        // would false-negative even though the JSON decodes correctly.
        #expect(
            StudyCardMedia.imagePath(fromMediaJSON: media) == "/tmp/EPUBAssets/book-1/fig-0.png")
    }

    @Test func imageFileCopiesIntoStorageAndSetsMediaJSON() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-2"
        try seedFigureBlock(db, audiobookID: book, imagePath: "/unused")  // gives target blocks
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
            {"deckName":"D","targetMediaID":"\(book)","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly",
               "sourceAnchor":"s9-b0","imageFile":"images/card-0.png"}]}
            """
        try writeDeckBundle(
            dir, json: json, images: ["card-0.png": Data([0x89, 0x50, 0x4E, 0x47])])
        let service = DeckImportService()
        _ = try service.importDeckVNext(from: dir, db: db.writer)
        let media = try db.writer.read { d in
            try String.fetchOne(d, sql: "SELECT media_json FROM flashcard LIMIT 1")
        }
        let path = try #require(StudyCardMedia.imagePath(fromMediaJSON: media))
        defer {
            // Clean up the real Application Support/DeckMedia/<deckID>/ dir this test creates.
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func imageFileManifestRequiresFolderSelection() throws {
        let db = try DatabaseService(inMemory: ())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
            {"deckName":"D","targetMediaID":"book","cards":[
              {"frontText":"Q","backText":"A","startTime":0,"endTime":1,
               "triggerTiming":"manualOnly","imageFile":"images/card-0.png"}]}
            """
        try writeDeckBundle(
            dir, json: json, images: ["card-0.png": Data([0x89, 0x50, 0x4E, 0x47])])

        let thrown = try #require(throws: DeckImportError.self) {
            _ = try DeckImportService().importDeckVNext(
                from: dir.appendingPathComponent("deck.echo-deck.json"), db: db.writer)
        }
        guard case .bundledImagesRequireFolder(cardIndex: 0) = thrown else {
            Issue.record("Expected bundledImagesRequireFolder(cardIndex: 0), got \(thrown)")
            return
        }
    }

    @Test func bothImageFieldsSetThrows() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-3"
        try seedFigureBlock(db, audiobookID: book, imagePath: "/x")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
            {"deckName":"D","targetMediaID":"\(book)","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly",
               "sourceAnchor":"s9-b0","imageAnchor":"s9-b0","imageFile":"images/x.png"}]}
            """
        try writeDeckBundle(dir, json: json, images: [:])
        let service = DeckImportService()
        // `DeckImportError` has `Error`-payload cases so it isn't Equatable; capture
        // the thrown error and pattern-match the specific case.
        let thrown = try #require(throws: DeckImportError.self) {
            _ = try service.importDeckVNext(
                from: dir.appendingPathComponent("deck.echo-deck.json"), db: db.writer)
        }
        guard case .conflictingImageFields(cardIndex: 0) = thrown else {
            Issue.record("Expected conflictingImageFields(cardIndex: 0), got \(thrown)")
            return
        }
    }

    /// A path-traversal / absolute `imageFile` must import the card as TEXT-ONLY
    /// (nil media_json) and copy nothing — the untrusted value is rejected before
    /// any file copy, and (per the non-fatal resolution design) image resolution
    /// never throws, so the card still imports.
    @Test func traversalImageFileImportsTextOnlyAndCopiesNothing() throws {
        let db = try DatabaseService(inMemory: ())
        let book = "book-4"
        try seedFigureBlock(db, audiobookID: book, imagePath: "/unused")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Plant a real file one level ABOVE the bundle dir that "../evil.png"
        // resolves to, proving the guard blocks it even when the target exists.
        let evil = dir.deletingLastPathComponent().appendingPathComponent("evil.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: evil)
        defer { try? FileManager.default.removeItem(at: evil) }
        let json = """
            {"deckName":"D","targetMediaID":"\(book)","cards":[
              {"frontText":"Q","backText":"A","triggerTiming":"manualOnly",
               "sourceAnchor":"s9-b0","imageFile":"../evil.png"}]}
            """
        try writeDeckBundle(dir, json: json, images: [:])
        let service = DeckImportService()
        let result = try service.importDeckVNext(from: dir, db: db.writer)
        #expect(result.importedCount == 1)  // card still imports (non-fatal)
        let media = try db.writer.read { d in
            try String.fetchOne(d, sql: "SELECT media_json FROM flashcard LIMIT 1")
        }
        #expect(media == nil)  // text-only: the traversal path was rejected
        // Prove nothing was copied: no "evil.png" landed anywhere under DeckMedia.
        let deckMediaRoot = URL.applicationSupportDirectory.appending(path: "DeckMedia")
        if let enumerator = FileManager.default.enumerator(atPath: deckMediaRoot.path) {
            for case let name as String in enumerator {
                #expect(!name.hasSuffix("evil.png"))
            }
        }
    }
}
