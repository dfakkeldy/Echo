// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Parses, validates, and inserts flashcard decks from JSON import files.
struct DeckImportService {

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
    /// database write (`PortableDeckPreflight.prepare`), then revalidates
    /// that same snapshot again immediately before mutating
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

        // Revalidate the selected book's canonical blocks immediately before
        // any write, closing the window between preflight (above) and this
        // transaction where another import, re-alignment, or edit could have
        // changed the book underneath this one. Atomic replacement of the
        // deck/card/timeline rows is added on top of this same transaction
        // boundary in a follow-up change; this change's scope stops at
        // preflight plus the write-time revalidation guarantee.
        try writer.write { database in
            try verifySourceSnapshot(plan, in: database)
        }

        // Preflight only: no rows are written yet, so no cards are imported or
        // anchored. Persisting the write plan must set these to the rows it
        // actually inserted rather than to `plan.cards.count`.
        return ImportDeckResult(
            importedCount: 0,
            anchoredCount: 0,
            warnings: []
        )
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
