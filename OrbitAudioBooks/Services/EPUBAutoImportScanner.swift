import Foundation
import os.log
import ZIPFoundation

enum EPUBAutoImportScanner {
    private static let logger = Logger(subsystem: "com.orbitaudiobooks", category: "EPUBAutoImport")

    /// Scans the given audiobook folder for `.epub` files. When one is found
    /// and no prior EPUB blocks exist in the database, the archive is extracted
    /// and imported via `EPUBImportService`.
    ///
    /// - Parameters:
    ///   - folderURL: The audiobook folder to scan.
    ///   - databaseService: The database service for checking existing imports and persisting blocks.
    ///   - chapters: The parsed chapter list for this audiobook.
    ///   - duration: The total audiobook duration (used for timestamp estimation).
    static func scanAndImportIfNeeded(
        folderURL: URL,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?
    ) async {
        let audiobookID = folderURL.absoluteString

        // 1. Scan for .epub files in the folder.
        let epubFiles: [URL]
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )
            epubFiles = contents.filter { $0.pathExtension.lowercased() == "epub" }
        } catch {
            logger.warning("Cannot scan folder for EPUB files: \(sanitizedPath(folderURL.path)) — \(error.localizedDescription)")
            return
        }

        guard let epubURL = epubFiles.first else {
            logger.debug("No .epub file found in folder: \(sanitizedPath(folderURL.path))")
            return
        }

        logger.info("Found EPUB file: \(sanitizedPath(epubURL.lastPathComponent))")

        await importEPUBFile(
            epubURL: epubURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: false
        )
    }

    /// Imports a specific EPUB file for an audiobook, extracting and parsing its blocks.
    static func importEPUBFile(
        epubURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?,
        force: Bool = false
    ) async {
        // Check if EPUB blocks are already imported for this audiobook.
        if !force {
            let alreadyImported = (try? EPubBlockDAO(db: databaseService.writer).visibleBlocks(for: audiobookID).isEmpty) == false
            if alreadyImported {
                logger.debug("EPUB blocks already exist for \(sanitizedPath(audiobookID)); skipping auto-import.")
                return
            }
        }

        // Extract the EPUB archive to a cache directory.
        let safeID = SafeFileName.fromAudiobookID(audiobookID)
        let cacheDir: URL
        do {
            cacheDir = try prepareCacheDirectory(safeID: safeID)
        } catch {
            logger.error("Failed to prepare EPUB cache directory: \(error.localizedDescription)")
            return
        }

        let extractedDir: URL
        do {
            extractedDir = try extractEPUB(epubURL, to: cacheDir, safeID: safeID)
        } catch {
            logger.error("Failed to extract EPUB \(sanitizedPath(epubURL.lastPathComponent)): \(error.localizedDescription)")
            return
        }

        // Import extracted EPUB blocks.
        do {
            let importer = EPUBImportService()
            let blocks = try await importer.import(
                audiobookID: audiobookID,
                epubURL: extractedDir,
                chapters: chapters,
                bookDuration: duration
            )
            logger.info("Auto-imported \(blocks.count) EPUB blocks for \(sanitizedPath(epubURL.lastPathComponent))")

            // Post notification to trigger UI refresh.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .timelineItemsIngested,
                    object: nil,
                    userInfo: ["audiobookID": audiobookID]
                )
            }
        } catch {
            logger.error("EPUB auto-import failed: \(error.localizedDescription)")
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

    /// Extracts the `.epub` archive to `<cacheDir>/<safeID>_content/`.
    /// Falls back to a manual approach when ZIPFoundation is not linked.
    private static func extractEPUB(_ epubURL: URL, to cacheDir: URL, safeID: String) throws -> URL {
        let destDir = cacheDir.appendingPathComponent("\(safeID)_content", isDirectory: true)

        // Remove any stale extraction.
        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        guard let archive = Archive(url: epubURL, accessMode: .read) else {
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
            let destination = destDir.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: destination)
        }

        logger.debug("Extracted EPUB to \(sanitizedPath(destDir.path))")
        return destDir
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

    var errorDescription: String? {
        switch self {
        case .cachesUnavailable:
            return "Caches directory is unavailable"
        case .invalidArchive(let url):
            return "Cannot open archive: \(url.lastPathComponent)"
        case .invalidEPUB(let path):
            return "File is not a valid EPUB: \(path)"
        }
    }
}
