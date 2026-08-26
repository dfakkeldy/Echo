// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Merges a sibling TEXT edition into an AUDIO edition for read-along: the
/// text edition's `.epub` is imported under the audio book's `audiobook_id`
/// via `EPUBImportCoordinator`, so its blocks and anchors key to the audio
/// folder. The standalone text row is deliberately left untouched —
/// `flashcard`/`study_plan`/`note`/`playback_state` all cascade-delete on
/// `audiobook.id`, so removing the row could destroy user data (spec
/// Amendment A1). Follows the `DatabaseService` DI pattern: concrete struct,
/// constructor injection, no protocol.
@MainActor
struct ReadAlongMergeService {

    enum MergeError: LocalizedError {
        case epubNotFound(URL)
        case expandedEPUBUnsupported(URL)

        nonisolated var errorDescription: String? {
            switch self {
            case .epubNotFound(let url):
                return
                    "Couldn't find an .epub file in \(url.lastPathComponent). Re-import the text edition, then try again."
            case .expandedEPUBUnsupported(let url):
                return
                    "\(url.lastPathComponent) is an unpacked EPUB folder, which can't be attached yet. Import a zipped .epub copy of the book and try again."
            }
        }
    }

    private let db: DatabaseService
    private let logger = Logger(category: "ReadAlongMergeService")

    init(db: DatabaseService) {
        self.db = db
    }

    /// Imports `text`'s epub into `audio`'s folder, keyed under `audio.id`.
    /// Both rows are resolved through `libraryService.urlForOpening` so
    /// root-backed books get their bookmark scope started for the copy.
    func merge(
        text: AudiobookRecord,
        intoAudio audio: AudiobookRecord,
        libraryService: LibraryService
    ) async throws {
        let textTarget = try libraryService.urlForOpening(text)
        let audioTarget = try libraryService.urlForOpening(audio)

        // The two books may share one root: starting the same scope twice and
        // stopping it twice is balanced, so no dedupe is needed.
        let scopedRoots = [textTarget.scopedRoot, audioTarget.scopedRoot].compactMap { $0 }
        let startedRoots = scopedRoots.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for root in startedRoots { root.stopAccessingSecurityScopedResource() }
        }

        let epubURL = try locateSourceEPUB(at: textTarget.url)
        let chapters = try persistedChapters(for: audio.id)

        try await EPUBImportCoordinator.importEPUB(
            from: epubURL,
            to: audioTarget.url,
            databaseService: db,
            chapters: chapters,
            duration: audio.duration > 0 ? audio.duration : nil
        )
        logger.info("Merged read-along text into \(audio.id)")
    }

    /// Whether the audio book already has imported text blocks. When it does,
    /// the merge action must not be offered — the import coordinator runs
    /// `force: true`, which would wipe the existing blocks and companion
    /// documents.
    func hasReadAlongText(_ audiobookID: String) -> Bool {
        do {
            return try !EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID).isEmpty
        } catch {
            logger.error(
                "Read-along text check failed for \(audiobookID): \(error.localizedDescription)")
            return false
        }
    }

    /// Bulk companion to `hasReadAlongText` for shelf loads: every audiobook id
    /// owning at least one `epub_block` row, in a single query. Errors degrade
    /// to an empty set (the menu action is simply not offered).
    func audiobookIDsWithText() -> Set<String> {
        do {
            return try db.writer.read { db in
                try Set(String.fetchAll(db, sql: "SELECT DISTINCT audiobook_id FROM epub_block"))
            }
        } catch {
            logger.error("Bulk read-along text lookup failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Private helpers

    /// Locates the zipped `.epub` behind a text edition's id, tolerating the
    /// three persisted id shapes (mirroring
    /// `EpubMetadataResolver.metadata(forAudiobookID:)`): the id is the `.epub`
    /// file itself, a folder containing one, or an expanded EPUB directory.
    /// v1 supports zipped epubs only — `EPUBImportCoordinator` requires a
    /// regular-file source and the scanner opens it as a ZIP archive — so
    /// expanded directories throw a descriptive error up front instead of
    /// failing deep inside the import.
    private func locateSourceEPUB(at url: URL) throws -> URL {
        if url.pathExtension.lowercased() == "epub" {
            guard let isDirectory = existsAsDirectory(url) else {
                throw MergeError.epubNotFound(url)
            }
            if isDirectory { throw MergeError.expandedEPUBUnsupported(url) }
            return url
        }

        guard existsAsDirectory(url) == true else { throw MergeError.epubNotFound(url) }

        let epubs =
            ((try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "epub" }
        if let zipped = epubs.first(where: { existsAsDirectory($0) == false }) {
            return zipped
        }
        if let expanded = epubs.first {
            throw MergeError.expandedEPUBUnsupported(expanded)
        }

        // The id may itself be an expanded EPUB directory.
        let containerXML = url.appendingPathComponent("META-INF/container.xml")
        if FileManager.default.fileExists(atPath: containerXML.path) {
            throw MergeError.expandedEPUBUnsupported(url)
        }
        throw MergeError.epubNotFound(url)
    }

    /// nil when nothing exists at `url`; otherwise whether it is a directory.
    private func existsAsDirectory(_ url: URL) -> Bool? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        return isDir.boolValue
    }

    /// Persisted chapter rows for the audio book, mapped back to the `Chapter`
    /// model the import coordinator expects (the reverse of
    /// `TimelineIngestionService.chapterRecords`).
    private func persistedChapters(for audiobookID: String) throws -> [Chapter] {
        try ChapterDAO(db: db.writer).chapters(for: audiobookID).enumerated().map { i, record in
            Chapter(
                index: i,
                title: record.title,
                startSeconds: record.startSeconds,
                endSeconds: record.endSeconds,
                isEnabled: record.isEnabled
            )
        }
    }
}
