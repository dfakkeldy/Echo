// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import OSLog

/// Repairs audiobook rows stranded by an app-container relocation.
///
/// Audiobook identity is the book folder's absolute `file://` URL string
/// (`AudiobookRecord.id`), and derived identifiers embed that string:
/// `epub_block.id` ("epub-<folderURL>-s0-b0"), `track.id`/`track.file_path`
/// (file URLs inside the folder), and EPUB image asset paths. iOS moves the
/// app's data container to a new UUID path on updates and reinstalls, which
/// strands every row keyed under the old path: Audiobookshelf imports lose
/// their downloaded/usable status, re-opening a folder creates a duplicate
/// placeholder row titled by the raw folder name, and study data silently
/// detaches from the book it belongs to.
///
/// This pass runs when a disk-backed database opens. For each audiobook row
/// whose id no longer resolves on disk but whose container-relative suffix
/// exists under a current container root, it re-keys the row and every
/// dependent table to the current absolute URL — absorbing any placeholder
/// row that was created at the new path in the meantime, so user data from
/// both generations survives on one row.
///
/// `article_capture.package_path` is deliberately out of scope: captures are
/// not audiobook-scoped and the Article Workshop resolves its directories
/// from `FileLocations` at use time.
nonisolated enum ContainerPathRepair {
    private static let logger = Logger(category: "ContainerPathRepair")

    /// One rebasing rule: `marker` is a path fragment (percent-encoded, as it
    /// appears inside a stored `file://` id) that separates the disposable
    /// container prefix from the durable book-relative suffix; `root` is the
    /// current directory that suffix lives under.
    struct Anchor: Sendable {
        let marker: String
        let root: URL

        /// The current root as an absolute URL string ("file:///…/"), the
        /// prefix that replaces everything up to and including `marker`.
        var rootAbsoluteString: String { root.absoluteString }

        /// The current container root in filesystem-path form (trailing
        /// slash), used to rewrite stored absolute *paths* (not URLs) such as
        /// `epub_block.image_path`. nil when the root doesn't end with the
        /// marker (synthetic test roots).
        var containerRootPath: String? {
            let abs = root.absoluteString
            guard abs.hasSuffix(marker) else { return nil }
            let prefix = String(abs.dropLast(marker.count))
            guard let url = URL(string: prefix + "/") else { return nil }
            return url.path.hasSuffix("/") ? url.path : url.path + "/"
        }
    }

    /// The anchors for this process's current containers. The app-group
    /// `File Provider Storage` root covers in-place opens recorded under the
    /// group container (device databases show track paths there); it is
    /// absent in processes without the entitlement (echo-cli).
    static func defaultAnchors() -> [Anchor] {
        var anchors: [Anchor] = [
            Anchor(
                marker: "/Library/Application%20Support/",
                root: FileLocations.applicationSupportDirectory),
            Anchor(marker: "/Documents/", root: FileLocations.documentsDirectory),
            Anchor(marker: "/Library/Caches/", root: FileLocations.cachesDirectory),
        ]
        if let group = try? FileLocations.appGroupContainer() {
            anchors.append(
                Anchor(
                    marker: "/File%20Provider%20Storage/",
                    root: group.appending(
                        path: "File Provider Storage", directoryHint: .isDirectory)))
        }
        return anchors
    }

    /// Entry point for database open: never throws — a failed repair must not
    /// take the database down with it. Returns the number of re-keyed rows.
    @discardableResult
    static func runIfNeeded(writer: DatabaseWriter) -> Int {
        do {
            let repaired = try repairStrandedBooks(
                writer: writer,
                anchors: defaultAnchors(),
                coversDirectory: FileLocations.libraryCoversDirectory)
            if repaired > 0 {
                logger.notice("Re-keyed \(repaired, privacy: .public) container-stranded book(s).")
            }
            return repaired
        } catch {
            logger.error("Container path repair failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Rebases a stored audiobook id onto the current container. Returns nil
    /// when no anchor marker occurs in the id or the id is already current.
    static func rebasedID(_ id: String, anchors: [Anchor]) -> String? {
        for anchor in anchors {
            // First occurrence: the container prefix precedes the marker, and
            // a user folder that happens to share the marker's name can only
            // appear later in the path.
            guard let range = id.range(of: anchor.marker) else { continue }
            let candidate = anchor.rootAbsoluteString + String(id[range.upperBound...])
            guard candidate != id else { return nil }
            return candidate
        }
        return nil
    }

    /// Tables carrying an `audiobook_id` column that moves with the book.
    /// (`playback_state` and `study_export_state` are *keyed by* the book id
    /// and handled separately, with a survivor rule for merge collisions.)
    private static let childTables = [
        "track", "chapter", "epub_block", "epub_toc_entry",
        "transcription_segment", "standalone_transcript", "word_timing",
        "alignment_anchor", "playback_event", "note", "bookmark", "flashcard",
        "study_plan", "marked_passage", "voice_memo", "planned_session",
        "timeline_item", "narration_quality_issue", "pdf_block_page",
        "batch_queue", "real_time_event", "anthology_build",
    ]

    /// Content tables where the stranded row's rows are authoritative in a
    /// merge: when the old row has content there, the placeholder's copy is
    /// dropped before the move. User-data tables are never dropped — both
    /// generations' rows survive side by side.
    private static let contentTables = [
        "track", "chapter", "epub_block", "epub_toc_entry",
        "transcription_segment", "standalone_transcript", "word_timing",
        "alignment_anchor", "timeline_item", "narration_quality_issue",
        "pdf_block_page",
    ]

    /// Columns whose TEXT values embed the audiobook's folder URL (block ids,
    /// track ids/paths) and are rewritten with a scoped string REPLACE. The
    /// `word_timing` UPDATE touches every timing row of the repaired book
    /// (~10⁵ rows for a word-aligned book) but is a single SQLite pass; the
    /// repair only ever runs on the first launch after a container move.
    private static let urlEmbeddingColumns: [(table: String, columns: [String])] = [
        ("epub_block", ["id"]),
        ("epub_toc_entry", ["id", "parent_id", "block_id"]),
        ("word_timing", ["epub_block_id"]),
        ("alignment_anchor", ["id", "epub_block_id"]),
        ("note", ["epub_block_id"]),
        ("voice_memo", ["epub_block_id"]),
        ("timeline_item", ["id", "epub_block_id", "source_rowid"]),
        ("flashcard", ["source_block_id"]),
        ("narration_quality_issue", ["source_block_id"]),
        ("pdf_block_page", ["epub_block_id"]),
        ("track", ["id", "file_path"]),
        ("bookmark", ["track_id"]),
        ("playback_event", ["track_id"]),
        ("real_time_event", ["source_item_id"]),
    ]

    /// Columns storing absolute filesystem *paths* (decoded, not URLs) that
    /// point into the old container and are rewritten container-root-to-root.
    private static let pathEmbeddingColumns: [(table: String, columns: [String])] = [
        ("epub_block", ["image_path"]),
        ("timeline_item", ["image_path"]),
        ("bookmark", ["image_path", "voice_memo_path"]),
        ("note", ["voice_memo_path"]),
        ("voice_memo", ["file_path"]),
        ("anthology_build", ["epub_path"]),
    ]

    /// Metadata the stranded (authoritative) row carries onto the surviving
    /// row in a merge. Availability, edition grouping, and last-seen stay as
    /// the surviving row's own state.
    private static let mergedMetadataColumns = [
        "title", "author", "narrator", "duration", "file_count", "added_at",
        "source_type", "server_id", "remote_item_id", "topics_json",
        "cover_art_path", "text_origin", "author_sort", "source_root_id",
        "index_state",
    ]

    /// Scans for stranded rows and re-keys them, one transaction per book so
    /// a single unrepairable row cannot abort — or permanently disable — the
    /// repair of every other book.
    @discardableResult
    static func repairStrandedBooks(
        writer: DatabaseWriter,
        anchors: [Anchor],
        coversDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Int {
        let ids = try writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM audiobook ORDER BY added_at")
        }

        // Oldest-first so that when several stranded generations of the same
        // book rebase onto one current folder, each successive merge overwrites
        // metadata and the newest generation's metadata wins.
        var repairs: [(old: String, new: String, anchor: Anchor)] = []
        for id in ids {
            guard let url = URL(string: id), url.isFileURL else { continue }
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            guard
                let anchor = anchors.first(where: { id.range(of: $0.marker) != nil }),
                let markerRange = id.range(of: anchor.marker),
                // Only container-managed prefixes relocate. This keeps the
                // repair from rebasing a foreign or unmounted-volume book that
                // merely contains "/Documents/" (echo-cli against an arbitrary
                // database, external drives) onto the operator's home folders.
                id[..<markerRange.lowerBound].contains("/Containers/"),
                let newID = rebasedID(id, anchors: anchors),
                newID != id,
                let newURL = URL(string: newID), newURL.isFileURL,
                fileManager.fileExists(atPath: newURL.path)
            else { continue }
            repairs.append((old: id, new: newID, anchor: anchor))
        }
        guard !repairs.isEmpty else { return 0 }

        var repaired = 0
        for repair in repairs {
            do {
                try writer.write { db in
                    // Children reference audiobook.id and epub_block.id with
                    // immediate foreign keys; deferring lets parent and child
                    // keys move within one transaction in any order.
                    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                    // Another process sharing the pool may have repaired this
                    // row between our scan and this write.
                    let stillExists =
                        try Bool.fetchOne(
                            db, sql: "SELECT EXISTS(SELECT 1 FROM audiobook WHERE id = ?)",
                            arguments: [repair.old]) ?? false
                    guard stillExists else { return }
                    try rekey(
                        db,
                        old: repair.old,
                        new: repair.new,
                        anchor: repair.anchor,
                        coversDirectory: coversDirectory,
                        fileManager: fileManager)
                    repaired += 1
                }
            } catch {
                logger.error(
                    "Skipping unrepairable stranded book: \(error.localizedDescription)")
            }
        }
        return repaired
    }

    private static func rekey(
        _ db: Database,
        old: String,
        new: String,
        anchor: Anchor,
        coversDirectory: URL?,
        fileManager: FileManager
    ) throws {
        let mergeTargetExists =
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM audiobook WHERE id = ?)",
                arguments: [new]) ?? false

        if mergeTargetExists {
            // The stranded row's content is authoritative; drop the
            // placeholder's copy only where the stranded row has one.
            for table in contentTables {
                let oldHasRows =
                    try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE audiobook_id = ?)",
                        arguments: [old]) ?? false
                guard oldHasRows else { continue }
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE audiobook_id = ?", arguments: [new])
            }
            try mergeKeyedRow(
                db, table: "playback_state", key: "audiobook_id", old: old, new: new,
                preferNewWhen: "last_played_at")
            try mergeKeyedRow(
                db, table: "study_export_state", key: "book_id", old: old, new: new,
                preferNewWhen: "last_exported_at")
            for table in childTables {
                try db.execute(
                    sql: "UPDATE \(table) SET audiobook_id = ? WHERE audiobook_id = ?",
                    arguments: [new, old])
            }
            let assignments =
                mergedMetadataColumns
                .map { "\($0) = (SELECT \($0) FROM audiobook WHERE id = :old)" }
                .joined(separator: ", ")
            try db.execute(
                sql: "UPDATE audiobook SET \(assignments), is_available = 1 WHERE id = :new",
                arguments: ["old": old, "new": new])
            try db.execute(sql: "DELETE FROM audiobook WHERE id = ?", arguments: [old])
        } else {
            try db.execute(
                sql: "UPDATE audiobook SET id = ?, is_available = 1 WHERE id = ?",
                arguments: [new, old])
            try db.execute(
                sql: "UPDATE playback_state SET audiobook_id = ? WHERE audiobook_id = ?",
                arguments: [new, old])
            try db.execute(
                sql: "UPDATE study_export_state SET book_id = ? WHERE book_id = ?",
                arguments: [new, old])
            for table in childTables {
                try db.execute(
                    sql: "UPDATE \(table) SET audiobook_id = ? WHERE audiobook_id = ?",
                    arguments: [new, old])
            }
        }

        // Rewrite embedded folder-URL fragments (block ids, track ids/paths)
        // on the surviving book's rows. REPLACE is a no-op on rows that never
        // referenced the old URL, so placeholder-era rows pass through intact.
        for fixup in urlEmbeddingColumns {
            let assignments = fixup.columns
                .map { "\($0) = REPLACE(\($0), :old, :new)" }
                .joined(separator: ", ")
            try db.execute(
                sql: "UPDATE \(fixup.table) SET \(assignments) WHERE audiobook_id = :book",
                arguments: ["old": old, "new": new, "book": new])
        }

        // Study-plan items carry block ids but no audiobook_id of their own;
        // reach them through their plan. They are the plan generator's dedupe
        // key, so leaving them stale would duplicate every item next pass.
        try db.execute(
            sql: """
                UPDATE study_plan_item
                SET source_block_id = REPLACE(source_block_id, :old, :new)
                WHERE plan_id IN (SELECT id FROM study_plan WHERE audiobook_id = :book)
                """,
            arguments: ["old": old, "new": new, "book": new])

        // Flashcard media payloads are JSONEncoder output, which escapes "/"
        // as "\/" — rewrite both the escaped URL form and (below) the escaped
        // path form, or image study cards keep dead absolute paths.
        try db.execute(
            sql: """
                UPDATE flashcard
                SET media_json = REPLACE(REPLACE(media_json, :old, :new), :oldEsc, :newEsc)
                WHERE audiobook_id = :book
                """,
            arguments: [
                "old": old, "new": new,
                "oldEsc": jsonSlashEscaped(old), "newEsc": jsonSlashEscaped(new),
                "book": new,
            ])

        // Rewrite absolute filesystem paths (image assets, memo files) from
        // the old container root to the current one, when both are derivable.
        if let oldRootPath = containerRootPath(fromID: old, marker: anchor.marker),
            let newRootPath = anchor.containerRootPath
        {
            for fixup in pathEmbeddingColumns {
                let assignments = fixup.columns
                    .map { "\($0) = REPLACE(\($0), :old, :new)" }
                    .joined(separator: ", ")
                try db.execute(
                    sql: "UPDATE \(fixup.table) SET \(assignments) WHERE audiobook_id = :book",
                    arguments: ["old": oldRootPath, "new": newRootPath, "book": new])
            }
            try db.execute(
                sql: """
                    UPDATE flashcard
                    SET media_json = REPLACE(REPLACE(media_json, :old, :new), :oldEsc, :newEsc)
                    WHERE audiobook_id = :book
                    """,
                arguments: [
                    "old": oldRootPath, "new": newRootPath,
                    "oldEsc": jsonSlashEscaped(oldRootPath),
                    "newEsc": jsonSlashEscaped(newRootPath),
                    "book": new,
                ])
        }

        // A merge that replaced the placeholder's track rows can leave its
        // bookmarks/events referencing deleted track ids (the generations'
        // file layouts need not match). Null the reference — the rows stay
        // valid through their timestamps — so the deferred FK check passes.
        for table in ["bookmark", "playback_event"] {
            try db.execute(
                sql: """
                    UPDATE \(table) SET track_id = NULL
                    WHERE audiobook_id = :book AND track_id IS NOT NULL
                        AND track_id NOT IN (SELECT id FROM track WHERE audiobook_id = :book)
                    """,
                arguments: ["book": new])
        }

        // A reinstall wipes Caches, so the stored cover filename may point at
        // nothing; clearing it lets the next open re-extract the cover.
        if let coversDirectory,
            let coverName = try String.fetchOne(
                db, sql: "SELECT cover_art_path FROM audiobook WHERE id = ?", arguments: [new]),
            !fileManager.fileExists(atPath: coversDirectory.appending(path: coverName).path)
        {
            try db.execute(
                sql: "UPDATE audiobook SET cover_art_path = NULL WHERE id = ?", arguments: [new])
        }
    }

    /// Merges a one-row-per-book table keyed by the book id. When both
    /// generations have a row, the one with the later `preferNewWhen`
    /// timestamp survives (NULL sorts oldest).
    private static func mergeKeyedRow(
        _ db: Database,
        table: String,
        key: String,
        old: String,
        new: String,
        preferNewWhen timestampColumn: String
    ) throws {
        let oldExists =
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(key) = ?)",
                arguments: [old]) ?? false
        guard oldExists else { return }
        let newExists =
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(key) = ?)",
                arguments: [new]) ?? false
        if newExists {
            let oldStamp = try String.fetchOne(
                db, sql: "SELECT \(timestampColumn) FROM \(table) WHERE \(key) = ?",
                arguments: [old])
            let newStamp = try String.fetchOne(
                db, sql: "SELECT \(timestampColumn) FROM \(table) WHERE \(key) = ?",
                arguments: [new])
            if (newStamp ?? "") > (oldStamp ?? "") {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE \(key) = ?", arguments: [old])
                return
            }
            try db.execute(sql: "DELETE FROM \(table) WHERE \(key) = ?", arguments: [new])
        }
        try db.execute(
            sql: "UPDATE \(table) SET \(key) = ? WHERE \(key) = ?", arguments: [new, old])
    }

    /// JSONEncoder/JSONSerialization escape "/" as "\/" in string values.
    private static func jsonSlashEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "\\/")
    }

    /// The old container root in filesystem-path form (trailing slash),
    /// derived from the stored id's prefix before `marker`.
    static func containerRootPath(fromID id: String, marker: String) -> String? {
        guard let range = id.range(of: marker) else { return nil }
        let prefix = String(id[..<range.lowerBound])
        guard let url = URL(string: prefix + "/"), url.isFileURL else { return nil }
        return url.path.hasSuffix("/") ? url.path : url.path + "/"
    }
}
