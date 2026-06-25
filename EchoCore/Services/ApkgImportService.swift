// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import ZIPFoundation
import os.log

/// Imports Anki .apkg files (anki21b, anki21, anki2) into Echo's flashcard
/// database.
///
/// ## Format support
/// - **anki21b**: Anki 2.1.50+ with STRICT tables — detected by the
///   `collection.anki21b` file inside the ZIP.
/// - **anki21**: Anki 2.1.x — `collection.anki21`.
/// - **anki2**: Anki 2.0.x — `collection.anki2`.
///
/// The three formats share the same logical schema (`col`, `notes`, `cards`,
/// `revlog` tables). The service detects the actual `.anki*` filename and
/// opens it via GRDB, so schema-version-specific handling is minimal.
nonisolated struct ApkgImportService {
    private let logger = Logger(category: "ApkgImport")

    enum ImportError: LocalizedError {
        case notAnApkg
        case unsupportedFormat(String)
        case dbOpenFailed(Error)
        case mappingFailed(String)
        case extractionFailed(Error)
        case insertionFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notAnApkg:
                return "The file is not a valid .apkg archive (missing collection file)."
            case .unsupportedFormat(let detail):
                return "Unsupported Anki format: \(detail)"
            case .dbOpenFailed(let error):
                return "Failed to open the Anki collection database: \(error.localizedDescription)"
            case .mappingFailed(let detail):
                return "Failed to map Anki data: \(detail)"
            case .extractionFailed(let error):
                return "Failed to extract .apkg archive: \(error.localizedDescription)"
            case .insertionFailed(let error):
                return "Failed to insert cards into Echo database: \(error.localizedDescription)"
            }
        }
    }

    /// Known collection-database filenames, newest first.
    private static let collectionFiles = [
        "collection.anki21b",
        "collection.anki21",
        "collection.anki2",
    ]

    // MARK: - Import

    /// Imports flashcards from an .apkg file into the Echo database.
    ///
    /// - Parameters:
    ///   - url: The .apkg file URL.
    ///   - writer: A GRDB DatabaseWriter for the Echo database.
    /// - Returns: Number of flashcards imported.
    func `import`(from url: URL, into writer: DatabaseWriter) async throws -> Int {
        // 1. Unzip to temp directory (zip-slip-safe)
        let tmpDir = try extractSafely(apkgURL: url)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 2. Detect the collection format
        guard let (collectionURL, formatName) = findCollection(in: tmpDir) else {
            throw ImportError.notAnApkg
        }

        logger.info("Detected Anki format: \(formatName) at \(collectionURL.lastPathComponent)")

        // 3. Open the collection database read-only
        let loadedCollection: CollectionData
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: collectionURL.path, configuration: config)
            loadedCollection = try await queue.read { db in
                try readCollection(db, format: formatName)
            }
        } catch {
            throw ImportError.dbOpenFailed(error)
        }
        var collectionWithMedia = loadedCollection
        collectionWithMedia.mediaMap = readMediaMap(in: tmpDir)
        let collection = collectionWithMedia
        let referencedMediaNames = mediaReferences(
            in: collection.notes.map(\.flds).joined(separator: "\u{1f}")
        )
        let importedMedia = importMediaFiles(
            from: tmpDir,
            mediaMap: collection.mediaMap,
            referencedFileNames: referencedMediaNames
        )

        guard !collection.notes.isEmpty else {
            logger.info("No notes found in collection.")
            return 0
        }

        // 4. Insert into Echo database in one transaction
        let imported = try await writer.write { db in
            try importCards(collection: collection, importedMedia: importedMedia, db: db)
        }

        logger.info("Imported \(imported) flashcards from .apkg")
        return imported
    }

    // MARK: - Extraction (zip-slip-safe)

    /// Extracts the .apkg ZIP into a temp directory, guarding against
    /// directory-traversal attacks (zip-slip).  Pattern from
    /// `EPUBAutoImportScanner.extractEPUB`.
    private func extractSafely(apkgURL: URL) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_import_\(UUID().uuidString)", isDirectory: true)

        // Copy to a local cache so Archive can access it reliably.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg_cache_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let cachedApkg = cacheDir.appendingPathComponent(apkgURL.lastPathComponent)
        try FileManager.default.copyItem(at: apkgURL, to: cachedApkg)

        let archive: Archive
        do {
            archive = try Archive(url: cachedApkg, accessMode: .read)
        } catch {
            throw ImportError.extractionFailed(error)
        }

        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        var totalExtracted: UInt64 = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            // Reject decompression bombs before touching the filesystem (audit §6.1).
            do {
                totalExtracted = try ArchiveExtractionLimits.checkedTotal(
                    addingEntryOfSize: entry.uncompressedSize, to: totalExtracted
                )
            } catch {
                throw ImportError.extractionFailed(error)
            }
            let destination = try Self.safeDestination(for: entry.path, within: tmpDir)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: destination)
        }

        return tmpDir
    }

    /// Validates that `entryPath` resolves inside `root`, throwing on
    /// absolute paths or `..` traversal.  Copied from EPUBAutoImportScanner.
    static func safeDestination(for entryPath: String, within root: URL) throws -> URL {
        guard !entryPath.hasPrefix("/") else {
            throw ImportError.extractionFailed(Archive.ArchiveError.invalidEntryPath)
        }

        let destination = root.appendingPathComponent(entryPath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path

        guard destination.path == rootPath || destination.path.hasPrefix(rootPath + "/") else {
            throw ImportError.extractionFailed(Archive.ArchiveError.invalidEntryPath)
        }

        return destination
    }

    // MARK: - Collection Detection

    private func findCollection(in dir: URL) -> (url: URL, format: String)? {
        for filename in Self.collectionFiles {
            let url = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return (url, filename)
            }
        }
        return nil
    }

    // MARK: - Reading

    private struct CollectionData {
        var notes: [AnkiNote] = []
        var cards: [AnkiCard] = []
        var deckName: String = "Imported"
        var mediaMap: [String: String] = [:]
    }

    private struct AnkiNote {
        var id: Int64
        var guid: String
        var mid: Int64
        var tags: String
        var flds: String  // Field values separated by \x1f
        var sfld: String  // Sort field (usually Front)
    }

    private struct AnkiCard {
        var id: Int64
        var nid: Int64  // Note ID
        var did: Int64  // Deck ID
        var ord: Int  // Card ordinal within note
        var type: Int
        var queue: Int
        var ivl: Int  // Interval in days
        var factor: Int  // Ease factor (1000ths)
        var reps: Int
    }

    private func readCollection(_ db: Database, format: String) throws -> CollectionData {
        // --- Read deck name from col.decks ---
        var deckName = "Imported"
        if let decksJSON = try String.fetchOne(db, sql: "SELECT decks FROM col LIMIT 1") {
            deckName = parseFirstDeckName(from: decksJSON) ?? "Imported"
        }

        // --- Read notes ---
        let noteRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, guid, mid, tags, flds, sfld FROM notes
                """)

        let notes: [AnkiNote] = noteRows.map { row in
            AnkiNote(
                id: row["id"],
                guid: row["guid"],
                mid: row["mid"],
                tags: row["tags"] as? String ?? "",
                flds: row["flds"] as? String ?? "",
                sfld: row["sfld"] as? String ?? ""
            )
        }

        // --- Read cards ---
        let cardRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, nid, did, ord, type, queue, ivl, factor, reps FROM cards
                """)

        let cards: [AnkiCard] = cardRows.map { row in
            AnkiCard(
                id: row["id"],
                nid: row["nid"],
                did: row["did"],
                ord: row["ord"],
                type: row["type"],
                queue: row["queue"],
                ivl: row["ivl"] as? Int ?? 0,
                factor: row["factor"] as? Int ?? 2500,
                reps: row["reps"] as? Int ?? 0
            )
        }

        return CollectionData(notes: notes, cards: cards, deckName: deckName)
    }

    // MARK: - Mapping & Insertion

    /// Maps Anki notes+cards to Echo flashcards and inserts in one transaction.
    private func importCards(
        collection: CollectionData,
        importedMedia: [String: String],
        db: Database
    ) throws -> Int {
        // Build a tolerant note lookup (last wins on duplicate IDs).
        var noteMap: [Int64: AnkiNote] = [:]
        for note in collection.notes {
            noteMap[note.id] = note
        }

        // Find or create the Echo deck
        let deckID: String
        if let existingID = try findDeck(named: collection.deckName, db: db) {
            deckID = existingID
        } else {
            deckID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO deck (id, name, source, created_at, modified_at)
                    VALUES (?, ?, 'apkg_import', ?, ?)
                    """,
                arguments: [
                    deckID, collection.deckName, Date().ISO8601Format(), Date().ISO8601Format(),
                ])
        }

        // Ensure a placeholder audiobook exists for the FK constraint.
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO audiobook (id, title, author, duration, added_at)
                VALUES ('apkg-import', 'Imported from Anki', 'apkg', 0, ?)
                """, arguments: [Date().ISO8601Format()])

        var importedCount = 0

        for card in collection.cards {
            guard let note = noteMap[card.nid] else { continue }

            // Split fields on \x1f (ASCII unit separator).
            // For Basic notes: flds[0] = Front, flds[1] = Back.
            // For Cloze notes: flds[0] = Text (with cloze markers), flds[1] = Extra.
            let fields = note.flds.components(separatedBy: "\u{1f}")
            let frontText = fields.indices.contains(0) ? fields[0] : note.sfld
            let backText = fields.indices.contains(1) ? fields[1] : ""

            // Skip cards with empty front/back.
            guard !frontText.isEmpty else { continue }

            let easeFactor = card.factor > 0 ? Double(card.factor) / 1000.0 : 2.5
            var flashcard = Flashcard(
                id: UUID().uuidString,
                audiobookID: "apkg-import",
                frontText: frontText,
                backText: backText,
                mediaTimestamp: 0,
                endTimestamp: nil,
                triggerTiming: .manualOnly,
                nextReviewDate: Date().ISO8601Format(),
                intervalDays: max(0, card.ivl),
                easeFactor: max(1.3, easeFactor),
                repetitions: max(0, card.reps),
                lastReviewedAt: nil,
                lastGrade: nil,
                isEnabled: true,
                deckID: deckID,
                tags: note.tags.isEmpty ? nil : note.tags,
                mediaJSON: mediaJSON(for: note, importedMedia: importedMedia),
                sourceBlockID: nil,
                playlistPosition: nil,
                createdAt: Date().ISO8601Format(),
                modifiedAt: Date().ISO8601Format()
            )
            try flashcard.insert(db)
            importedCount += 1
        }

        return importedCount
    }

    private func findDeck(named name: String, db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT id FROM deck WHERE name = ?", arguments: [name])
    }

    // MARK: - Media

    /// Reads Anki's root-level `media` manifest (`"0": "image.png"`, etc.).
    private func readMediaMap(in directory: URL) -> [String: String] {
        let mediaURL = directory.appendingPathComponent("media")
        guard let data = try? Data(contentsOf: mediaURL), !data.isEmpty else { return [:] }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Ignoring invalid Anki media manifest")
            return [:]
        }

        var mediaMap: [String: String] = [:]
        for (entryName, fileNameValue) in raw {
            guard let fileName = fileNameValue as? String, !fileName.isEmpty else { continue }
            mediaMap[entryName] = fileName
        }
        return mediaMap
    }

    /// Copies extracted media to durable Echo-owned storage and returns
    /// `originalFilename -> durablePath`, matching `ApkgExportService`'s
    /// existing `mediaJSON` payload shape.
    private func importMediaFiles(
        from extractedDirectory: URL,
        mediaMap: [String: String],
        referencedFileNames: Set<String>
    ) -> [String: String] {
        guard !mediaMap.isEmpty, !referencedFileNames.isEmpty else { return [:] }

        let destinationRoot = URL.applicationSupportDirectory
            .appending(path: "AnkiMedia", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true
            )
        } catch {
            logger.warning("Could not create Anki media directory: \(error.localizedDescription)")
            return [:]
        }

        var imported: [String: String] = [:]
        var usedDestinationNames = Set<String>()
        for (entryName, originalFileName) in mediaMap {
            guard referencedFileNames.contains(originalFileName) else { continue }
            guard let source = try? Self.safeDestination(for: entryName, within: extractedDirectory),
                  FileManager.default.fileExists(atPath: source.path) else {
                continue
            }

            let destinationName = uniqueMediaFileName(
                for: originalFileName,
                entryName: entryName,
                usedNames: &usedDestinationNames
            )
            let destination = destinationRoot.appending(path: destinationName)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                imported[originalFileName] = destination.path
            } catch {
                logger.warning(
                    "Could not import Anki media '\(originalFileName)': \(error.localizedDescription)"
                )
            }
        }

        if imported.isEmpty {
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        return imported
    }

    private func mediaJSON(for note: AnkiNote, importedMedia: [String: String]) -> String? {
        guard !importedMedia.isEmpty else { return nil }
        let references = mediaReferences(in: note.flds)
        let media = importedMedia.filter { fileName, _ in references.contains(fileName) }
        guard !media.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: media, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func mediaReferences(in fields: String) -> Set<String> {
        var references = Set<String>()
        collectSoundReferences(in: fields, into: &references)
        collectImageSourceReferences(in: fields, into: &references)
        return references
    }

    private func collectSoundReferences(in fields: String, into references: inout Set<String>) {
        var searchRange = fields.startIndex..<fields.endIndex
        while let tagRange = fields.range(of: "[sound:", range: searchRange) {
            let valueStart = tagRange.upperBound
            guard let valueEnd = fields[valueStart...].firstIndex(of: "]") else { break }
            let value = String(fields[valueStart..<valueEnd])
            if !value.isEmpty {
                references.insert(value)
            }
            let nextStart = fields.index(after: valueEnd)
            searchRange = nextStart..<fields.endIndex
        }
    }

    private func collectImageSourceReferences(in fields: String, into references: inout Set<String>) {
        var searchStart = fields.startIndex
        while let srcRange = fields.range(
            of: "src=",
            options: [.caseInsensitive],
            range: searchStart..<fields.endIndex
        ) {
            var valueStart = srcRange.upperBound
            while valueStart < fields.endIndex, fields[valueStart].isWhitespace {
                valueStart = fields.index(after: valueStart)
            }
            guard valueStart < fields.endIndex else { break }

            let quote = fields[valueStart]
            if quote == "\"" || quote == "'" {
                let quotedValueStart = fields.index(after: valueStart)
                guard let valueEnd = fields[quotedValueStart...].firstIndex(of: quote) else {
                    break
                }
                let value = String(fields[quotedValueStart..<valueEnd])
                if !value.isEmpty {
                    references.insert(value)
                }
                searchStart = fields.index(after: valueEnd)
            } else {
                var valueEnd = valueStart
                while valueEnd < fields.endIndex,
                      !fields[valueEnd].isWhitespace,
                      fields[valueEnd] != ">" {
                    valueEnd = fields.index(after: valueEnd)
                }
                let value = String(fields[valueStart..<valueEnd])
                if !value.isEmpty {
                    references.insert(value)
                }
                searchStart = valueEnd
            }
        }
    }

    private func uniqueMediaFileName(
        for originalFileName: String,
        entryName: String,
        usedNames: inout Set<String>
    ) -> String {
        let readableName = URL(fileURLWithPath: originalFileName).lastPathComponent
        let sanitized = sanitizeMediaFileName(readableName)
        let fallbackName = "media-\(sanitizeMediaFileName(entryName))"
        let baseName = sanitized.isEmpty ? fallbackName : sanitized
        var candidate = baseName
        var suffix = 2
        while usedNames.contains(candidate) {
            let stem = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        usedNames.insert(candidate)
        return candidate
    }

    private func sanitizeMediaFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*:|\"<>")
        let sanitized = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return sanitized.isEmpty ? "media" : sanitized
    }

    // MARK: - JSON Parsing

    /// Extracts the first deck name from Anki's `decks` JSON blob.
    /// The format is `{"12345": {"name": "My Deck", ...}, ...}`.
    private func parseFirstDeckName(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Anki stores the default deck with id 1.
        if let defaultDeck = dict["1"] as? [String: Any],
            let name = defaultDeck["name"] as? String
        {
            return name
        }

        // Fall back to the first deck in the dictionary.
        for (_, value) in dict {
            if let deck = value as? [String: Any],
                let name = deck["name"] as? String
            {
                return name
            }
        }

        return nil
    }
}
