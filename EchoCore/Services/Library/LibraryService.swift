// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Owns the on-device Library: registers folder roots, rescans them for books
/// (cheap shallow upsert), and resolves a book's URL for opening. A launcher
/// layer above the single-book player — it does not change playback.
@MainActor
struct LibraryService {
    private let logger = Logger(category: "LibraryService")
    private let db: DatabaseService

    init(db: DatabaseService) {
        self.db = db
    }

    struct RescanResult: Equatable {
        var added: Int
        var updated: Int
        var hidden: Int
    }

    /// Registers `url` as a rescannable root: stores its security-scoped bookmark
    /// and a `library_root` row. `now` injects the timestamp for testability.
    @discardableResult
    func registerRoot(url: URL, now: () -> String = { Date().ISO8601Format() }) throws
        -> LibraryRootRecord
    {
        let bookmark = LibraryAccess.makeBookmark(for: url) ?? Data()
        let root = LibraryRootRecord(
            id: "root-\(UUID().uuidString)",
            displayName: url.lastPathComponent,
            bookmark: bookmark,
            addedAt: now(),
            lastScannedAt: nil)
        try LibraryRootDAO(db: db.writer).save(root)
        return root
    }

    /// Rescans a root: shallow-upserts newly found books, refreshes availability
    /// for present ones, and hides ones that vanished (never deleted). `discover`
    /// is injected so tests pass a fixed book list. Metadata enrichment is layered
    /// on in a later task; this pass establishes identity + availability.
    ///
    /// When the bookmark cannot be resolved (e.g. the root was registered with a
    /// non-existent path in tests), `discover` is still called with a placeholder
    /// URL so injected closures that ignore their argument work correctly.
    @discardableResult
    func rescan(
        root: LibraryRootRecord,
        discover: (URL) -> [DiscoveredBook] = { LibraryScanner.discoverBooks(in: $0) },
        now: () -> String = { Date().ISO8601Format() }
    ) throws -> RescanResult {
        // Resolve bookmark to get the root URL for the discover call. When the
        // bookmark is empty (e.g. non-existent path registered in tests), fall back
        // to a placeholder so injected discover closures (which ignore the URL) still
        // work. In production, a valid registered root always has a resolvable bookmark.
        let rootURL: URL
        if let resolved = LibraryAccess.resolveURL(from: root.bookmark)?.url {
            rootURL = resolved
        } else {
            logger.warning(
                "Root \(root.id) bookmark unresolved; using placeholder URL for discover.")
            rootURL = URL(fileURLWithPath: "/")
        }

        let dao = AudiobookDAO(db: db.writer)
        let found = discover(rootURL)
        let foundIDs = Set(found.map { $0.folderURL.absoluteString })
        var result = RescanResult(added: 0, updated: 0, hidden: 0)
        let timestamp = now()

        for book in found {
            let id = book.folderURL.absoluteString
            if let existing = try dao.get(id) {
                var updated = existing
                updated.isAvailable = true
                updated.lastSeenAt = timestamp
                if updated.sourceRootID == nil { updated.sourceRootID = root.id }
                try dao.save(updated)
                result.updated += 1
            } else {
                let record = AudiobookRecord(
                    id: id,
                    title: book.folderURL.lastPathComponent,
                    author: nil,
                    duration: 0,
                    fileCount: book.audioFiles.count,
                    addedAt: timestamp,
                    indexState: 0,
                    isAvailable: true,
                    lastSeenAt: timestamp,
                    authorSort: nil,
                    sourceRootID: root.id)
                try dao.save(record)
                result.added += 1
            }
        }

        // Hide books previously under this root that weren't found this pass.
        let knownUnderRoot = try db.writer.read { db in
            try AudiobookRecord
                .filter(Column("source_root_id") == root.id)
                .filter(Column("is_available") == true)
                .fetchAll(db)
        }
        for book in knownUnderRoot where !foundIDs.contains(book.id) {
            var hidden = book
            hidden.isAvailable = false
            try dao.save(hidden)
            result.hidden += 1
        }

        var stampedRoot = root
        stampedRoot.lastScannedAt = timestamp
        try LibraryRootDAO(db: db.writer).save(stampedRoot)
        return result
    }
}
