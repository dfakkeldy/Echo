import Foundation
import GRDB
import ZIPFoundation
import os.log

// MARK: - Anki .apkg Export

enum ApkgExportError: LocalizedError {
    case noDeckFound(String)
    case noCardsToExport(String)
    case tempDirFailed(Error)
    case dbCreationFailed(Error)
    case zipFailed(Error)
    case mediaCopyFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .noDeckFound(let id):
            return "No deck found with id: \(id)"
        case .noCardsToExport(let name):
            return "Deck '\(name)' has no cards to export"
        case .tempDirFailed(let err):
            return "Failed to create temporary directory: \(err.localizedDescription)"
        case .dbCreationFailed(let err):
            return "Failed to create Anki collection database: \(err.localizedDescription)"
        case .zipFailed(let err):
            return "Failed to create .apkg archive: \(err.localizedDescription)"
        case .mediaCopyFailed(let file, let err):
            return "Failed to copy media file '\(file)': \(err.localizedDescription)"
        }
    }
}

/// Exports Echo flashcard decks as Anki .apkg files.
///
/// An .apkg is a ZIP archive containing:
/// - `collection.anki21` — a SQLite database with Anki's schema
/// - `media` — a JSON dict mapping numeric ids to original filenames
/// - `0`, `1`, `2`, … — referenced media files (audio / images)
struct ApkgExportService {
    private let logger = Logger(category: "ApkgExport")

    // MARK: - Public API

    /// Exports every flashcard belonging to `deckID` as an Anki .apkg file.
    ///
    /// - Parameters:
    ///   - deckID: The Echo deck ID to export.
    ///   - db: A GRDB DatabaseWriter containing the deck + flashcards.
    /// - Returns: URL of the generated `.apkg` file in a temporary directory.
    func export(deckID: String, db: DatabaseWriter) throws -> URL {
        let deck = try db.read { db in
            try Deck.fetchOne(db, key: deckID)
        }
        guard let deck else {
            throw ApkgExportError.noDeckFound(deckID)
        }

        let cards = try db.read { db in
            try Flashcard
                .filter(Column("deck_id") == deckID)
                .order(Column("created_at"))
                .fetchAll(db)
        }
        guard !cards.isEmpty else {
            throw ApkgExportError.noCardsToExport(deck.name)
        }

        return try buildApkg(deck: deck, cards: cards)
    }

    /// Exports all decks and their cards into a single .apkg file.
    func exportAll(db: DatabaseWriter) throws -> URL {
        let decks = try db.read { db in
            try Deck.fetchAll(db)
        }
        var allCards: [Flashcard] = []
        for deck in decks {
            let cards = try db.read { db in
                try Flashcard
                    .filter(Column("deck_id") == deck.id)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
            allCards.append(contentsOf: cards)
        }

        if allCards.isEmpty {
            let unassigned = try db.read { db in
                try Flashcard
                    .filter(Column("deck_id") == nil)
                    .fetchAll(db)
            }
            guard !unassigned.isEmpty else {
                throw ApkgExportError.noCardsToExport("all decks")
            }
            let fallbackDeck = Deck(
                id: "echo-all",
                name: "Echo Imported",
                source: "echo",
                ankiDeckID: nil,
                createdAt: Date().ISO8601Format(),
                modifiedAt: Date().ISO8601Format()
            )
            return try buildApkg(deck: fallbackDeck, cards: unassigned)
        }

        let containerDeck = Deck(
            id: "echo-all",
            name: "Echo Decks",
            source: "echo",
            ankiDeckID: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )
        return try buildApkg(deck: containerDeck, cards: allCards)
    }

    // MARK: - .apkg Builder

    private func buildApkg(deck: Deck, cards: [Flashcard]) throws -> URL {
        // 1. Temp directory
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            throw ApkgExportError.tempDirFailed(error)
        }
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 2. Build the Anki SQLite collection
        let ankiDBPath = tmpDir.appendingPathComponent("collection.anki21")
        try writeAnkiCollection(at: ankiDBPath, deck: deck, cards: cards)

        // 3. Copy media files
        let mediaMap = try copyMediaFiles(to: tmpDir, cards: cards)

        // 4. Write the media mapping file
        let mediaURL = tmpDir.appendingPathComponent("media")
        if let data = try? JSONSerialization.data(withJSONObject: mediaMap),
            let json = String(data: data, encoding: .utf8)
        {
            try json.write(to: mediaURL, atomically: true, encoding: .utf8)
        }

        // 5. ZIP the contents into .apkg (entries at root, no directory prefix)
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitize(deck.name)).apkg")
        try? FileManager.default.removeItem(at: apkgURL)

        do {
            let archive = try Archive(url: apkgURL, accessMode: .create)
            let items = try FileManager.default.contentsOfDirectory(
                at: tmpDir, includingPropertiesForKeys: nil)
            for item in items {
                let entryName = item.lastPathComponent
                // Use add method with the file path
                try archive.addEntry(with: entryName, relativeTo: tmpDir)
            }
        } catch {
            throw ApkgExportError.zipFailed(error)
        }

        logger.info("Exported .apkg to \(apkgURL.path)")
        return apkgURL
    }

    // MARK: - Anki Collection DB

    /// Writes a valid `collection.anki21` SQLite database at `dbURL`.
    private func writeAnkiCollection(at dbURL: URL, deck: Deck, cards: [Flashcard]) throws {
        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            // Set pragmas via configuration before the transaction.
            try queue.write { db in

                // -- Create schema --
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
                            id INTEGER PRIMARY KEY, nid INTEGER NOT NULL REFERENCES notes(id),
                            did INTEGER NOT NULL, ord INTEGER NOT NULL, mod INTEGER NOT NULL,
                            usn INTEGER NOT NULL, type INTEGER NOT NULL, queue INTEGER NOT NULL,
                            due INTEGER NOT NULL, ivl INTEGER NOT NULL, factor INTEGER NOT NULL,
                            reps INTEGER NOT NULL, lapses INTEGER NOT NULL, left INTEGER NOT NULL,
                            odue INTEGER NOT NULL, odid INTEGER NOT NULL, flags INTEGER NOT NULL,
                            data TEXT NOT NULL
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

                // -- Prepare data --
                let now = Int(Date().timeIntervalSince1970)
                let ankiDeckID = Int(deck.ankiDeckID ?? Int(Int64(deck.id.hashValue) & 0x7FFF_FFFF))
                let modelID: Int64 = 1_547_929_172_779

                let decksJSON = makeDeckJSON(ankiDeckID: ankiDeckID, name: deck.name)
                let modelsJSON = makeBasicModelJSON(modelID: modelID)

                try db.execute(
                    sql: """
                        INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        1, now, now, now, 21, 0, 0, now,
                        "{}", modelsJSON, decksJSON, "{}", "",
                    ])

                // Allocate note/card IDs from one base timestamp, strided by 2
                // (notes = base, base+2…; cards = base+1, base+3…) so the
                // INTEGER PRIMARY KEYs never collide. The old epoch-ms +
                // hashValue % 1000 could collide within a millisecond, and
                // hashValue is randomized per process.
                let baseID = Int64(Date().timeIntervalSince1970 * 1000)
                for (index, card) in cards.enumerated() {
                    let noteID = baseID + Int64(index) * 2
                    let guid = String(
                        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
                    let tags = card.tags ?? ""
                    let flds = "\(card.frontText)\u{1f}\(card.backText)"
                    let sfld = card.frontText
                    let csum = Int(crc32Checksum(sfld))

                    try db.execute(
                        sql: """
                            INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            noteID, guid, modelID, now, 0,
                            tags, flds, sfld, csum, 0, "",
                        ])

                    let cardID = noteID + 1
                    let factor = Int(card.easeFactor * 1000)
                    try db.execute(
                        sql: """
                            INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            cardID, noteID, ankiDeckID, 0, now, 0,
                            cardType(card), queueType(card), dueValue(card),
                            card.intervalDays, factor, card.repetitions, 0, 0, 0, 0, 0, "",
                        ])
                }
            }
        } catch {
            throw ApkgExportError.dbCreationFailed(error)
        }
    }

    // MARK: - Media

    /// Copies referenced media files into `tmpDir` as numerically-named files.
    private func copyMediaFiles(to tmpDir: URL, cards: [Flashcard]) throws -> [String: String] {
        var mapping: [String: String] = [:]
        var nextIndex = 0

        for card in cards {
            guard let json = card.mediaJSON,
                let data = json.data(using: .utf8),
                let entries = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { continue }

            for (fileName, sourcePath) in entries {
                let sourceURL = URL(fileURLWithPath: sourcePath)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                let indexKey = "\(nextIndex)"
                let destURL = tmpDir.appendingPathComponent(indexKey)
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                } catch {
                    logger.warning(
                        "Failed to copy media '\(fileName)': \(error.localizedDescription)")
                    continue
                }
                mapping[indexKey] = fileName
                nextIndex += 1
            }
        }
        return mapping
    }

    // MARK: - Helpers

    private func makeDeckJSON(ankiDeckID: Int, name: String) -> String {
        let now = Int(Date().timeIntervalSince1970)
        return """
            {"\(ankiDeckID)":{"id":\(ankiDeckID),"name":"\(escaped(name))","desc":"","collapsed":false,"conf":1,"dyn":0,"extendNew":0,"extendRev":0,"mid":null,"mod":\(now),"usn":0,"lrnToday":[0,0],"revToday":[0,0],"newToday":[0,0],"timeToday":[0,0],"browserCollapsed":false,"previewDelay":null}}
            """
    }

    private func makeBasicModelJSON(modelID: Int64) -> String {
        let now = Int(Date().timeIntervalSince1970)
        return """
            {"\(modelID)":{"id":\(modelID),"name":"Basic","type":0,"mod":\(now),"usn":0,"sortf":0,"did":1,"tags":[],"flds":[{"name":"Front","ord":0,"rtl":false,"sticky":false,"media":[],"font":"Arial","size":20},{"name":"Back","ord":1,"rtl":false,"sticky":false,"media":[],"font":"Arial","size":20}],"css":"","latexPre":"","latexPost":"","latexsvg":false,"req":[[0,"any",[0]]],"tmpls":[{"name":"Card 1","ord":0,"qfmt":"{{Front}}","afmt":"{{FrontSide}}\\n\\n<hr id=\\"answer\\">\\n\\n{{Back}}","did":null,"bfont":"","bsize":0}]}}
            """
    }

    private func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func cardType(_ card: Flashcard) -> Int {
        card.intervalDays > 0 ? 2 : 0
    }

    private func queueType(_ card: Flashcard) -> Int {
        card.intervalDays > 0 ? 2 : 0
    }

    private func dueValue(_ card: Flashcard) -> Int {
        card.intervalDays > 0 ? card.intervalDays : daysSinceEpoch()
    }

    private func daysSinceEpoch() -> Int {
        Int(Date().timeIntervalSince1970 / 86400)
    }

    private func sanitize(_ name: String) -> String {
        SafeFileName.sanitizeForFilename(name)
    }

    /// CRC-32 checksum (IEEE polynomial) used by Anki for note sorting.
    private func crc32Checksum(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(0)) { (crc, byte) in
            let lookupIndex = Int((crc ^ UInt32(byte)) & 0xFF)
            return (crc >> 8) ^ Self.crc32Table[lookupIndex]
        }
    }

    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }()
}
