// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Imports a Markdown / plain-text file as an audio-less book's blocks, reusing
/// the shared `EPUBImportService.import(parse:)` persist phase and the shared
/// `DocumentImportFinalizer` tail. The text counterpart to
/// `EPUBAutoImportScanner.importEPUBFile`. The parent `audiobook` row must
/// already exist (loadFolder's `persistAudiobookToSQL` / the macOS batch path
/// creates it) — `epub_block` has a NOT-NULL FK to it.
enum TextAutoImportScanner {
    private static let logger = Logger(category: "TextAutoImportScanner")

    /// Markdown vs plain-text is chosen by extension.
    static func importTextFile(
        textURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        force: Bool = false
    ) async -> Bool {
        if !force {
            let alreadyImported =
                (try? EPubBlockDAO(db: databaseService.writer).visibleBlocks(for: audiobookID)
                    .isEmpty) == false
            if alreadyImported { return false }
        }

        do {
            let parse: EPUBBlockParse
            switch textURL.pathExtension.lowercased() {
            case "md", "markdown":
                parse = try parseMarkdownBlocks(audiobookID: audiobookID, fileURL: textURL)
            default:
                parse = try parsePlainTextBlocks(audiobookID: audiobookID, fileURL: textURL)
            }

            let importer = EPUBImportService(
                assetStorage: EPUBAssetStorage(databaseService: databaseService))
            let blocks = try await importer.import(
                parse: parse, audiobookID: audiobookID, chapters: [], bookDuration: nil,
                assetBaseURL: textURL.deletingLastPathComponent())
            logger.info("Imported \(blocks.count) text blocks for \(audiobookID)")

            return await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID, blocks: blocks, fileURL: textURL,
                duration: nil, databaseService: databaseService)
        } catch {
            logger.error("Text auto-import failed: \(error.localizedDescription)")
            return false
        }
    }
}
