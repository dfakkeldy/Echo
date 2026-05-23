import Foundation
import os.log

/// Coordinates the file-level operations of importing an EPUB into an
/// audiobook folder: copying the file (preserving same-folder sources),
/// clearing stale database blocks, and triggering extraction/parsing.
enum EPUBImportCoordinator {
    private static let logger = Logger(subsystem: "com.orbitaudiobooks", category: "EPUBImportCoordinator")

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
    ) {
        let destinationURL = folderURL.appendingPathComponent(sourceURL.lastPathComponent)

        let standardizedSource = sourceURL.resolvingSymlinksInPath().standardized
        let standardizedDest = destinationURL.resolvingSymlinksInPath().standardized

        // Copy new EPUB if destination differs from source (same-folder imports
        // skip the copy to avoid replacing a file with itself).
        if standardizedDest.path != standardizedSource.path {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("epub")

            do {
                try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL, backupItemName: nil, options: [])
                } else {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
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
        Task {
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
}
