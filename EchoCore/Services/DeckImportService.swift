// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os

/// Parses, validates, and inserts flashcard decks from JSON import files.
struct DeckImportService {

    private static let logger = Logger(subsystem: "Echo", category: "DeckImportService")

    let validTriggerTimings = Set(FlashcardTriggerTiming.allCases.map(\.rawValue))

    /// Imports a deck from a JSON file URL, resolves EPUB source anchors, and
    /// inserts cards with their `sourceBlockID` populated where possible.
    ///
    /// Classifies the document first: legacy (v1) documents continue through
    /// this overload's original warn-and-continue import; portable
    /// (formatVersion 2) documents have no selected book to preflight
    /// against here and fail closed with `selectedBookRequired` rather than
    /// guessing a target audiobook. Use
    /// `importDeckVNext(from:targetAudiobookID:db:)` for portable decks.
    /// - Parameters:
    ///   - url: The JSON file URL to import.
    ///   - db: A GRDB DatabaseWriter for FlashcardDAO.
    /// - Returns: An `ImportDeckResult` with counts and any anchor warnings.
    func importDeckVNext(from url: URL, db writer: DatabaseWriter) throws -> ImportDeckResult {
        let data = try readFile(at: url)
        switch try ValidatedDeckImport.decode(data) {
        case .legacy(let deck):
            return try importLegacyDeckVNext(deck, from: url, db: writer)
        case .portable:
            throw DeckImportError.selectedBookRequired
        }
    }

    /// Imports a portable (formatVersion 2) study deck against an explicitly
    /// selected local audiobook.
    ///
    /// Preflights every card's anchors and the deck's `sourceSignature`
    /// against `targetAudiobookID`'s persisted canonical blocks before any
    /// database write (`PortableDeckPreflight.prepare`), then persists the
    /// resulting write plan atomically (`persistPortable`), which itself
    /// revalidates that same snapshot again immediately before mutating
    /// (`verifySourceSnapshot`), closing the race between preflight and the
    /// write transaction. Legacy documents have no portable contract to
    /// preflight and fail closed with `portableDeckRequired` rather than
    /// silently reinterpreting `targetAudiobookID` under legacy semantics.
    /// Never persists `deck.targetMediaID` (the portable sentinel) as an
    /// audiobook id — only the caller-supplied `targetAudiobookID`.
    /// - Parameters:
    ///   - url: The portable deck JSON file URL to import.
    ///   - targetAudiobookID: The local audiobook id the caller selected to
    ///     receive this deck.
    ///   - db: A GRDB DatabaseWriter.
    /// - Returns: An `ImportDeckResult` with counts.
    func importDeckVNext(
        from url: URL,
        targetAudiobookID: String,
        db writer: DatabaseWriter
    ) throws -> ImportDeckResult {
        let data = try readFile(at: url)
        guard case .portable(let deck) = try ValidatedDeckImport.decode(data) else {
            throw DeckImportError.portableDeckRequired
        }

        let plan = try PortableDeckPreflight.prepare(
            deck: deck,
            targetAudiobookID: targetAudiobookID,
            deckURL: url,
            dbReader: writer
        )

        // Stage and publish every bundled `imageFile` this deck references
        // before touching the database at all. A deck with no `imageFile`
        // cards (only `imageAnchor`/no-image cards) skips the stager
        // entirely — no staging/backup directories are ever created for it.
        // Deduplicated: two cards may legitimately reference the same
        // bundled image, and the stager's collision-safe (content-hashed)
        // filenames mean a duplicate copy would just collide with itself.
        let stager = PortableDeckImageStager()
        let stagedRelativePaths = Set(
            plan.cards.compactMap { card -> String? in
                guard case .stagedFile(_, let relativePath) = card.media else { return nil }
                return relativePath
            })

        var published: PortableDeckImageStager.PublishedSet?
        if !stagedRelativePaths.isEmpty {
            let staged = try stager.stage(
                relativePaths: Array(stagedRelativePaths), beside: url, deckID: plan.deckID)
            do {
                published = try stager.publish(staged)
            } catch {
                // `stage()` already cleaned up after itself if it failed, but
                // a `publish` failure (either move can throw) leaves
                // `staged.stagingRoot` behind on disk — `publish` never
                // touches it on its own failure path. `discard` only removes
                // this transaction's staging/backup directories, so it can't
                // disturb `finalRoot` or a prior import's images. `try?`
                // keeps a cleanup failure from masking the real publish
                // error, which is what the caller needs.
                try? stager.discard(staged)
                throw error
            }
        }

        // Every media path in the database must point at the atomically
        // published final directory, so `imageFile` is never resolved
        // inside the per-card insertion loop: every prepared card's media
        // is converted to its persisted JSON string up front, from the
        // publication that already succeeded above. Both this conversion
        // and the write transaction are covered by the same rollback: an
        // internal mismatch here (should be unreachable — every staged
        // relative path above came from `plan.cards` in the first place)
        // must roll back already-published images exactly like a database
        // failure would, so a declared image is never left half-imported.
        do {
            let mediaJSONByCardIndex = try plan.cards.map { card in
                try mediaJSON(for: card.media, staged: published?.staged)
            }
            try persistPortable(
                plan, mediaJSONByCardIndex: mediaJSONByCardIndex, in: writer, now: Date())
        } catch {
            if let published {
                do {
                    try stager.rollback(published)
                } catch let recoveryError {
                    throw DeckImportError.imageRollbackFailed(
                        primary: error, recovery: recoveryError)
                }
            }
            throw error
        }

        // The database transaction committed: the new rows and the newly
        // published image directory are both valid regardless of what
        // happens next. Only cleaning up a now-superseded backup (from a
        // reimport that replaced an existing image directory) can still
        // fail here; that failure never invalidates the import, so it
        // downgrades to exactly one warning and leaves the uniquely named
        // backup directory for `cleanupOrphanedImageStaging` to sweep up
        // on a future launch.
        var warnings: [ImportDeckWarning] = []
        if let published {
            do {
                try stager.commit(published)
            } catch {
                Self.logger.warning(
                    "Failed to clean up superseded image backup for deck \(plan.deckID, privacy: .private): \(String(describing: error), privacy: .private)"
                )
                warnings.append(.imageBackupCleanupFailed(deckID: plan.deckID))
            }
        }

        // Read every count back from the rows `persistPortable` actually
        // committed, rather than reusing `plan.cards.count`: every card in
        // a write plan is already proven to resolve to a concrete source
        // block by preflight, so a genuinely inserted row is always
        // anchored, but deriving all three counts from the table keeps
        // this correct even if a future change ever makes inserted rows
        // diverge from the plan. `imageCount` follows the identical
        // discipline: it's the number of committed rows whose media_json
        // is non-null, so it reflects exactly what's persisted in the
        // database rather than how many cards this import merely attempted
        // to attach an image to.
        let (importedCount, anchoredCount, imageCount) = try writer.read {
            database -> (Int, Int, Int) in
            let imported =
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM flashcard WHERE deck_id = ?",
                    arguments: [plan.deckID]
                ) ?? 0
            let anchored =
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM flashcard
                        WHERE deck_id = ? AND source_block_id IS NOT NULL
                        """,
                    arguments: [plan.deckID]
                ) ?? 0
            let images =
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM flashcard
                        WHERE deck_id = ? AND media_json IS NOT NULL
                        """,
                    arguments: [plan.deckID]
                ) ?? 0
            return (imported, anchored, images)
        }

        return ImportDeckResult(
            importedCount: importedCount,
            anchoredCount: anchoredCount,
            imageCount: imageCount,
            warnings: warnings
        )
    }

    /// Converts a card's resolved image input into its persisted
    /// `media_json` string. `imageAnchor` (`.sourceImage`) needs no
    /// filesystem work — it's already an in-book figure's stored path.
    /// `imageFile` (`.stagedFile`) must have already been staged and
    /// published by `stager` before this runs; `staged` is that
    /// publication's `StagedSet`, keyed by the same relative paths used to
    /// build it.
    private func mediaJSON(
        for media: PreparedCardMedia?,
        staged: PortableDeckImageStager.StagedSet?
    ) throws -> String? {
        let imagePath: String
        switch media {
        case .none:
            return nil
        case .sourceImage(let path):
            imagePath = path
        case .stagedFile(_, let relativePath):
            guard let staged,
                let resolved = staged.mediaPathByRelativePath[relativePath]
            else {
                throw DeckImportError.stagedImageMissing(relativePath)
            }
            imagePath = resolved
        }
        let data = try JSONEncoder().encode(StudyCardMedia(imagePath: imagePath))
        return String(decoding: data, as: UTF8.self)
    }

    /// Launch-safe, best-effort sweep of `DeckMediaV2` staging/backup
    /// directories abandoned by an interrupted or partially-completed
    /// image import:
    /// - `.staging-<safeDeckID>-<transactionID>` directories older than 24
    ///   hours (an in-progress `stage()` call that never reached `publish`
    ///   or `discard`, e.g. because the app was terminated mid-import).
    /// - `.backup-<safeDeckID>-<transactionID>` directories whose
    ///   corresponding final `<safeDeckID>` directory exists (a `commit()`
    ///   cleanup that failed after a successful reimport — see
    ///   `ImportDeckWarning.imageBackupCleanupFailed`).
    ///
    /// A backup directory is **never** removed when its final directory is
    /// absent: that backup is the only surviving copy of that deck's
    /// images (e.g. `commit()` never ran because the app quit between
    /// `publish()` and `commit()`), so deleting it would be a genuine data
    /// loss rather than cleanup. One directory's deletion failure is
    /// logged and does not stop the sweep of the rest, so a single stuck
    /// directory never blocks unrelated imports.
    func cleanupOrphanedImageStaging(now: Date = Date()) {
        let manager = FileManager.default
        let mediaRoot = URL.applicationSupportDirectory
            .appending(path: "DeckMediaV2", directoryHint: .isDirectory)
        // Dot-prefixed staging/backup directories are exactly what this
        // sweep targets, so hidden files must stay included in the listing.
        guard
            let entries = try? manager.contentsOfDirectory(
                at: mediaRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: []
            )
        else { return }

        let stagingMaxAge: TimeInterval = 24 * 60 * 60
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".staging-") {
                let modified =
                    (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) > stagingMaxAge else { continue }
                removeOrphan(entry, using: manager)
            } else if name.hasPrefix(".backup-") {
                guard
                    let safeDeckID = Self.safeDeckID(
                        fromOrphanDirectoryName: name, prefix: ".backup-")
                else { continue }
                let finalDirectory = mediaRoot.appending(
                    path: safeDeckID, directoryHint: .isDirectory)
                guard manager.fileExists(atPath: finalDirectory.path) else { continue }
                removeOrphan(entry, using: manager)
            }
        }
    }

    private func removeOrphan(_ url: URL, using manager: FileManager) {
        do {
            try manager.removeItem(at: url)
        } catch {
            Self.logger.warning(
                "Failed to remove orphaned deck media directory \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .private)"
            )
        }
    }

    /// Extracts the fixed-length (64 lowercase hex character SHA-256)
    /// `safeDeckID` component from a `.staging-<safeDeckID>-<uuid>` or
    /// `.backup-<safeDeckID>-<uuid>` directory name. `safeDeckID` is
    /// always exactly 64 hex characters (see `PortableDeckImageStager`),
    /// so it can be sliced out positionally rather than split on `-`,
    /// which would otherwise be ambiguous with the hyphens inside the
    /// trailing UUID transaction id.
    private static func safeDeckID(fromOrphanDirectoryName name: String, prefix: String)
        -> String?
    {
        guard name.hasPrefix(prefix) else { return nil }
        let remainder = name.dropFirst(prefix.count)
        guard remainder.count > 64 else { return nil }
        let candidate = remainder.prefix(64)
        let separatorIndex = remainder.index(remainder.startIndex, offsetBy: 64)
        guard remainder[separatorIndex] == "-",
            candidate.allSatisfy(\.isHexDigit)
        else { return nil }
        return String(candidate)
    }

    /// Replaces the persisted state of a portable deck in one write
    /// transaction: revalidates the source snapshot, upserts the `deck` row
    /// keyed by its stable `deckID` (never `deck.name`), deletes that deck's
    /// prior cards and their timeline rows, and inserts the replacement set.
    /// A collision with a same-id deck this service didn't create, a stale
    /// source snapshot, or any mid-transaction failure throws and rolls the
    /// whole transaction back, leaving the prior deck/cards/timeline
    /// byte-identical — GRDB commits only if this closure returns normally.
    private func persistPortable(
        _ plan: PortableDeckWritePlan,
        mediaJSONByCardIndex: [String?],
        in writer: DatabaseWriter,
        now: Date
    ) throws {
        guard mediaJSONByCardIndex.count == plan.cards.count else {
            throw DeckImportError.internalCardPreparationMismatch
        }
        try writer.write { database in
            try verifySourceSnapshot(plan, in: database)
            let existingSource = try String.fetchOne(
                database,
                sql: "SELECT source FROM deck WHERE id = ?",
                arguments: [plan.deckID]
            )
            if let existingSource, existingSource != "json_import_v2" {
                throw DeckImportError.deckIDCollision(plan.deckID)
            }
            let timestamp = now.ISO8601Format()
            try database.execute(
                sql: """
                    INSERT INTO deck (id, name, source, created_at, modified_at)
                    VALUES (?, ?, 'json_import_v2', ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        source = excluded.source,
                        modified_at = excluded.modified_at
                    """,
                arguments: [plan.deckID, plan.deckName, timestamp, timestamp]
            )
            try database.execute(
                sql: """
                    DELETE FROM timeline_item
                    WHERE source_table = 'flashcard'
                      AND source_rowid IN (
                        SELECT id FROM flashcard WHERE deck_id = ?
                      )
                    """,
                arguments: [plan.deckID]
            )
            try database.execute(
                sql: "DELETE FROM flashcard WHERE deck_id = ?",
                arguments: [plan.deckID]
            )
            for (index, prepared) in plan.cards.enumerated() {
                let card = Flashcard(
                    id: UUID().uuidString,
                    audiobookID: plan.targetAudiobookID,
                    frontText: prepared.imported.frontText,
                    backText: prepared.imported.backText,
                    mediaTimestamp: 0,
                    endTimestamp: nil,
                    triggerTiming: .manualOnly,
                    nextReviewDate: timestamp,
                    intervalDays: 0,
                    easeFactor: 2.5,
                    repetitions: 0,
                    lastReviewedAt: nil,
                    lastGrade: nil,
                    isEnabled: true,
                    deckID: plan.deckID,
                    tags: nil,
                    mediaJSON: mediaJSONByCardIndex[index],
                    sourceBlockID: prepared.sourceBlockID,
                    playlistPosition: nil,
                    createdAt: timestamp,
                    modifiedAt: timestamp
                )
                try FlashcardDAO.insert(card, in: database)
            }
        }
    }

    /// Revalidates that the selected book's persisted canonical blocks still
    /// match `plan.sourceSignature` immediately before mutating. Must run
    /// before any delete/update/insert in the final write transaction.
    private func verifySourceSnapshot(
        _ plan: PortableDeckWritePlan,
        in database: Database
    ) throws {
        let records = try EPubBlockRecord
            .filter(Column("audiobook_id") == plan.targetAudiobookID)
            .order(Column("sequence_index"))
            .fetchAll(database)
        guard EchoSourceSignature.make(records: records) == plan.sourceSignature else {
            throw DeckImportError.sourceChangedDuringImport
        }
    }

    private func readFile(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw DeckImportError.fileReadFailed(error)
        }
    }

    /// The pre-existing legacy (v1) import implementation: resolves EPUB
    /// source anchors with warn-and-continue semantics, and creates a
    /// placeholder audiobook row for an unknown `targetMediaID`. Unchanged
    /// in behavior from before portable-deck classification was added —
    /// `deck` here is already-decoded, not re-parsed.
    private func importLegacyDeckVNext(
        _ deck: FlashcardDeckImport, from url: URL, db writer: DatabaseWriter
    ) throws -> ImportDeckResult {
        guard !deck.cards.isEmpty else {
            throw DeckImportError.emptyDeck
        }

        var triggerTimings: [FlashcardTriggerTiming] = []
        triggerTimings.reserveCapacity(deck.cards.count)
        for (index, card) in deck.cards.enumerated() {
            guard !card.frontText.isEmpty, !card.backText.isEmpty else {
                throw DeckImportError.emptyCardText(cardIndex: index)
            }
            guard validTriggerTimings.contains(card.triggerTiming),
                let triggerTiming = FlashcardTriggerTiming(rawValue: card.triggerTiming)
            else {
                throw DeckImportError.invalidTriggerTiming(
                    card.triggerTiming, cardIndex: index)
            }
            triggerTimings.append(triggerTiming)

            if !(card.imageAnchor?.isEmpty ?? true) && !(card.imageFile?.isEmpty ?? true) {
                throw DeckImportError.conflictingImageFields(cardIndex: index)
            }
        }

        var warnings: [ImportDeckWarning] = []
        var anchoredCount = 0
        var resolvedSourceBlockIDs = [String?](repeating: nil, count: deck.cards.count)

        let resolver = EPUBSourceAnchorResolver(dbReader: writer)
        let targetHasBlocks = try resolver.hasBlocks(for: deck.targetMediaID)
        if !targetHasBlocks {
            warnings.append(.targetAudiobookHasNoEPUBBlocks(targetMediaID: deck.targetMediaID))
        }

        if targetHasBlocks {
            for (index, importedCard) in deck.cards.enumerated() {
                let cardReference = "json-card-\(index)"
                switch try resolver.resolve(
                    sourceAnchor: importedCard.sourceAnchor,
                    targetMediaID: deck.targetMediaID,
                    cardReference: cardReference
                ) {
                case .none:
                    resolvedSourceBlockIDs[index] = nil
                case .resolved(let blockID):
                    resolvedSourceBlockIDs[index] = blockID
                    anchoredCount += 1
                case .unresolved(let warning):
                    resolvedSourceBlockIDs[index] = nil
                    warnings.append(warning)
                }
            }
        }

        for (index, card) in deck.cards.enumerated() {
            guard hasValidTimeRange(card) || resolvedSourceBlockIDs[index] != nil else {
                throw DeckImportError.invalidTimeRange(cardIndex: index)
            }
        }

        let deckID: String
        if let existingID = try findDeck(named: deck.deckName, db: writer) {
            deckID = existingID
        } else {
            deckID = UUID().uuidString
            try writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO deck (id, name, source, created_at, modified_at)
                        VALUES (?, ?, 'json_import', ?, ?)
                        """,
                    arguments: [
                        deckID, deck.deckName, Date().ISO8601Format(), Date().ISO8601Format(),
                    ]
                )
            }
        }

        // Ensure the target audiobook row exists: flashcard.audiobook_id is a
        // NOT NULL FK, and an imported deck may target a book not yet on this
        // device. INSERT OR IGNORE is a no-op when the book already exists, so
        // it never clobbers a real title. (Mirrors ApkgImportService.)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO audiobook (id, title, author, duration, added_at)
                    VALUES (?, ?, 'json_import', 0, ?)
                    """,
                arguments: [deck.targetMediaID, deck.deckName, Date().ISO8601Format()]
            )
        }

        // Re-import replaces existing cards for this deck so corrected front/back
        // text, timings, and source anchors are applied instead of skipped.
        try replaceExistingCards(in: writer, deckID: deckID)

        let bundleDir = url.deletingLastPathComponent()
        let dao = FlashcardDAO(db: writer)
        for (index, card) in deck.cards.enumerated() {
            let flashcard = Flashcard(
                id: UUID().uuidString,
                audiobookID: deck.targetMediaID,
                frontText: card.frontText,
                backText: card.backText,
                mediaTimestamp: startTimestamp(for: card),
                endTimestamp: endTimestamp(for: card),
                triggerTiming: triggerTimings[index],
                nextReviewDate: Date().ISO8601Format(),
                intervalDays: 0,
                easeFactor: 2.5,
                repetitions: 0,
                lastReviewedAt: nil,
                lastGrade: nil,
                isEnabled: true,
                deckID: deckID,
                tags: nil,
                mediaJSON: resolveCardImageJSON(
                    card: card, targetMediaID: deck.targetMediaID,
                    bundleDir: bundleDir, deckID: deckID, writer: writer),
                sourceBlockID: resolvedSourceBlockIDs[index],
                playlistPosition: nil,
                createdAt: Date().ISO8601Format(),
                modifiedAt: Date().ISO8601Format()
            )
            try dao.insert(flashcard)
        }

        return ImportDeckResult(
            importedCount: deck.cards.count,
            anchoredCount: anchoredCount,
            warnings: warnings
        )
    }

    /// Imports a deck from a JSON file URL, validates every card, and inserts
    /// into the database via FlashcardDAO.
    /// - Parameters:
    ///   - url: The JSON file URL to import.
    ///   - db: A GRDB DatabaseWriter for FlashcardDAO.
    /// - Returns: The number of cards successfully imported.
    func importDeck(from url: URL, db: DatabaseWriter) throws -> Int {
        try importDeckVNext(from: url, db: db).importedCount
    }

    private func findDeck(named name: String, db: DatabaseWriter) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM deck WHERE name = ?", arguments: [name])
        }
    }

    private func replaceExistingCards(in writer: DatabaseWriter, deckID: String) throws {
        let now = Date().ISO8601Format()
        try writer.write { db in
            try db.execute(
                sql: """
                    DELETE FROM timeline_item
                    WHERE source_table = 'flashcard'
                      AND source_rowid IN (
                          SELECT id FROM flashcard WHERE deck_id = ?
                      )
                    """,
                arguments: [deckID]
            )
            try db.execute(
                sql: "DELETE FROM flashcard WHERE deck_id = ?",
                arguments: [deckID]
            )
            try db.execute(
                sql: "UPDATE deck SET modified_at = ? WHERE id = ?",
                arguments: [now, deckID]
            )
        }
    }

    private func hasValidTimeRange(_ card: FlashcardDeckImport.ImportedCard) -> Bool {
        guard let startTime = card.startTime, let endTime = card.endTime else {
            return false
        }
        return startTime >= 0 && endTime > startTime
    }

    private func startTimestamp(for card: FlashcardDeckImport.ImportedCard) -> Double {
        guard hasValidTimeRange(card), let startTime = card.startTime else {
            return 0
        }
        return startTime
    }

    private func endTimestamp(for card: FlashcardDeckImport.ImportedCard) -> Double? {
        guard hasValidTimeRange(card) else {
            return nil
        }
        return card.endTime
    }

    /// Produces the `media_json` value for a card's image, or nil if it has none.
    /// `imageAnchor` -> the in-book figure block's `image_path`; `imageFile` ->
    /// a bundled PNG copied into per-deck storage. Both-set is already rejected by
    /// the early validation loop, so this only resolves a single field.
    ///
    /// Non-throwing by design: this runs inside the per-card INSERT loop, which
    /// executes *after* `replaceExistingCards` has already deleted the deck's old
    /// cards. Throwing mid-loop would leave the deck half-imported with no rollback,
    /// so any I/O or DB failure resolving an image degrades the card to text-only
    /// (mediaJSON nil) instead of aborting the whole import.
    private func resolveCardImageJSON(
        card: FlashcardDeckImport.ImportedCard,
        targetMediaID: String,
        bundleDir: URL,
        deckID: String,
        writer: DatabaseWriter
    ) -> String? {
        let imagePath: String?
        if let anchor = card.imageAnchor, !anchor.isEmpty {
            imagePath = figureImagePath(
                anchor: anchor, targetMediaID: targetMediaID, writer: writer)
        } else if let rel = card.imageFile, !rel.isEmpty {
            imagePath = copyBundledImage(relativePath: rel, bundleDir: bundleDir, deckID: deckID)
        } else {
            imagePath = nil
        }
        guard let imagePath else { return nil }  // missing/unresolved -> card imports text-only
        guard let data = try? JSONEncoder().encode(StudyCardMedia(imagePath: imagePath)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func figureImagePath(
        anchor: String, targetMediaID: String, writer: DatabaseWriter
    ) -> String? {
        let resolution =
            (try? EPUBSourceAnchorResolver(dbReader: writer).resolve(
                sourceAnchor: anchor, targetMediaID: targetMediaID, cardReference: "image-anchor"))
            ?? .none
        guard case .resolved(let blockID) = resolution else { return nil }
        let imagePath = try? writer.read { db in
            try EPubBlockRecord.filter(Column("id") == blockID).fetchOne(db)?.imagePath
        }
        return imagePath ?? nil
    }

    /// Copies a bundled deck image into per-deck storage and returns its absolute
    /// path, or nil on any failure. `imageFile` comes from untrusted, shareable
    /// deck JSON, so absolute paths and any value escaping the bundle dir (e.g.
    /// `../evil.png`) are rejected before the copy. Non-throwing: a failed copy
    /// degrades the card to text-only rather than aborting the import.
    private func copyBundledImage(
        relativePath: String, bundleDir: URL, deckID: String
    ) -> String? {
        guard !relativePath.hasPrefix("/") else { return nil }  // no absolute paths
        let source = bundleDir.appendingPathComponent(relativePath).standardizedFileURL
        let root = bundleDir.standardizedFileURL
        // Stay inside the bundle dir: reject path-traversal escapes.
        guard source.path == root.path || source.path.hasPrefix(root.path + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destRoot = URL.applicationSupportDirectory
            .appending(path: "DeckMedia", directoryHint: .isDirectory)
            .appending(path: deckID, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
            let dest = destRoot.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            return dest.path
        } catch {
            return nil  // non-fatal
        }
    }
}
