// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
struct ApkgImportServiceTests {

    /// Creates an in-memory database with all schema migrations applied.
    private func makeTestDB() throws -> DatabaseWriter {
        try DatabaseService(inMemory: ()).writer
    }

    // MARK: - Fixture creation

    private struct FixtureApkgIdentity {
        let cardID: Int64
        let noteGUID: String
    }

    /// Builds a minimal valid .apkg file at `destURL` with a single note + card.
    /// When `sidecarJSON` is non-nil the JSON string is written to `echo-import.json`
    /// inside the archive. Returns the deterministic card/note identifiers so tests
    /// can reference them.
    @discardableResult
    private func createFixtureApkg(
        destURL: URL,
        deckName: String = "Test Deck",
        front: String = "Hello",
        back: String = "World",
        format: String = "collection.anki21",
        mediaFiles: [(name: String, data: Data)] = [],
        noteID: Int64 = 1_712_345_678_000,
        cardID: Int64 = 1_712_345_678_001,
        noteGUID: String = "echo-note-guid",
        sidecarJSON: String? = nil
    ) async throws -> FixtureApkgIdentity {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_fixture_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent(format)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=OFF")
            try db.execute(sql: "PRAGMA synchronous=OFF")
        }
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try await queue.write { db in

            // Create schema
            try db.execute(
                sql: """
                    CREATE TABLE col (
                        id INTEGER PRIMARY KEY,
                        crt INTEGER NOT NULL, mod INTEGER NOT NULL, scm INTEGER NOT NULL,
                        ver INTEGER NOT NULL, dty INTEGER NOT NULL, usn INTEGER NOT NULL,
                        ls INTEGER NOT NULL, conf TEXT NOT NULL, models TEXT NOT NULL,
                        decks TEXT NOT NULL, dconf TEXT NOT NULL, tags TEXT NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE notes (
                        id INTEGER PRIMARY KEY, guid TEXT NOT NULL, mid INTEGER NOT NULL,
                        mod INTEGER NOT NULL, usn INTEGER NOT NULL, tags TEXT NOT NULL,
                        flds TEXT NOT NULL, sfld TEXT NOT NULL, csum INTEGER NOT NULL,
                        flags INTEGER NOT NULL, data TEXT NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE cards (
                        id INTEGER PRIMARY KEY, nid INTEGER NOT NULL, did INTEGER NOT NULL,
                        ord INTEGER NOT NULL, mod INTEGER NOT NULL, usn INTEGER NOT NULL,
                        type INTEGER NOT NULL, queue INTEGER NOT NULL, due INTEGER NOT NULL,
                        ivl INTEGER NOT NULL, factor INTEGER NOT NULL, reps INTEGER NOT NULL,
                        lapses INTEGER NOT NULL, left INTEGER NOT NULL, odue INTEGER NOT NULL,
                        odid INTEGER NOT NULL, flags INTEGER NOT NULL, data TEXT NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE revlog (
                        id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, usn INTEGER NOT NULL,
                        ease INTEGER NOT NULL, ivl INTEGER NOT NULL, lastIvl INTEGER NOT NULL,
                        factor INTEGER NOT NULL, time INTEGER NOT NULL, type INTEGER NOT NULL
                    )
                    """)

            let now = 1_712_345_678
            let decksJSON = """
                {"1":{"id":1,"name":"\(deckName)","desc":"","collapsed":false,"conf":1,"dyn":0}}
                """
            let modelsJSON = """
                {"1547929172779":{"id":1547929172779,"name":"Basic","type":0,"mod":\(now),"usn":0,"sortf":0,"did":1,"tags":[],"flds":[{"name":"Front","ord":0},{"name":"Back","ord":1}],"tmpls":[{"name":"Card 1","ord":0,"qfmt":"{{Front}}","afmt":"{{Back}}"}]}}
                """

            try db.execute(
                sql: """
                    INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                    VALUES (1, ?, ?, ?, 21, 0, 0, ?, '{}', ?, ?, '{}', '')
                    """, arguments: [now, now, now, now, modelsJSON, decksJSON])

            // Insert a note with deterministic IDs so tests can key on them.
            let fields = "\(front)\u{1f}\(back)"
            try db.execute(
                sql: """
                    INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, 1547929172779, ?, 0, '', ?, ?, 0, 0, '')
                    """, arguments: [noteID, noteGUID, now, fields, front])

            // Insert a card with deterministic ID.
            try db.execute(
                sql: """
                    INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                    VALUES (?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 2500, 0, 0, 0, 0, 0, 0, '')
                    """, arguments: [cardID, noteID, now])
        }

        // Write Anki's media manifest and numbered media files.
        var mediaMap: [String: String] = [:]
        for (index, file) in mediaFiles.enumerated() {
            let key = "\(index)"
            mediaMap[key] = file.name
            try file.data.write(to: tmpDir.appendingPathComponent(key))
        }
        let mediaData = try JSONSerialization.data(withJSONObject: mediaMap, options: [.sortedKeys])
        try mediaData.write(to: tmpDir.appendingPathComponent("media"))

        // Optionally write the echo-import.json sidecar.
        if let sidecarJSON {
            try sidecarJSON.write(
                to: tmpDir.appendingPathComponent("echo-import.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        // ZIP (entries at root, no directory prefix)
        try? FileManager.default.removeItem(at: destURL)
        let archive = try Archive(url: destURL, accessMode: .create)
        let items = try FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil)
        for item in items {
            try archive.addEntry(with: item.lastPathComponent, relativeTo: tmpDir)
        }

        return FixtureApkgIdentity(cardID: cardID, noteGUID: noteGUID)
    }

    // MARK: - Sidecar seed helper

    private func seedBookWithBlocks(
        _ writer: DatabaseWriter, targetID: String, blockIDs: [String]
    ) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, author, duration, added_at)
                    VALUES (?, ?, 'Test Author', 0, ?)
                    """,
                arguments: [
                    targetID, targetID,
                    Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format(),
                ])

            for (index, blockID) in blockIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, chapter_index, is_hidden)
                        VALUES (?, ?, 'Text/chapter.xhtml', ?, ?, ?, 'paragraph', ?, 0)
                        """,
                    arguments: [blockID, targetID, index, index, index, index])
            }
        }
    }

    // MARK: - anki21 import

    @Test func importsAnki21Apkg() async throws {
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_anki21.apkg")
        try await createFixtureApkg(destURL: apkgURL, front: "Question", back: "Answer")
        defer { try? FileManager.default.removeItem(at: apkgURL) }

        let writer = try makeTestDB()
        let service = ApkgImportService()
        let count = try await service.import(from: apkgURL, into: writer)

        #expect(count == 1)

        // Verify the deck and flashcard were created.
        let deckName = try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM deck LIMIT 1")
        }
        #expect(deckName == "Test Deck")

        let cards = try await writer.read { db in
            try Flashcard.fetchAll(db)
        }
        #expect(cards.count == 1)
        #expect(cards[0].frontText == "Question")
        #expect(cards[0].backText == "Answer")
    }

    @Test func importedMediaRoundTripsThroughApkgExport() async throws {
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_media_roundtrip.apkg")
        let soundData = Data("sound-bytes".utf8)
        let imageData = Data("image-bytes".utf8)
        try await createFixtureApkg(
            destURL: apkgURL,
            front: "Listen [sound:ding.mp3]",
            back: "<img src=\"diagram.png\">",
            mediaFiles: [
                (name: "ding.mp3", data: soundData),
                (name: "diagram.png", data: imageData),
                (name: "unused.png", data: Data("unused".utf8)),
            ]
        )
        defer { try? FileManager.default.removeItem(at: apkgURL) }

        let writer = try makeTestDB()
        let importService = ApkgImportService()
        let count = try await importService.import(from: apkgURL, into: writer)
        #expect(count == 1)

        let card = try await writer.read { db in
            try Flashcard.fetchOne(db)
        }
        let mediaJSON = try #require(card?.mediaJSON)
        let importedMediaObject = try JSONSerialization.jsonObject(with: Data(mediaJSON.utf8))
        let importedMedia = try #require(importedMediaObject as? [String: String])
        #expect(Set(importedMedia.keys) == ["ding.mp3", "diagram.png"])
        #expect(importedMedia["unused.png"] == nil)

        let importedMediaDirectory = URL(
            fileURLWithPath: try #require(importedMedia["ding.mp3"])
        )
        .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: importedMediaDirectory) }
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: try #require(importedMedia["ding.mp3"])))
                == soundData)
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: try #require(importedMedia["diagram.png"])))
                == imageData)

        let deckID = try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM deck LIMIT 1")
        }
        let exportedURL = try ApkgExportService().export(deckID: try #require(deckID), db: writer)
        defer { try? FileManager.default.removeItem(at: exportedURL) }

        let exportedDirectory = try extractApkg(exportedURL)
        defer { try? FileManager.default.removeItem(at: exportedDirectory) }
        let manifestData = try Data(
            contentsOf: exportedDirectory.appendingPathComponent("media")
        )
        let manifestObject = try JSONSerialization.jsonObject(with: manifestData)
        let manifest = try #require(manifestObject as? [String: String])
        let soundEntry = try #require(manifest.first { $0.value == "ding.mp3" }?.key)
        let imageEntry = try #require(manifest.first { $0.value == "diagram.png" }?.key)

        #expect(
            try Data(contentsOf: exportedDirectory.appendingPathComponent(soundEntry)) == soundData)
        #expect(
            try Data(contentsOf: exportedDirectory.appendingPathComponent(imageEntry)) == imageData)
    }

    // MARK: - anki21b import

    @Test func importsAnki21bApkg() async throws {
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_anki21b.apkg")
        try await createFixtureApkg(
            destURL: apkgURL, front: "Cloze Question", back: "Cloze Answer",
            format: "collection.anki21b")
        defer { try? FileManager.default.removeItem(at: apkgURL) }

        let writer = try makeTestDB()
        let service = ApkgImportService()
        let count = try await service.import(from: apkgURL, into: writer)

        #expect(count == 1)

        let cards = try await writer.read { db in
            try Flashcard.fetchAll(db)
        }
        #expect(cards[0].frontText == "Cloze Question")
        #expect(cards[0].backText == "Cloze Answer")
    }

    // MARK: - anki2 import

    @Test func importsAnki2Apkg() async throws {
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_anki2.apkg")
        try await createFixtureApkg(
            destURL: apkgURL, front: "Old Anki", back: "Version 2",
            format: "collection.anki2")
        defer { try? FileManager.default.removeItem(at: apkgURL) }

        let writer = try makeTestDB()
        let service = ApkgImportService()
        let count = try await service.import(from: apkgURL, into: writer)

        #expect(count == 1)

        let cards = try await writer.read { db in
            try Flashcard.fetchAll(db)
        }
        #expect(cards[0].frontText == "Old Anki")
        #expect(cards[0].backText == "Version 2")
    }

    // MARK: - Multi-card import

    @Test func importsMultipleCards() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_fixture_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("collection.anki21")
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=OFF")
            try db.execute(sql: "PRAGMA synchronous=OFF")
        }
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try await queue.write { db in

            try db.execute(
                sql: """
                    CREATE TABLE col (id INTEGER PRIMARY KEY, crt INTEGER NOT NULL, mod INTEGER NOT NULL,
                        scm INTEGER NOT NULL, ver INTEGER NOT NULL, dty INTEGER NOT NULL,
                        usn INTEGER NOT NULL, ls INTEGER NOT NULL, conf TEXT NOT NULL,
                        models TEXT NOT NULL, decks TEXT NOT NULL, dconf TEXT NOT NULL, tags TEXT NOT NULL)
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE notes (id INTEGER PRIMARY KEY, guid TEXT NOT NULL, mid INTEGER NOT NULL,
                        mod INTEGER NOT NULL, usn INTEGER NOT NULL, tags TEXT NOT NULL,
                        flds TEXT NOT NULL, sfld TEXT NOT NULL, csum INTEGER NOT NULL,
                        flags INTEGER NOT NULL, data TEXT NOT NULL)
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE cards (id INTEGER PRIMARY KEY, nid INTEGER NOT NULL, did INTEGER NOT NULL,
                        ord INTEGER NOT NULL, mod INTEGER NOT NULL, usn INTEGER NOT NULL,
                        type INTEGER NOT NULL, queue INTEGER NOT NULL, due INTEGER NOT NULL,
                        ivl INTEGER NOT NULL, factor INTEGER NOT NULL, reps INTEGER NOT NULL,
                        lapses INTEGER NOT NULL, left INTEGER NOT NULL, odue INTEGER NOT NULL,
                        odid INTEGER NOT NULL, flags INTEGER NOT NULL, data TEXT NOT NULL)
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, usn INTEGER NOT NULL,
                        ease INTEGER NOT NULL, ivl INTEGER NOT NULL, lastIvl INTEGER NOT NULL,
                        factor INTEGER NOT NULL, time INTEGER NOT NULL, type INTEGER NOT NULL)
                    """)

            let now = Int(Date().timeIntervalSince1970)
            let decksJSON = """
                {"1":{"id":1,"name":"Multi Deck","desc":"","collapsed":false,"conf":1,"dyn":0}}
                """
            let modelsJSON = """
                {"1547929172779":{"id":1547929172779,"name":"Basic","type":0,"mod":\(now),"usn":0,"sortf":0,"did":1,"tags":[],"flds":[{"name":"Front","ord":0},{"name":"Back","ord":1}],"tmpls":[{"name":"Card 1","ord":0,"qfmt":"{{Front}}","afmt":"{{Back}}"}]}}
                """
            try db.execute(
                sql: """
                    INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                    VALUES (1, ?, ?, ?, 21, 0, 0, ?, '{}', ?, ?, '{}', '')
                    """, arguments: [now, now, now, now, modelsJSON, decksJSON])

            let pairs = [("Q1", "A1"), ("Q2", "A2"), ("Q3", "A3")]
            for (i, (front, back)) in pairs.enumerated() {
                let noteID = Int64(now) * 1000 + Int64(i)
                let guid = String(
                    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
                let flds = "\(front)\u{1f}\(back)"
                try db.execute(
                    sql: """
                        INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                        VALUES (?, ?, 1547929172779, ?, 0, '', ?, ?, 0, 0, '')
                        """, arguments: [noteID, guid, now, flds, front])
                try db.execute(
                    sql: """
                        INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                        VALUES (?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 2500, 0, 0, 0, 0, 0, 0, '')
                        """, arguments: [noteID + 1, noteID, now])
            }
        }

        try "{}".write(
            to: tmpDir.appendingPathComponent("media"), atomically: true, encoding: .utf8)

        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi_test.apkg")
        try? FileManager.default.removeItem(at: apkgURL)
        let archive = try Archive(url: apkgURL, accessMode: .create)
        let items = try FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil)
        for item in items {
            try archive.addEntry(with: item.lastPathComponent, relativeTo: tmpDir)
        }
        defer { try? FileManager.default.removeItem(at: apkgURL) }

        let writer = try makeTestDB()
        let service = ApkgImportService()
        let count = try await service.import(from: apkgURL, into: writer)

        #expect(count == 3)

        let cards = try await writer.read { db in
            try Flashcard.fetchAll(db)
        }
        #expect(cards.count == 3)
        #expect(cards.map(\.frontText).sorted() == ["Q1", "Q2", "Q3"])
    }

    // MARK: - Error cases

    @Test func rejectsInvalidFile() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent.apkg")
        // This should not crash — let it throw.
        let writer = try! makeTestDB()
        let service = ApkgImportService()
        await #expect(throws: (any Error).self) {
            try await service.import(from: bogusURL, into: writer)
        }
    }

    @Test func rejectsNonApkgZip() async throws {
        // Create a ZIP that isn't an Anki collection
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake_apkg_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try "not a collection".write(
            to: tmpDir.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake.apkg")
        try? FileManager.default.removeItem(at: apkgURL)
        try FileManager.default.zipItem(at: tmpDir, to: apkgURL)
        defer { try? FileManager.default.removeItem(at: apkgURL) }
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = try makeTestDB()
        let service = ApkgImportService()
        await #expect(throws: ApkgImportService.ImportError.self) {
            try await service.import(from: apkgURL, into: writer)
        }
    }

    private func extractApkg(_ apkgURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_extract_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let archive = try Archive(url: apkgURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let entryURL = destination.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: entryURL)
        }
        return destination
    }

    // MARK: - importVNext sidecar tests

    @Test
    func importVNextResolvesSidecarCardIDAnchor() async throws {
        let writer = try makeTestDB()
        try await seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b1"])
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar_card_id_\(UUID().uuidString).apkg")
        defer { try? FileManager.default.removeItem(at: apkgURL) }
        let identity = try await createFixtureApkg(
            destURL: apkgURL,
            sidecarJSON: """
                {
                  "formatVersion": 1,
                  "targetMediaID": "book-a",
                  "cards": [
                    {
                      "cardID": \(1_712_345_678_001 as Int64),
                      "sourceAnchor": "s0-b1",
                      "startTime": 10.5,
                      "endTime": 15.25,
                      "triggerTiming": "beginning"
                    }
                  ]
                }
                """
        )

        #expect(identity.cardID == 1_712_345_678_001)
        let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 1)
        #expect(result.warningCount == 0)

        let cards = try await writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.first?.audiobookID == "book-a")
        #expect(cards.first?.sourceBlockID == "epub-book-a-s0-b1")
        #expect(cards.first?.mediaTimestamp == 10.5)
        #expect(cards.first?.endTimestamp == 15.25)
        #expect(cards.first?.triggerTiming == .beginning)
    }

    @Test
    func importVNextResolvesSidecarNoteGUIDAnchor() async throws {
        let writer = try makeTestDB()
        try await seedBookWithBlocks(writer, targetID: "book-a", blockIDs: ["epub-book-a-s0-b1"])
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar_note_guid_\(UUID().uuidString).apkg")
        defer { try? FileManager.default.removeItem(at: apkgURL) }
        let identity = try await createFixtureApkg(
            destURL: apkgURL,
            sidecarJSON: """
                {
                  "formatVersion": 1,
                  "targetMediaID": "book-a",
                  "cards": [
                    {
                      "noteGUID": "echo-note-guid",
                      "sourceAnchor": "s0-b1"
                    }
                  ]
                }
                """
        )

        #expect(identity.noteGUID == "echo-note-guid")
        let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

        #expect(result.anchoredCount == 1)
        let cards = try await writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.first?.sourceBlockID == "epub-book-a-s0-b1")
    }

    @Test
    func importVNextReportsInvalidSidecarButImportsDeck() async throws {
        let writer = try makeTestDB()
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid_sidecar_\(UUID().uuidString).apkg")
        defer { try? FileManager.default.removeItem(at: apkgURL) }
        try await createFixtureApkg(destURL: apkgURL, sidecarJSON: "{ invalid json")

        let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 0)
        #expect(result.warningCount == 1)
        guard case .apkgSidecarDecodeFailed = result.warnings.first else {
            Issue.record("Expected APKG sidecar decode warning")
            return
        }

        let cards = try await writer.read { db in try Flashcard.fetchAll(db) }
        #expect(cards.first?.audiobookID == "apkg-import")
        #expect(cards.first?.sourceBlockID == nil)
    }

    @Test
    func importVNextReportsSidecarMissingTargetMediaID() async throws {
        let writer = try makeTestDB()
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_target_\(UUID().uuidString).apkg")
        defer { try? FileManager.default.removeItem(at: apkgURL) }
        try await createFixtureApkg(
            destURL: apkgURL,
            sidecarJSON: """
                {
                  "formatVersion": 1,
                  "cards": [
                    { "cardID": 1712345678001, "sourceAnchor": "s0-b1" }
                  ]
                }
                """
        )

        let result = try await ApkgImportService().importVNext(from: apkgURL, into: writer)

        #expect(result.importedCount == 1)
        #expect(result.anchoredCount == 0)
        #expect(result.warnings.contains(.apkgSidecarMissingTargetMediaID))
    }
}
