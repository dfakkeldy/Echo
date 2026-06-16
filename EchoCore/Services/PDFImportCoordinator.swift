// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Coordinates the file-level operations of importing a PDF into an audiobook folder
enum PDFImportCoordinator {
    private static let logger = Logger(category: "PDFImportCoordinator")

    /// Copies a PDF file into the audiobook folder (if not already there).
    /// Callers are responsible for starting security-scoped access on
    /// both URLs before invoking.
    static func importPDF(
        from sourceURL: URL,
        to folderURL: URL,
        databaseService: DatabaseService? = nil
    ) {
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

        // Copy the PDF into the folder when the source is outside of it.
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
                logger.info("Successfully copied PDF to \(destinationURL.path)")
            } catch {
                logger.error("Failed to copy PDF into folder: \(error.localizedDescription)")
            }
        }
        
        // Clear any existing database blocks so EPUB state is fully wiped out.
        if let databaseService = databaseService {
            let audiobookID = folderURL.absoluteString
            do {
                try EPubBlockDAO(db: databaseService.writer).deleteAll(for: audiobookID)
            } catch {
                logger.error("Failed to clear existing EPUB blocks: \(error.localizedDescription)")
            }
        }
    }
}
