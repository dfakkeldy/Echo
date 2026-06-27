// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PDFKit
import os.log

/// Imports a PDF's extracted text into the same EPUB block pipeline used for EPUB
/// and text documents.
enum PDFAutoImportScanner {
    private static let logger = Logger(category: "PDFAutoImport")
    private struct ExtractedText: Sendable {
        let pages: [String]

        var body: String {
            pages.joined(separator: "\n\n")
        }
    }

    enum ImportOutcome {
        case imported
        case alreadyImported
        case noReadableText(URL)
        case unreadable(URL, underlying: Error)
        case failed(URL, underlying: Error)

        var didImportBlocks: Bool {
            if case .imported = self { return true }
            return false
        }
    }

    /// Scans the given audiobook folder for `.pdf` files. When one is found and no
    /// prior import exists for the folder, the text is extracted and imported via
    /// `EPUBImportService.import(parse:)`.
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

        // 1. Scan for .pdf files in the folder.
        let pdfFiles: [URL]
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
            pdfFiles = contents.filter { $0.pathExtension.lowercased() == "pdf" }
        } catch {
            logger.warning(
                "Cannot scan folder for PDF files: \(sanitizedPath(targetURL.path)) — \(error.localizedDescription)"
            )
            return false
        }

        guard let pdfURL = pdfFiles.first else {
            logger.debug("No .pdf file found in folder: \(sanitizedPath(folderURL.path))")
            return false
        }

        logger.info("Found PDF file: \(sanitizedPath(pdfURL.lastPathComponent))")

        return await importPDFFile(
            pdfURL: pdfURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: false
        )
    }

    /// Imports a specific PDF file for an audiobook, extracting and parsing the
    /// text content from its pages.
    @discardableResult
    static func importPDFFile(
        pdfURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?,
        force: Bool = false,
        finalizerFileURL: URL? = nil
    ) async -> Bool {
        let outcome = await importPDFFileOutcome(
            pdfURL: pdfURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: force,
            finalizerFileURL: finalizerFileURL
        )
        return outcome.didImportBlocks
    }

    static func importPDFFileOutcome(
        pdfURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?,
        force: Bool = false,
        finalizerFileURL: URL? = nil
    ) async -> ImportOutcome {
        // Security-scoped access is managed by SecurityScopeManager in loadFolder.
        // Don't start/stop here — duplicate cycles break file-provider access.

        // Skip import when text is already present.
        if !force {
            let alreadyImported =
                (try? EPubBlockDAO(db: databaseService.writer).visibleBlocks(for: audiobookID)
                    .isEmpty) == false
            if alreadyImported {
                logger.debug(
                    "PDF text blocks already exist for \(sanitizedPath(audiobookID)); skipping auto-import."
                )
                return .alreadyImported
            }
        }

        do {
            // PDF text extraction (PDFDocument(url:) + per-page .string) is a
            // synchronous, potentially expensive CPU pass with no suspension
            // points. Under this target's default-MainActor isolation it would
            // otherwise run on the main thread and hang the UI for large PDFs, so
            // hop it onto the cooperative pool. Only the Sendable [String] page
            // text crosses back — no PDFKit object leaves the detached task.
            let extractedText = try await Task.detached(priority: .userInitiated) {
                try Self.extractText(from: pdfURL)
            }.value
            let sourceText = extractedText.body
            guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.info(
                    "Skipping PDF import because no readable text was extracted: \(sanitizedPath(pdfURL.path))"
                )
                return .noReadableText(pdfURL)
            }

            let parse = parsePDFText(
                audiobookID: audiobookID,
                extractedText: extractedText,
                sourceURL: pdfURL)
            let importer = EPUBImportService(
                assetStorage: EPUBAssetStorage(databaseService: databaseService))
            let blocks = try await importer.import(
                parse: parse,
                audiobookID: audiobookID,
                chapters: chapters,
                bookDuration: duration,
                assetBaseURL: pdfURL.deletingLastPathComponent()
            )
            logger.info("Imported \(blocks.count) PDF blocks for \(sanitizedPath(audiobookID))")

            let finalized = await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID, blocks: blocks, fileURL: finalizerFileURL ?? pdfURL,
                duration: duration, databaseService: databaseService)
            if finalized {
                // Record each block's source page index (page mode auto-follow).
                // try? so capture failure never aborts a successful import.
                let mapping = PDFBlockPageMapper.map(
                    blocks: blocks.map { (id: $0.id, text: $0.text ?? "") },
                    pages: extractedText.pages)
                let dao = PDFBlockPageDAO(db: databaseService.writer)
                try? dao.deleteAll(for: audiobookID)
                try? dao.insertAll(
                    mapping.map {
                        PDFBlockPageRecord(
                            id: nil, audiobookID: audiobookID, epubBlockID: $0.blockID,
                            pageIndex: $0.pageIndex)
                    })
                return .imported
            }
            return .failed(pdfURL, underlying: PDFAutoImportError.finalizationFailed(pdfURL))
        } catch let error as PDFAutoImportError {
            logger.error("PDF auto-import failed: \(error.localizedDescription)")
            switch error {
            case .unreadable(let url):
                return .unreadable(url, underlying: error)
            case .noText(let url):
                return .noReadableText(url)
            case .finalizationFailed(let url):
                return .failed(url, underlying: error)
            }
        } catch {
            logger.error("PDF auto-import failed: \(error.localizedDescription)")
            return .failed(pdfURL, underlying: error)
        }
    }

    /// Extracts readable text from each page in the PDF.
    private static func parsePDFText(
        audiobookID: String,
        extractedText: ExtractedText,
        sourceURL: URL
    ) -> EPUBBlockParse {
        let naturalParse = parsePlainText(
            audiobookID: audiobookID,
            content: extractedText.body,
            sourceURL: sourceURL)

        guard
            shouldUseSyntheticPageChapters(
                for: naturalParse,
                pageCount: extractedText.pages.count)
        else {
            return naturalParse
        }

        logger.info(
            "PDF has no usable chapter markers; using \(extractedText.pages.count) page-based narration chapters."
        )
        return parsePDFPagesAsPlainTextChapters(
            audiobookID: audiobookID,
            pages: extractedText.pages,
            sourceURL: sourceURL)
    }

    private static func shouldUseSyntheticPageChapters(
        for parse: EPUBBlockParse,
        pageCount: Int
    ) -> Bool {
        guard pageCount > 1 else { return false }
        let bodySpines = Set(parse.blocks.filter { !$0.isFrontMatter }.map(\.spineIndex))
        let spines = bodySpines.isEmpty ? Set(parse.blocks.map(\.spineIndex)) : bodySpines
        return spines.count <= 1
    }

    /// `nonisolated` so it can run off the main actor inside a detached task
    /// (see `importPDFFile`); it touches only PDFKit and local state.
    private nonisolated static func extractText(from pdfURL: URL) throws -> ExtractedText {
        guard let document = PDFDocument(url: pdfURL) else {
            throw PDFAutoImportError.unreadable(pdfURL)
        }

        let pages = (0..<document.pageCount).compactMap { pageIndex -> String? in
            guard let raw = document.page(at: pageIndex)?.string else { return nil }
            // Preserve line breaks. The downstream tokenizer reflows consecutive
            // non-blank lines back into paragraphs (so PDF hard-wraps within a
            // paragraph are rejoined) but inspects each line individually for
            // chapter markers — so a standalone "Chapter 1" line is still
            // promoted to a heading. Flattening every page to one line (the prior
            // behavior) hid all in-page chapter markers.
            let page = raw.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !page.isEmpty else { return nil }
            return page
        }

        if pages.isEmpty {
            throw PDFAutoImportError.noText(pdfURL)
        }

        return ExtractedText(pages: pages)
    }

    /// Sanitizes a filesystem path for safe logging.
    // `nonisolated`: pure string helper called from `PDFAutoImportError.errorDescription`,
    // a `nonisolated` `LocalizedError` requirement. Under the iOS target's Swift 6
    // MainActor default isolation the enclosing enum (and thus this static) is inferred
    // `@MainActor`, which the nonisolated error path cannot call. (Same fix as SafeFileName.)
    private nonisolated static func sanitizedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private enum PDFAutoImportError: LocalizedError, Sendable {
        case unreadable(URL)
        case noText(URL)
        case finalizationFailed(URL)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                return "Cannot open PDF: \(PDFAutoImportScanner.sanitizedPath(url.path))"
            case .noText(let url):
                return
                    "No readable text found in PDF: \(PDFAutoImportScanner.sanitizedPath(url.path))"
            case .finalizationFailed(let url):
                return
                    "Could not save PDF text import: \(PDFAutoImportScanner.sanitizedPath(url.path))"
            }
        }
    }
}
