// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ZIPFoundation
import os.log

enum EPUBAutoImportScanner {
    private static let logger = Logger(category: "EPUBAutoImport")

    /// Scans the given audiobook folder for `.epub` files. When one is found
    /// and no prior EPUB blocks exist in the database, the archive is extracted
    /// and imported via `EPUBImportService`.
    ///
    /// - Parameters:
    ///   - folderURL: The audiobook folder to scan.
    ///   - databaseService: The database service for checking existing imports and persisting blocks.
    ///   - chapters: The parsed chapter list for this audiobook.
    ///   - duration: The total audiobook duration (used for timestamp estimation).
    /// - Returns: `true` when an EPUB was actually imported (blocks created) —
    ///   callers must re-ingest timeline items so `timeline_item` rows reference
    ///   the freshly created block IDs. `false` when skipped or failed.
    @discardableResult
    static func scanAndImportIfNeeded(
        folderURL: URL,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?
    ) async -> Bool {
        // Security-scoped access is managed by SecurityScopeManager in loadFolder.
        // Don't start/stop here — duplicate cycles break file-provider access.

        let audiobookID = folderURL.absoluteString

        // 1. Scan for .epub files in the folder.
        let epubFiles: [URL]
        var isDir: ObjCBool = false
        let folderIsDirectory =
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            && isDir.boolValue
        let targetURL = folderIsDirectory ? folderURL : folderURL.deletingLastPathComponent()

        // When the original URL is a single file (e.g. an M4B opened directly),
        // SecurityScopeManager only covers that file — not its parent directory.
        // Start a temporary scope on the parent so we can enumerate siblings.
        let needsParentScope = !folderIsDirectory
        let didStartParentScope =
            needsParentScope && targetURL.startAccessingSecurityScopedResource()
        defer {
            if didStartParentScope {
                targetURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )
            epubFiles = contents.filter { $0.pathExtension.lowercased() == "epub" }
        } catch {
            logger.warning(
                "Cannot scan folder for EPUB files: \(sanitizedPath(targetURL.path)) — \(error.localizedDescription)"
            )
            return false
        }

        guard let epubURL = epubFiles.first else {
            logger.debug("No .epub file found in folder: \(sanitizedPath(folderURL.path))")
            return false
        }

        logger.info("Found EPUB file: \(sanitizedPath(epubURL.lastPathComponent))")

        return await importEPUBFile(
            epubURL: epubURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: false
        )
    }

    /// Imports a specific EPUB file for an audiobook, extracting and parsing its blocks.
    /// - Returns: `true` when blocks were imported, `false` when skipped or failed.
    @discardableResult
    static func importEPUBFile(
        epubURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?,
        force: Bool = false
    ) async -> Bool {
        // Security-scoped access is managed by SecurityScopeManager in loadFolder.
        // Don't start/stop here — duplicate cycles break file-provider access.

        // Check if EPUB blocks are already imported for this audiobook.
        if !force {
            let alreadyImported =
                (try? EPubBlockDAO(db: databaseService.writer).visibleBlocks(for: audiobookID)
                    .isEmpty) == false
            if alreadyImported {
                logger.debug(
                    "EPUB blocks already exist for \(sanitizedPath(audiobookID)); skipping auto-import."
                )
                return false
            }
        }

        // Try downloading CloudKit anchors first if not forced, but wait, if blocks aren't extracted yet, CloudKit anchors need the blocks.
        // So we must extract EPUB first, insert blocks, then check CloudKit before doing auto-alignment.

        // Extract the EPUB archive to a cache directory.
        let safeID = SafeFileName.fromAudiobookID(audiobookID)
        let cacheDir: URL
        do {
            cacheDir = try prepareCacheDirectory(safeID: safeID)
        } catch {
            logger.error("Failed to prepare EPUB cache directory: \(error.localizedDescription)")
            return false
        }

        let extractedDir: URL
        do {
            extractedDir = try extractEPUB(epubURL, to: cacheDir, safeID: safeID)
        } catch {
            logger.error(
                "Failed to extract EPUB \(sanitizedPath(epubURL.lastPathComponent)): \(error.localizedDescription)"
            )
            return false
        }

        // Import extracted EPUB blocks.
        do {
            let assetStorage = EPUBAssetStorage(databaseService: databaseService)
            let importer = EPUBImportService(assetStorage: assetStorage)
            let blocks = try await importer.import(
                audiobookID: audiobookID,
                epubURL: extractedDir,
                chapters: chapters,
                bookDuration: duration
            )
            logger.info(
                "Auto-imported \(blocks.count) EPUB blocks for \(sanitizedPath(epubURL.lastPathComponent))"
            )

            return await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID, blocks: blocks, fileURL: epubURL,
                duration: duration, databaseService: databaseService)
        } catch {
            logger.error("EPUB auto-import failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Anchor lookup

    /// Title/author to use for the CloudKit anchor lookup. Prefer the persisted
    /// audiobook row (authoritative — for ABS books this is the real ABS metadata);
    /// fall back to folder-name derivation for not-yet-persisted local books.
    static func anchorLookupMetadata(folderURL: URL, record: AudiobookRecord?) -> (
        title: String, author: String
    ) {
        let title = record?.title ?? folderURL.lastPathComponent
        let author = record?.author ?? folderURL.deletingLastPathComponent().lastPathComponent
        return (title, author)
    }

    // MARK: - Private helpers

    /// Creates (or reuses) the cache directory `Caches/EPUBUnpacked/<safeID>/`.
    private static func prepareCacheDirectory(safeID: String) throws -> URL {
        guard
            let caches = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first
        else {
            throw ScannerError.cachesUnavailable
        }
        let dir =
            caches
            .appendingPathComponent("EPUBUnpacked", isDirectory: true)
            .appendingPathComponent(safeID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Extracts the `.epub` archive to a uniquely-named subdirectory under
    /// `<cacheDir>/` to prevent races when two imports of the same EPUB
    /// happen concurrently.  The caller should atomically move the content
    /// into its final location after extraction.
    private static func extractEPUB(_ epubURL: URL, to cacheDir: URL, safeID: String) throws -> URL
    {
        let destDir = cacheDir.appendingPathComponent(
            "\(safeID)_\(UUID().uuidString)_content", isDirectory: true)

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Copy the EPUB into the cache directory so Archive opens a local file
        // rather than a file-provider-managed one. This avoids permission issues
        // with File Provider Storage paths. The copy is uniquely named and
        // removed after extraction — a shared name raced when two imports ran
        // concurrently (remove/copy interleaving truncated the archive).
        let cachedEPUB = cacheDir.appendingPathComponent("\(safeID)_\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: cachedEPUB) }
        do {
            let started = epubURL.startAccessingSecurityScopedResource()
            defer { if started { epubURL.stopAccessingSecurityScopedResource() } }

            var copyError: Error?
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            coordinator.coordinate(
                readingItemAt: epubURL, options: .withoutChanges, error: &coordinatorError
            ) { url in
                do {
                    try FileManager.default.copyItem(at: url, to: cachedEPUB)
                } catch {
                    copyError = error
                }
            }
            if let error = copyError ?? coordinatorError {
                throw error
            }
        } catch {
            logger.error(
                "Failed to copy EPUB to cache at \(sanitizedPath(cachedEPUB.path)): \(error.localizedDescription)"
            )
            throw ScannerError.invalidArchive(url: epubURL)
        }

        let archive: Archive
        do {
            logger.debug("Opening EPUB archive from cache: \(sanitizedPath(cachedEPUB.path))")
            archive = try Archive(url: cachedEPUB, accessMode: .read)
        } catch {
            logger.error(
                "Failed to open EPUB archive at \(sanitizedPath(cachedEPUB.path)): \(error.localizedDescription) (type: \(type(of: error)))"
            )
            throw ScannerError.invalidArchive(url: epubURL)
        }

        // Validate mimetype.
        if let mimetypeEntry = archive["mimetype"] {
            var mimetypeData = Data()
            _ = try archive.extract(mimetypeEntry) { chunk in
                mimetypeData.append(chunk)
            }
            let mimetypeString = String(data: mimetypeData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard mimetypeString == "application/epub+zip" else {
                throw ScannerError.invalidEPUB(path: epubURL.path)
            }
        }

        var totalExtracted: UInt64 = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            // Reject decompression bombs before touching the filesystem (audit §6.1).
            do {
                totalExtracted = try ArchiveExtractionLimits.checkedTotal(
                    addingEntryOfSize: entry.uncompressedSize, to: totalExtracted
                )
            } catch {
                throw ScannerError.invalidArchive(url: epubURL)
            }
            // Validate the entry path *before* creating any directory or
            // writing any file, so a hostile archive can never coax us into
            // touching the filesystem outside `destDir`.
            let destination = try safeDestination(for: entry.path, within: destDir)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: destination)
        }

        // Apply data protection after extraction. Setting it on the directory
        // first can make simulator writes fail with EPERM, while device files
        // still need explicit protection once ZIPFoundation has created them.
        #if os(iOS) && !targetEnvironment(simulator)
        try applyDataProtectionRecursively(to: destDir)
        #endif

        logger.debug("Extracted EPUB to \(sanitizedPath(destDir.path))")
        return destDir
    }

    private static func applyDataProtectionRecursively(to root: URL) throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
            )
        else { return }

        let descendants = enumerator.compactMap { $0 as? URL }
            .sorted { $0.path.count > $1.path.count }

        for url in descendants {
            try (url as NSURL).setResourceValue(
                URLFileProtection.complete, forKey: .fileProtectionKey)
        }
        try (root as NSURL).setResourceValue(
            URLFileProtection.complete, forKey: .fileProtectionKey)
    }

    /// Resolves a ZIP entry path to its on-disk destination, guaranteeing the
    /// result stays inside `root` (zip-slip / directory-traversal defense).
    ///
    /// ZIPFoundation's `unzipItem(at:to:)` performs this check internally, but
    /// we extract entries individually (to validate the mimetype and stream
    /// each entry), so the guard is ours to enforce. Throws when the entry path
    /// is absolute or escapes `root` via `..` segments.  (CODE_AUDIT.md §6.1)
    static func safeDestination(for entryPath: String, within root: URL) throws -> URL {
        // Absolute entry paths have no legitimate use in an EPUB and would
        // otherwise be silently re-rooted by `appendingPathComponent`.
        guard !entryPath.hasPrefix("/") else {
            throw ScannerError.unsafeEntryPath(entryPath)
        }

        let destination = root.appendingPathComponent(entryPath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path

        // After normalizing `..` segments, the destination must remain within
        // root — i.e. be root itself or a path beneath `root/`.
        guard destination.path == rootPath || destination.path.hasPrefix(rootPath + "/") else {
            throw ScannerError.unsafeEntryPath(entryPath)
        }

        return destination
    }

    /// Sanitizes a filesystem path for safe logging (strips the user's home
    /// directory prefix to avoid leaking the full path in logs).
    private static func sanitizedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Errors

private enum ScannerError: LocalizedError {
    case cachesUnavailable
    case invalidArchive(url: URL)
    case invalidEPUB(path: String)
    case unsafeEntryPath(String)

    var errorDescription: String? {
        switch self {
        case .cachesUnavailable:
            return "Caches directory is unavailable"
        case .invalidArchive(let url):
            return "Cannot open archive: \(url.lastPathComponent)"
        case .invalidEPUB(let path):
            return "File is not a valid EPUB: \(path)"
        case .unsafeEntryPath(let path):
            return "EPUB contains an unsafe entry path: \(path)"
        }
    }
}
