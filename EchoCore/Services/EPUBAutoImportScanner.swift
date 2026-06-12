import Foundation
import os.log
import ZIPFoundation

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
        let folderIsDirectory = FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir) && isDir.boolValue
        let targetURL = folderIsDirectory ? folderURL : folderURL.deletingLastPathComponent()

        // When the original URL is a single file (e.g. an M4B opened directly),
        // SecurityScopeManager only covers that file — not its parent directory.
        // Start a temporary scope on the parent so we can enumerate siblings.
        let needsParentScope = !folderIsDirectory
        let didStartParentScope = needsParentScope && targetURL.startAccessingSecurityScopedResource()
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
            logger.warning("Cannot scan folder for EPUB files: \(sanitizedPath(targetURL.path)) — \(error.localizedDescription)")
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
            let alreadyImported = (try? EPubBlockDAO(db: databaseService.writer).visibleBlocks(for: audiobookID).isEmpty) == false
            if alreadyImported {
                logger.debug("EPUB blocks already exist for \(sanitizedPath(audiobookID)); skipping auto-import.")
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
            logger.error("Failed to extract EPUB \(sanitizedPath(epubURL.lastPathComponent)): \(error.localizedDescription)")
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
            logger.info("Auto-imported \(blocks.count) EPUB blocks for \(sanitizedPath(epubURL.lastPathComponent))")

            // Create initial system anchors (first block → 0, last block → duration)
            // so every block gets an interpolated timestamp from the start.
            let alignmentService = AlignmentService(db: databaseService.writer, audiobookID: audiobookID)
            let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)
            
            let alignmentSidecarURL = epubURL.deletingPathExtension().appendingPathExtension("alignment.json")
            if FileManager.default.fileExists(atPath: alignmentSidecarURL.path) {
                do {
                    let data = try Data(contentsOf: alignmentSidecarURL)
                    let exports = try JSONDecoder().decode([AlignmentAnchorExport].self, from: data)
                    logger.info("Found alignment.json sidecar with \(exports.count) anchors.")
                    try anchorDAO.deleteAll(for: audiobookID)
                    for export in exports {
                        let anchor = AlignmentAnchorRecord(
                            id: UUID().uuidString,
                            audiobookID: audiobookID,
                            epubBlockID: export.blockId,
                            audioTime: export.timestamp,
                            audioEndTime: nil,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                            source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
                            note: "Mac App DTW alignment",
                            createdAt: AlignmentService.isoFormatter.string(from: Date()),
                            modifiedAt: nil
                        )
                        try anchorDAO.upsert(anchor)
                    }
                    try alignmentService.recalculateTimeline()
                    logger.info("Ingested \(exports.count) anchors from alignment.json")
                } catch {
                    logger.error("Failed to ingest alignment.json sidecar: \(error.localizedDescription)")
                }
            } else {
                // Try CloudKit sync
                let syncService = CloudKitSyncService(db: databaseService.writer)
                // Use folder name as title, parent folder as author (common audiobook convention)
                let folderURL = epubURL.deletingLastPathComponent()
                let title = folderURL.lastPathComponent
                let author = folderURL.deletingLastPathComponent().lastPathComponent
                let durationVal = duration ?? 0.0
                
                let downloadedAnchors = (try? await syncService.downloadAnchors(audiobookID: audiobookID, title: title, author: author, duration: durationVal)) ?? []
                
                if !downloadedAnchors.isEmpty {
                    try? anchorDAO.deleteAll(for: audiobookID)
                    for anchor in downloadedAnchors {
                        try? anchorDAO.upsert(anchor)
                    }
                    try? alignmentService.recalculateTimeline()
                    logger.info("Ingested \(downloadedAnchors.count) anchors from CloudKit")
                } else if let firstBlock = blocks.first, let lastBlock = blocks.last, let bookDuration = duration {
                    // Anchor first block to time 0
                let firstAnchor = AlignmentAnchorRecord(
                    id: "anchor-init-first-\(audiobookID)",
                    audiobookID: audiobookID,
                    epubBlockID: firstBlock.id,
                    audioTime: 0,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.imported.rawValue,
                    note: "Auto-created: first block",
                    createdAt: AlignmentService.isoFormatter.string(from: Date()),
                    modifiedAt: nil
                )
                // Anchor last block to total duration
                let lastAnchor = AlignmentAnchorRecord(
                    id: "anchor-init-last-\(audiobookID)",
                    audiobookID: audiobookID,
                    epubBlockID: lastBlock.id,
                    audioTime: bookDuration,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.imported.rawValue,
                    note: "Auto-created: last block",
                    createdAt: AlignmentService.isoFormatter.string(from: Date()),
                    modifiedAt: nil
                )
                try? anchorDAO.deleteAll(for: audiobookID)
                try? anchorDAO.upsert(firstAnchor)
                try? anchorDAO.upsert(lastAnchor)
                try? alignmentService.recalculateTimeline()
                logger.info("Created initial alignment anchors for \(audiobookID)")
            }
            }

            // Always recalculate timeline to ensure chapter-boundary virtual
            // anchors cover blocks even when total duration is unknown.
            if duration == nil {
                try? alignmentService.recalculateTimeline()
                logger.info("Recalculated EPUB timeline (no book duration) for \(audiobookID)")
            }

            // Post notification to trigger UI refresh.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .timelineItemsIngested,
                    object: nil,
                    userInfo: ["audiobookID": audiobookID]
                )
            }
            return true
        } catch {
            logger.error("EPUB auto-import failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private helpers

    /// Creates (or reuses) the cache directory `Caches/EPUBUnpacked/<safeID>/`.
    private static func prepareCacheDirectory(safeID: String) throws -> URL {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else {
            throw ScannerError.cachesUnavailable
        }
        let dir = caches
            .appendingPathComponent("EPUBUnpacked", isDirectory: true)
            .appendingPathComponent(safeID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Extracts the `.epub` archive to a uniquely-named subdirectory under
    /// `<cacheDir>/` to prevent races when two imports of the same EPUB
    /// happen concurrently.  The caller should atomically move the content
    /// into its final location after extraction.
    private static func extractEPUB(_ epubURL: URL, to cacheDir: URL, safeID: String) throws -> URL {
        let destDir = cacheDir.appendingPathComponent("\(safeID)_\(UUID().uuidString)_content", isDirectory: true)

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Apply data protection so extracted book text is encrypted at rest.
        try (destDir as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)

        // Copy the EPUB into the cache directory so Archive opens a local file
        // rather than a file-provider-managed one. This avoids permission issues
        // with File Provider Storage paths.
        let cachedEPUB = cacheDir.appendingPathComponent("\(safeID).epub")
        if FileManager.default.fileExists(atPath: cachedEPUB.path) {
            try FileManager.default.removeItem(at: cachedEPUB)
        }
        do {
            let started = epubURL.startAccessingSecurityScopedResource()
            defer { if started { epubURL.stopAccessingSecurityScopedResource() } }

            var copyError: Error?
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            coordinator.coordinate(readingItemAt: epubURL, options: .withoutChanges, error: &coordinatorError) { url in
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
            logger.error("Failed to copy EPUB to cache at \(sanitizedPath(cachedEPUB.path)): \(error.localizedDescription)")
            throw ScannerError.invalidArchive(url: epubURL)
        }

        let archive: Archive
        do {
            logger.debug("Opening EPUB archive from cache: \(sanitizedPath(cachedEPUB.path))")
            archive = try Archive(url: cachedEPUB, accessMode: .read)
        } catch {
            logger.error("Failed to open EPUB archive at \(sanitizedPath(cachedEPUB.path)): \(error.localizedDescription) (type: \(type(of: error)))")
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

        for entry in archive {
            guard entry.type == .file else { continue }
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

        logger.debug("Extracted EPUB to \(sanitizedPath(destDir.path))")
        return destDir
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

// MARK: - Sidecar Models

private struct AlignmentAnchorExport: Codable {
    let blockId: String
    let timestamp: TimeInterval
    let confidence: Double
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
