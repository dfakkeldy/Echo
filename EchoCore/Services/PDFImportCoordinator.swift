import Foundation
import os.log

/// Coordinates the file-level operations of importing a PDF into an audiobook folder
enum PDFImportCoordinator {
    private static let logger = Logger(subsystem: "com.orbitaudiobooks", category: "PDFImportCoordinator")

    /// Copies a PDF file into the audiobook folder (if not already there).
    /// Callers are responsible for starting security-scoped access on
    /// both URLs before invoking.
    static func importPDF(
        from sourceURL: URL,
        to folderURL: URL
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
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                logger.info("Successfully copied PDF to \(destinationURL.path)")
            } catch {
                logger.error("Failed to copy PDF into folder: \(error.localizedDescription)")
            }
        }
    }
}
