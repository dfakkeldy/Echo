// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log
import PDFKit

/// Coordinates the file-level operations of importing a PDF into an audiobook folder
enum PDFImportCoordinator {
    private static let logger = Logger(category: "PDFImportCoordinator")

    struct ImportResult {
        let sourceURL: URL
        let destinationURL: URL
        let audiobookID: String
        let copiedFile: Bool
    }

    enum ImportError: LocalizedError {
        case sourceUnavailable(URL, underlying: Error?)
        case targetUnavailable(URL, underlying: Error?)
        case folderCleanupFailed(URL, underlying: Error)
        case copyFailed(source: URL, destination: URL, underlying: Error)
        case databaseCleanupFailed(audiobookID: String, underlying: Error)
        case unreadableDocument(URL)
        case scannerFailed(URL, underlying: Error?)

        nonisolated var errorDescription: String? {
            switch self {
            case .sourceUnavailable(let url, let underlying):
                if let underlying {
                    return "Could not read \(url.lastPathComponent): \(underlying.localizedDescription)"
                }
                return "Could not read \(url.lastPathComponent)."
            case .targetUnavailable(let url, let underlying):
                if let underlying {
                    return "Could not access the book folder: \(underlying.localizedDescription)"
                }
                return "Could not access the book folder at \(url.lastPathComponent)."
            case .folderCleanupFailed(_, let underlying):
                return "Could not prepare the book folder: \(underlying.localizedDescription)"
            case .copyFailed(let source, _, let underlying):
                return "Could not copy \(source.lastPathComponent): \(underlying.localizedDescription)"
            case .databaseCleanupFailed(_, let underlying):
                return "Could not clear the previous document import: \(underlying.localizedDescription)"
            case .unreadableDocument(let url):
                return "Could not open \(url.lastPathComponent) as a PDF."
            case .scannerFailed(let url, let underlying):
                if let underlying {
                    return "Echo copied \(url.lastPathComponent), but could not import its text: \(underlying.localizedDescription)"
                }
                return "Echo copied \(url.lastPathComponent), but could not import its text."
            }
        }
    }

    /// Copies a PDF file into the audiobook folder (if not already there).
    /// Also clears previous document blocks and imports readable PDF text.
    @discardableResult
    static func importPDF(
        from sourceURL: URL,
        to folderURL: URL,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?
    ) async throws -> ImportResult {
        let didStartSource = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartSource { sourceURL.stopAccessingSecurityScopedResource() } }

        let didStartFolder = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartFolder { folderURL.stopAccessingSecurityScopedResource() } }

        try validateReadableSource(sourceURL)
        try await validatePDFDocument(sourceURL)

        var isDir: ObjCBool = false
        let targetFolder = FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir) && isDir.boolValue
            ? folderURL
            : folderURL.deletingLastPathComponent()

        let didStartTarget = targetFolder != folderURL ? targetFolder.startAccessingSecurityScopedResource() : false
        defer { if didStartTarget { targetFolder.stopAccessingSecurityScopedResource() } }

        try validateTargetFolder(targetFolder)

        let destinationURL = targetFolder.appendingPathComponent(sourceURL.lastPathComponent)

        let standardizedSource = sourceURL.resolvingSymlinksInPath().standardized
        let standardizedDest = destinationURL.resolvingSymlinksInPath().standardized
        let shouldCopy = standardizedDest.path != standardizedSource.path
        let importURL: URL
        if shouldCopy {
            let stagedURL = stagingURL(in: targetFolder, basedOn: sourceURL)
            try copyCoordinatedItem(from: sourceURL, to: stagedURL)
            importURL = stagedURL
        } else {
            importURL = sourceURL
        }

        let audiobookID = folderURL.absoluteString

        let importOutcome = await PDFAutoImportScanner.importPDFFileOutcome(
            pdfURL: importURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: true,
            finalizerFileURL: destinationURL
        )
        switch importOutcome {
        case .imported:
            break
        case .noReadableText:
            do {
                try await clearExistingDocumentBlocks(
                    audiobookID: audiobookID,
                    databaseService: databaseService
                )
            } catch {
                if shouldCopy {
                    try? FileManager.default.removeItem(at: importURL)
                }
                throw error
            }
            break
        case .alreadyImported:
            break
        case .unreadable(_, let underlying), .failed(_, let underlying):
            if shouldCopy {
                try? FileManager.default.removeItem(at: importURL)
            }
            throw ImportError.scannerFailed(importURL, underlying: underlying)
        }

        let finalURL = finalizeSuccessfulImport(
            importURL: importURL,
            destinationURL: destinationURL,
            targetFolder: targetFolder,
            sourceURL: sourceURL,
            shouldMoveStagedFile: shouldCopy
        )

        return ImportResult(
            sourceURL: sourceURL,
            destinationURL: finalURL,
            audiobookID: audiobookID,
            copiedFile: shouldCopy
        )
    }

    private static func validateReadableSource(_ sourceURL: URL) throws {
        do {
            guard try sourceURL.checkResourceIsReachable() else {
                throw ImportError.sourceUnavailable(sourceURL, underlying: nil)
            }
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.sourceUnavailable(sourceURL, underlying: error)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir),
            !isDir.boolValue,
            FileManager.default.isReadableFile(atPath: sourceURL.path)
        else {
            throw ImportError.sourceUnavailable(sourceURL, underlying: nil)
        }
    }

    private static func validatePDFDocument(_ sourceURL: URL) async throws {
        let canOpen = await Task.detached(priority: .userInitiated) {
            PDFDocument(url: sourceURL) != nil
        }.value

        guard canOpen else {
            throw ImportError.unreadableDocument(sourceURL)
        }
    }

    private static func validateTargetFolder(_ targetFolder: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetFolder.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            throw ImportError.targetUnavailable(targetFolder, underlying: nil)
        }
    }

    private static func clearExistingDocumentBlocks(
        audiobookID: String,
        databaseService: DatabaseService
    ) async throws {
        do {
            try await databaseService.writer.write { database in
                try EPubTOCEntryRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .deleteAll(database)
                try EPubBlockRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .deleteAll(database)
            }
        } catch {
            logger.error("Failed to clear existing document blocks: \(error.localizedDescription)")
            throw ImportError.databaseCleanupFailed(audiobookID: audiobookID, underlying: error)
        }
    }

    private static func stagingURL(in targetFolder: URL, basedOn sourceURL: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        return targetFolder
            .appendingPathComponent("\(base).echo-import-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private static func copyCoordinatedItem(from sourceURL: URL, to destinationURL: URL) throws {
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
            logger.error("Failed to copy PDF into folder: \(error.localizedDescription)")
            throw ImportError.copyFailed(
                source: sourceURL, destination: destinationURL, underlying: error)
        }
        logger.info("Successfully staged PDF at \(destinationURL.path)")
    }

    private static func finalizeSuccessfulImport(
        importURL: URL,
        destinationURL: URL,
        targetFolder: URL,
        sourceURL: URL,
        shouldMoveStagedFile: Bool
    ) -> URL {
        let exclusions = [
            sourceURL.resolvingSymlinksInPath().standardized.path,
            importURL.resolvingSymlinksInPath().standardized.path,
        ]
        do {
            try removeExistingCompanionDocuments(
                in: targetFolder,
                excluding: Set(exclusions),
                sourceKind: "PDF"
            )
        } catch {
            logger.error("PDF import succeeded, but stale companion cleanup failed: \(error.localizedDescription)")
        }

        guard shouldMoveStagedFile else { return importURL }

        do {
            try FileManager.default.moveItem(at: importURL, to: destinationURL)
            logger.info("Successfully finalized PDF at \(destinationURL.path)")
            return destinationURL
        } catch {
            logger.error("Failed to finalize PDF import: \(error.localizedDescription)")
            return importURL
        }
    }

    private static func removeExistingCompanionDocuments(
        in targetFolder: URL,
        excluding excludedPaths: Set<String>,
        sourceKind: String
    ) throws {
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: targetFolder.path)
            for file in files {
                let lower = file.lowercased()
                if lower.hasSuffix(".pdf") || lower.hasSuffix(".epub") {
                    let fileURL = targetFolder.appendingPathComponent(file)
                    let standardizedPath = fileURL.resolvingSymlinksInPath().standardized.path
                    if !excludedPaths.contains(standardizedPath) {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                }
            }
        } catch {
            logger.error("Failed to prepare folder for \(sourceKind) import: \(error.localizedDescription)")
            throw ImportError.folderCleanupFailed(targetFolder, underlying: error)
        }
    }
}
