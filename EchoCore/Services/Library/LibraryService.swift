// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import os.log

/// The grouping axes available in the Library browser. Status-based axes
/// (e.g. `.unread`, `.inProgress`) are added in Task 10.
enum LibraryAxis {
    case recentlyAdded
    case author
    case topic
    case folder
}

/// A titled group of books returned by `LibraryService.sections(by:)`.
/// Note: not `Equatable` because `AudiobookRecord` is not `Equatable`; add
/// conformance once `AudiobookRecord` gains it (Task 10+).
struct LibrarySection {
    let title: String
    let books: [AudiobookRecord]
}

/// Errors thrown by `LibraryService` query methods.
enum LibraryError: Error {
    /// The book's id could not be parsed to a URL and has no resolvable root.
    case unresolvableBook(String)
}

/// Resolution result for opening a library book. The caller (the player layer)
/// owns the security-scope lifecycle: before accessing `url`, call
/// `scopedRoot?.startAccessingSecurityScopedResource()`, and call the matching
/// `stopAccessingSecurityScopedResource()` when the book is closed (M3 routes this
/// through SecurityScopeManager). LibraryService intentionally starts NO scope itself.
struct LibraryOpenTarget {
    let url: URL  // book folder URL to open
    let scopedRoot: URL?  // root whose scope the caller must start/stop; nil for standalone books
}

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

    // MARK: - Query

    /// Returns all books ordered by `added_at` DESC. Filters out unavailable books
    /// unless `includeUnavailable` is `true`.
    func books(includeUnavailable: Bool) throws -> [AudiobookRecord] {
        try db.writer.read { db in
            var request = AudiobookRecord.order(Column("added_at").desc)
            if !includeUnavailable {
                request = request.filter(Column("is_available") == true)
            }
            return try request.fetchAll(db)
        }
    }

    /// Returns books grouped into sections according to `axis`. Books within each
    /// section are sorted by title; sections are sorted deterministically by key.
    func sections(by axis: LibraryAxis, includeUnavailable: Bool) throws -> [LibrarySection] {
        let all = try books(includeUnavailable: includeUnavailable)
        switch axis {
        case .recentlyAdded:
            return [LibrarySection(title: "Recently Added", books: all)]
        case .author:
            return grouped(
                all, key: { $0.authorSort ?? "unknown" },
                title: { $0.author ?? "Unknown Author" })
        case .topic:
            return groupedByTopic(all)
        case .folder:
            return grouped(all, key: { rootKey(for: $0) }, title: { rootKey(for: $0) })
        }
    }

    /// Resolves the folder URL to open this book, together with the library root
    /// whose security scope the caller must enter. This method is SIDE-EFFECT-FREE:
    /// it does NOT call `startAccessingSecurityScopedResource()` — the player layer
    /// owns that lifecycle (start before access, stop on close) so the scope is
    /// never leaked. See `LibraryOpenTarget` for the contract.
    ///
    /// A root-backed book whose root row is missing or whose bookmark no longer
    /// resolves is treated as unavailable and throws `LibraryError.unresolvableBook`
    /// (it must not silently fall through to an unscoped open).
    func urlForOpening(_ book: AudiobookRecord) throws -> LibraryOpenTarget {
        if let rootID = book.sourceRootID {
            guard let root = try LibraryRootDAO(db: db.writer).get(rootID),
                let resolved = LibraryAccess.resolveURL(from: root.bookmark),
                // book.id is stored as the folder's absoluteString (e.g. "file:///path/").
                // URL(string:) correctly parses it, including percent-encoded characters,
                // without the fragile replacingOccurrences approach in the brief.
                let childURL = URL(string: book.id)
            else {
                throw LibraryError.unresolvableBook(book.id)
            }
            return LibraryOpenTarget(url: childURL, scopedRoot: resolved.url)
        }
        guard let url = URL(string: book.id) else {
            throw LibraryError.unresolvableBook(book.id)
        }
        return LibraryOpenTarget(url: url, scopedRoot: nil)
    }

    // MARK: - Private grouping helpers

    /// Groups `books` by `key`, sorts sections by that key, and derives each
    /// section's display title from the first book in the group.
    private func grouped(
        _ books: [AudiobookRecord],
        key: (AudiobookRecord) -> String,
        title: (AudiobookRecord) -> String
    ) -> [LibrarySection] {
        let groups = Dictionary(grouping: books, by: key)
        return groups.keys.sorted().map { k in
            let items = groups[k]!.sorted { $0.title < $1.title }
            return LibrarySection(title: title(items[0]), books: items)
        }
    }

    /// Groups books by each decoded topic tag; a book with multiple topics appears
    /// in multiple sections.
    private func groupedByTopic(_ books: [AudiobookRecord]) -> [LibrarySection] {
        var byTopic: [String: [AudiobookRecord]] = [:]
        for book in books {
            for topic in decodeTopics(book.topicsJSON) {
                byTopic[topic, default: []].append(book)
            }
        }
        return byTopic.keys.sorted().map { topic in
            LibrarySection(
                title: topic, books: byTopic[topic]!.sorted { $0.title < $1.title })
        }
    }

    /// Decodes a JSON array of topic strings from `json`. Returns `[]` on any failure.
    private func decodeTopics(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
            let topics = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return topics
    }

    /// Returns the parent folder name from the book's `id` URL for grouping by folder.
    private func rootKey(for book: AudiobookRecord) -> String {
        URL(string: book.id)?.deletingLastPathComponent().lastPathComponent ?? "Other"
    }
}
