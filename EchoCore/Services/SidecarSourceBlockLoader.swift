// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Loads source text blocks for estimated alignment sidecar generation using the
/// same EPUB/PDF import stack as Echo's reader and headless narration pipeline.
@MainActor
enum SidecarSourceBlockLoader {
    enum SourceError: Error, Equatable, LocalizedError {
        case missingSource(URL)
        case unsupportedSource(URL)
        case noBlocksImported(String)

        var errorDescription: String? {
            switch self {
            case .missingSource(let url):
                return "No EPUB or PDF source was found at: \(url.path)"
            case .unsupportedSource(let url):
                return "Unsupported sidecar source: \(url.path)"
            case .noBlocksImported(let name):
                return "No readable text blocks were imported for: \(name)"
            }
        }
    }

    private enum SourceKind {
        case expandedEPUB(URL)
        case epubFile(URL)
        case pdf(URL)

        var sourceURL: URL {
            switch self {
            case .expandedEPUB(let url), .epubFile(let url), .pdf(let url):
                return url
            }
        }
    }

    static func blocks(
        from sourceURL: URL,
        audiobookID: String? = nil
    ) async throws -> [EPubBlockRecord] {
        let source = try resolveSource(at: sourceURL)
        let resolvedAudiobookID = audiobookID ?? defaultAudiobookID(for: source.sourceURL)
        let shouldCleanupTransientFiles = audiobookID == nil
        defer {
            if shouldCleanupTransientFiles {
                cleanupTransientFiles(audiobookID: resolvedAudiobookID)
            }
        }

        let database = try DatabaseService(inMemory: ())
        try database.write { db in
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO audiobook (id, title, duration, added_at) VALUES (?, ?, 0, '2026-01-01T00:00:00Z')",
                arguments: [resolvedAudiobookID, source.sourceURL.deletingPathExtension().lastPathComponent]
            )
        }

        let blocks: [EPubBlockRecord]
        switch source {
        case .expandedEPUB(let epubURL):
            let importer = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: database))
            blocks = try await importer.import(
                audiobookID: resolvedAudiobookID,
                epubURL: epubURL,
                chapters: [],
                bookDuration: nil
            )
        case .epubFile(let epubURL):
            let didImport = await EPUBAutoImportScanner.importEPUBFile(
                epubURL: epubURL,
                audiobookID: resolvedAudiobookID,
                databaseService: database,
                chapters: [],
                duration: nil,
                force: true
            )
            guard didImport else {
                throw SourceError.noBlocksImported(epubURL.lastPathComponent)
            }
            blocks = try EPubBlockDAO(db: database.writer).visibleBlocks(for: resolvedAudiobookID)
        case .pdf(let pdfURL):
            let didImport = await PDFAutoImportScanner.importPDFFile(
                pdfURL: pdfURL,
                audiobookID: resolvedAudiobookID,
                databaseService: database,
                chapters: [],
                duration: nil,
                force: true
            )
            guard didImport else {
                throw SourceError.noBlocksImported(pdfURL.lastPathComponent)
            }
            blocks = try EPubBlockDAO(db: database.writer).visibleBlocks(for: resolvedAudiobookID)
        }

        guard !blocks.isEmpty else {
            throw SourceError.noBlocksImported(source.sourceURL.lastPathComponent)
        }
        return blocks
    }

    static func defaultAudiobookID(for sourceURL: URL) -> String {
        "sidecar-\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)"
    }

    private static func resolveSource(at sourceURL: URL) throws -> SourceKind {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw SourceError.missingSource(sourceURL)
        }

        if isDirectory.boolValue {
            if isExpandedEPUB(sourceURL) {
                return .expandedEPUB(sourceURL)
            }

            let entries = try fm.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }

            if let epubURL = entries.first(where: { $0.pathExtension.lowercased() == "epub" }) {
                return .epubFile(epubURL)
            }
            if let pdfURL = entries.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                return .pdf(pdfURL)
            }
            throw SourceError.missingSource(sourceURL)
        }

        switch sourceURL.pathExtension.lowercased() {
        case "epub":
            return .epubFile(sourceURL)
        case "pdf":
            return .pdf(sourceURL)
        default:
            throw SourceError.unsupportedSource(sourceURL)
        }
    }

    private static func isExpandedEPUB(_ sourceURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: sourceURL.appendingPathComponent("META-INF/container.xml").path
        )
            && FileManager.default.fileExists(
                atPath: sourceURL.appendingPathComponent("mimetype").path
            )
    }

    private static func cleanupTransientFiles(audiobookID: String) {
        let safeID = SafeFileName.fromAudiobookID(audiobookID)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at:
                    caches
                    .appendingPathComponent("EPUBUnpacked", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true)
            )
        }
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            try? FileManager.default.removeItem(
                at:
                    appSupport
                    .appendingPathComponent("EPUBAssets", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true)
            )
        }
    }
}
