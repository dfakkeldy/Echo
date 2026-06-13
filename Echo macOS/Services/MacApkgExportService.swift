//
//  MacApkgExportService.swift
//  Echo macOS
//
//  WS-12: macOS-native Anki .apkg export.
//  Mirrors the patterns of EchoCore's ApkgExportService for the macOS target.
//

import Foundation
import GRDB
import os.log

// MARK: - Errors

enum MacApkgExportError: LocalizedError {
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

/// Exports Echo flashcard decks as Anki .apkg files from the macOS app.
///
/// An .apkg is a ZIP archive containing:
/// - `collection.anki21` — a SQLite database with Anki's schema
/// - `media` — a JSON dict mapping numeric ids to original filenames
/// - `0`, `1`, `2`, … — referenced media files (audio / images)
///
/// This mirrors the patterns in EchoCore's `ApkgExportService`, reimplemented
/// here because EchoCore is not available to the macOS target.
struct MacApkgExportService {
    private let logger = Logger(category: "MacApkgExport")

    // MARK: - Public API

    /// Exports all cards from the given deck IDs into a single .apkg file.
    ///
    /// - Parameters:
    ///   - deckIDs: The Echo deck IDs to export. If empty, all decks are exported.
    ///   - db: A GRDB DatabaseWriter containing the decks + flashcards.
    /// - Returns: URL of the generated `.apkg` file in a temporary directory.
    func export(deckIDs: [String], db: DatabaseWriter) async throws -> URL {
        let decks: [Deck]
        if deckIDs.isEmpty {
            decks = try await db.read { try Deck.fetchAll($0) }
        } else {
            decks = try deckIDs.compactMap { id in
                try db.read { try Deck.fetchOne($0, key: id) }
            }
        }

        guard !decks.isEmpty else {
            let sampleID = deckIDs.first ?? "<empty>"
            throw MacApkgExportError.noDeckFound(sampleID)
        }

        var allCards: [Flashcard] = []
        for deck in decks {
            let cards = try await db.read { db in
                try Flashcard
                    .filter(Column("deck_id") == deck.id)
                    .order(Column("created_at"))
                    .fetchAll(db)
            }
            allCards.append(contentsOf: cards)
        }

        guard !allCards.isEmpty else {
            let names = decks.map(\.name).joined(separator: ", ")
            throw MacApkgExportError.noCardsToExport(names)
        }

        let containerName: String
        if decks.count == 1, let first = decks.first {
            containerName = first.name
        } else {
            containerName = "Echo Decks"
        }

        let containerDeck = Deck(
            id: "echo-export",
            name: containerName,
            source: "echo",
            ankiDeckID: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modifiedAt: ISO8601DateFormatter().string(from: Date())
        )

        return try await buildApkg(deck: containerDeck, cards: allCards)
    }

    // MARK: - .apkg Builder

    private func buildApkg(deck: Deck, cards: [Flashcard]) async throws -> URL {
        // 1. Temp directory
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            throw MacApkgExportError.tempDirFailed(error)
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
           let json = String(data: data, encoding: .utf8) {
            try json.write(to: mediaURL, atomically: true, encoding: .utf8)
        }

        // 5. ZIP the contents into .apkg using system `ditto` (avoids external dependency)
        let apkgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitize(deck.name)).apkg")
        try? FileManager.default.removeItem(at: apkgURL)

        do {
            try await createZipArchive(from: tmpDir, to: apkgURL)
        } catch {
            throw MacApkgExportError.zipFailed(error)
        }

        logger.info("Exported .apkg to \(apkgURL.path)")
        return apkgURL
    }

    /// Creates a ZIP archive using the system `/usr/bin/zip` command.
    /// Runs `zip -r -X <dest> .` from within `sourceDir` so all files
    /// appear at the archive root (as required by the .apkg format),
    /// without requiring the ZIPFoundation package on the macOS target.
    private func createZipArchive(from sourceDir: URL, to destURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", "-X", destURL.path, "."]
            process.currentDirectoryPath = sourceDir.path
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let error = NSError(domain: "MacApkgExport",
                                       code: Int(p.terminationStatus),
                                       userInfo: [NSLocalizedDescriptionKey: "zip exited with status \(p.terminationStatus)"])
                    continuation.resume(throwing: error)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Anki Collection DB

    /// Writes a valid `collection.anki21` SQLite database at `dbURL`.
    /// Follows the Anki 2.1 schema specification.
    private func writeAnkiCollection(at dbURL: URL, deck: Deck, cards: [Flashcard]) throws {
        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            try queue.write { db in
                // Create schema
                try db.execute(sql: """
                    CREATE TABLE col (
                        id INTEGER PRIMARY KEY,
                        crt INTEGER NOT NULL, mod INTEGER NOT NULL, scm INTEGER NOT NULL,
                        ver INTEGER NOT NULL, dty INTEGER NOT NULL, usn INTEGER NOT NULL,
                        ls INTEGER NOT NULL, conf TEXT NOT NULL, models TEXT NOT NULL,
                        decks TEXT NOT NULL, dconf TEXT NOT NULL, tags TEXT NOT NULL
                    )
                """)
                try db.execute(sql: """
                    CREATE TABLE notes (
                        id INTEGER PRIMARY KEY, guid TEXT NOT NULL, mid INTEGER NOT NULL,
                        mod INTEGER NOT NULL, usn INTEGER NOT NULL, tags TEXT NOT NULL,
                        flds TEXT NOT NULL, sfld TEXT NOT NULL, csum INTEGER NOT NULL,
                        flags INTEGER NOT NULL, data TEXT NOT NULL
                    )
                """)
                try db.execute(sql: """
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
                try db.execute(sql: """
                    CREATE TABLE revlog (
                        id INTEGER PRIMARY KEY, cid INTEGER NOT NULL, usn INTEGER NOT NULL,
                        ease INTEGER NOT NULL, ivl INTEGER NOT NULL, lastIvl INTEGER NOT NULL,
                        factor INTEGER NOT NULL, time INTEGER NOT NULL, type INTEGER NOT NULL
                    )
                """)

                // Prepare data
                let now = Int(Date().timeIntervalSince1970)
                let ankiDeckID = Int(deck.ankiDeckID ?? Int(Int64(deck.id.hashValue) & 0x7FFFFFFF))
                let modelID: Int64 = 1547929172779

                let decksJSON = makeDeckJSON(ankiDeckID: ankiDeckID, name: deck.name)
                let modelsJSON = makeBasicModelJSON(modelID: modelID)

                try db.execute(sql: """
                    INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    1, now, now, now, 21, 0, 0, now,
                    "{}", modelsJSON, decksJSON, "{}", ""
                ])

                // Insert notes and cards
                for card in cards {
                    let noteID = Int64(Date().timeIntervalSince1970 * 1000) + Int64(card.id.hashValue % 1000)
                    let guid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
                    let tags = card.tags ?? ""
                    let flds = "\(card.frontText)\u{1f}\(card.backText)"
                    let sfld = card.frontText
                    let csum = Int(crc32Checksum(sfld))

                    try db.execute(sql: """
                        INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        noteID, guid, modelID, now, 0,
                        tags, flds, sfld, csum, 0, ""
                    ])

                    let cardID = noteID + 1
                    let factor = Int(card.easeFactor * 1000)
                    try db.execute(sql: """
                        INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        cardID, noteID, ankiDeckID, 0, now, 0,
                        cardType(card), queueType(card), dueValue(card),
                        card.intervalDays, factor, card.repetitions, 0, 0, 0, 0, 0, ""
                    ])
                }
            }
        } catch {
            throw MacApkgExportError.dbCreationFailed(error)
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
                    logger.warning("Failed to copy media '\(fileName)': \(error.localizedDescription)")
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
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }()
}
