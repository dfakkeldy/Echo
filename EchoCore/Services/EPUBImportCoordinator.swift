// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Coordinates the file-level operations of importing an EPUB into an
/// audiobook folder: copying the file (preserving same-folder sources),
/// clearing stale database blocks, and triggering extraction/parsing.
enum EPUBImportCoordinator {
    private static let logger = Logger(category: "EPUBImportCoordinator")

    /// Copies an EPUB file into the audiobook folder (if not already there),
    /// clears previous EPUB blocks from the database, and triggers a fresh
    /// import. Callers are responsible for starting security-scoped access on
    /// both URLs before invoking.
    static func importEPUB(
        from sourceURL: URL,
        to folderURL: URL,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?
    ) async {
        let didStartSource = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartSource { sourceURL.stopAccessingSecurityScopedResource() } }

        let didStartFolder = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartFolder { folderURL.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        let targetFolder = FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir) && isDir.boolValue
            ? folderURL
            : folderURL.deletingLastPathComponent()

        let didStartTarget = targetFolder != folderURL ? targetFolder.startAccessingSecurityScopedResource() : false
        defer { if didStartTarget { targetFolder.stopAccessingSecurityScopedResource() } }

        let destinationURL = targetFolder.appendingPathComponent(sourceURL.lastPathComponent)

        let standardizedSource = sourceURL.resolvingSymlinksInPath().standardized
        let standardizedDest = destinationURL.resolvingSymlinksInPath().standardized

        // Copy the EPUB into the folder when the source is outside of it.
        // Same-folder imports skip the copy to avoid replacing a file with itself.
        if standardizedDest.path != standardizedSource.path {
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: targetFolder.path)
                for file in files {
                    let lower = file.lowercased()
                    if lower.hasSuffix(".pdf") || lower.hasSuffix(".epub") {
                        let fileURL = targetFolder.appendingPathComponent(file)
                        if fileURL.resolvingSymlinksInPath().standardized.path != standardizedSource.path {
                            try FileManager.default.removeItem(at: fileURL)
                        }
                    }
                }
                var copyError: Error?
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?
                coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinatorError) { url in
                    do {
                        try FileManager.default.copyItem(at: url, to: destinationURL)
                    } catch {
                        copyError = error
                    }
                }
                if let error = copyError ?? coordinatorError {
                    throw error
                }
            } catch {
                logger.error("Failed to copy EPUB into folder: \(error.localizedDescription)")
                return
            }
        }

        // Clear existing database blocks so the forced import can re-ingest.
        let audiobookID = folderURL.absoluteString
        do {
            try EPubBlockDAO(db: databaseService.writer).deleteAll(for: audiobookID)
        } catch {
            logger.error("Failed to clear existing EPUB blocks: \(error.localizedDescription)")
            return
        }

        // Trigger extraction and block parsing asynchronously.
        await EPUBAutoImportScanner.importEPUBFile(
            epubURL: destinationURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: true
        )
    }
}
