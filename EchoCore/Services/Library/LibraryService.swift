// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
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
        let bookmark: Data
        if let made = LibraryAccess.makeBookmark(for: url) {
            bookmark = made
        } else {
            logger.warning(
                "Could not bookmark root at \(url.path); storing empty bookmark (rescan will skip)."
            )
            bookmark = Data()
        }
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
    @discardableResult
    func rescan(
        root: LibraryRootRecord,
        discover: (URL) -> [DiscoveredBook] = { LibraryScanner.discoverBooks(in: $0) },
        now: () -> String = { Date().ISO8601Format() }
    ) throws -> RescanResult {
        // A stale/unresolvable bookmark (the missing-root scenario) must NOT fall
        // through to scanning a placeholder path — that would enumerate the whole
        // filesystem root. Skip the rescan and leave existing rows untouched.
        guard let rootURL = LibraryAccess.resolveURL(from: root.bookmark)?.url else {
            logger.warning("Root \(root.id) bookmark unresolved; skipping rescan.")
            return RescanResult(added: 0, updated: 0, hidden: 0)
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

    /// Rescan that also enriches each found book with cheap metadata (title,
    /// author, narrator, duration, cover). `readMetadata` is injected for tests;
    /// production passes `LibraryScanner.readMetadata`. Covers are written as JPEG
    /// under `coversDir` and the relative path stored on the row.
    @discardableResult
    func rescan(
        root: LibraryRootRecord,
        discover: (URL) -> [DiscoveredBook] = { LibraryScanner.discoverBooks(in: $0) },
        readMetadata: (DiscoveredBook) async -> LibraryScanner.ScannedMetadata,
        coversDir: URL,
        now: () -> String = { Date().ISO8601Format() }
    ) async throws -> RescanResult {
        guard let rootURL = LibraryAccess.resolveURL(from: root.bookmark)?.url else {
            logger.warning("Root \(root.id) bookmark unresolved; skipping metadata rescan.")
            return RescanResult(added: 0, updated: 0, hidden: 0)
        }
        try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)

        let dao = AudiobookDAO(db: db.writer)
        let found = discover(rootURL)
        let foundIDs = Set(found.map { $0.folderURL.absoluteString })
        var result = RescanResult(added: 0, updated: 0, hidden: 0)
        let timestamp = now()

        for book in found {
            let id = book.folderURL.absoluteString
            let meta = await readMetadata(book)
            let coverPath = writeCover(meta.coverImageData, id: id, coversDir: coversDir)
            let existing = try dao.get(id)
            var record: AudiobookRecord
            if let e = existing {
                record = e
            } else {
                record = AudiobookRecord(
                    id: id, title: meta.title, author: meta.author,
                    duration: meta.duration, fileCount: book.audioFiles.count,
                    addedAt: timestamp)
            }
            record.title = meta.title
            record.author = meta.author
            record.narrator = meta.narrator
            record.duration = meta.duration
            record.authorSort = LibraryAccess.authorSort(meta.author)
            record.coverArtPath = coverPath ?? record.coverArtPath
            record.fileCount = book.audioFiles.count
            record.isAvailable = true
            record.lastSeenAt = timestamp
            record.indexState = existing?.indexState ?? 0
            if record.sourceRootID == nil { record.sourceRootID = root.id }
            try dao.save(record)
            if existing == nil { result.added += 1 } else { result.updated += 1 }
        }

        // Hide books previously under this root that weren't found this pass.
        let knownUnderRoot = try await db.writer.read { db in
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

    /// Writes cover JPEG bytes under `coversDir`, named with a SHA-256 hash of
    /// the book id for cross-launch stability. Returns the relative filename, or
    /// nil if `data` is nil or the write fails.
    private func writeCover(_ data: Data?, id: String, coversDir: URL) -> String? {
        guard let data else { return nil }
        let name = coverFilename(for: id)
        let url = coversDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return name
        } catch {
            logger.error("Cover write failed for \(id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Derives a stable, cross-launch cover filename by SHA-256 hashing the book
    /// id. Unlike Swift's `Hasher` (per-run seeded), SHA-256 is deterministic so
    /// the same book always maps to the same file, preventing orphaned covers.
    private func coverFilename(for id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}
