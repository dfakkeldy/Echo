// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CryptoKit
import Foundation
import os.log

/// A PDF's read-along file: `<pdf name>.readalong.json` beside the PDF, written
/// by the layout engine that made the PDF (the textbook-pdf `narration.py`).
///
/// It says what is narrated, in reading order, and where every spoken word sits
/// on the printed page. When it is present and matches the PDF, the importer
/// uses its segments as the book's blocks instead of PDFKit text extraction (so
/// running heads, page numbers and footers are never read), and the PDF reader
/// highlights each word's exact boxes instead of searching the page for it.
///
/// Contract (version 1): each segment's `text` splits into words exactly as
/// `WordTokenizer` does, and `words[i]` is that word's page (0-based) and
/// rectangles `[x, y, width, height]` in PDF page space (points, origin at the
/// page's bottom-left). A word with no rectangles is spoken but has no printed
/// box (a list number); a segment with no words is spoken only (an exercise cue).
nonisolated struct PDFReadAlongFile: Decodable, Sendable {
    static let formatName = "echo-pdf-readalong"
    static let supportedVersion = 1
    static let fileSuffix = ".readalong.json"

    nonisolated struct PDFInfo: Decodable, Sendable {
        let file: String?
        /// Lowercase hex SHA-256 of the PDF the file was made from.
        let sha256: String?
        let pageCount: Int
    }

    nonisolated struct Word: Codable, Equatable, Sendable {
        let p: Int?
        let r: [[Double]]
    }

    nonisolated struct Segment: Decodable, Sendable {
        let kind: String
        let level: Int?
        let text: String
        let page: Int
        let words: [Word]
    }

    nonisolated enum Problem: Error, Equatable {
        case wrongFormat(String)
        case unsupportedVersion(Int)
        case noSegments
        case pageCountMismatch(file: Int, pdf: Int)
        case pdfChanged
        case emptyText(segment: Int)
        case wordCountMismatch(segment: Int, words: Int, boxes: Int)
        case pageOutOfRange(segment: Int)
        case badRectangle(segment: Int)
    }

    let format: String
    let version: Int
    let pdf: PDFInfo
    let segments: [Segment]

    private static let logger = Logger(category: "PDFReadAlongFile")

    /// `<dir>/<pdf name without extension>.readalong.json`.
    static func url(forPDF pdfURL: URL) -> URL {
        pdfURL.deletingLastPathComponent().appendingPathComponent(
            pdfURL.deletingPathExtension().lastPathComponent + fileSuffix)
    }

    static func decode(_ data: Data) throws -> PDFReadAlongFile {
        try JSONDecoder().decode(PDFReadAlongFile.self, from: data)
    }

    /// Checks the file against the PDF it would be used with, and every segment
    /// against the word contract. `pdfSHA256` nil skips the identity check.
    func validate(pageCount: Int, pdfSHA256: String?) throws {
        guard format == Self.formatName else { throw Problem.wrongFormat(format) }
        guard version == Self.supportedVersion else { throw Problem.unsupportedVersion(version) }
        guard !segments.isEmpty else { throw Problem.noSegments }
        guard pdf.pageCount == pageCount else {
            throw Problem.pageCountMismatch(file: pdf.pageCount, pdf: pageCount)
        }
        if let expected = pdf.sha256, let actual = pdfSHA256,
            expected.lowercased() != actual.lowercased()
        {
            throw Problem.pdfChanged
        }
        let pages = 0..<pageCount
        for (i, segment) in segments.enumerated() {
            let wordCount = WordTokenizer.words(in: segment.text).count
            guard wordCount > 0 else { throw Problem.emptyText(segment: i) }
            guard pages.contains(segment.page) else { throw Problem.pageOutOfRange(segment: i) }
            guard segment.words.isEmpty || segment.words.count == wordCount else {
                throw Problem.wordCountMismatch(
                    segment: i, words: wordCount, boxes: segment.words.count)
            }
            for word in segment.words {
                if let p = word.p, !pages.contains(p) { throw Problem.pageOutOfRange(segment: i) }
                guard word.p != nil || word.r.isEmpty else {
                    throw Problem.pageOutOfRange(segment: i)
                }
                for rect in word.r where rect.count != 4 || !rect.allSatisfy(\.isFinite) {
                    throw Problem.badRectangle(segment: i)
                }
            }
        }
    }

    /// The segments as importer units, one per segment, in order.
    var units: [LaidOutTextUnit] {
        segments.map {
            LaidOutTextUnit(
                headingLevel: $0.kind == "heading" ? max(1, $0.level ?? 2) : nil, text: $0.text)
        }
    }

    /// Lowercase hex SHA-256 of a file's bytes.
    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The first existing candidate that decodes and matches the PDF, or nil.
    /// A file that exists but doesn't match is logged and skipped, so the PDF
    /// still imports through text extraction.
    static func loadMatching(pdfURL: URL, candidates: [URL], pageCount: Int) -> PDFReadAlongFile? {
        var seen = Set<String>()
        for url in candidates where seen.insert(url.standardizedFileURL.path).inserted {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let file = try decode(Data(contentsOf: url))
                let sha = file.pdf.sha256 == nil ? nil : try sha256Hex(of: pdfURL)
                try file.validate(pageCount: pageCount, pdfSHA256: sha)
                return file
            } catch {
                logger.error(
                    "Ignoring read-along file \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return nil
    }

    // MARK: - iCloud

    /// Where iCloud keeps `url` while only its placeholder is on the device:
    /// `<dir>/.<name>.icloud`. The logical file doesn't exist until it downloads.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    /// True when `url` is on disk or iCloud holds it as a placeholder.
    static func isPresent(_ url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || fileManager.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// Downloads `url` when iCloud holds only a placeholder, waiting up to
    /// `timeout`; true once the file is local. A file outside iCloud returns
    /// whether it exists. Echo can open a book's folder as soon as the PDF is
    /// local, while this file is still in the cloud; `loadMatching` checks only
    /// for a file on disk, so without this the PDF imports through text
    /// extraction instead.
    static func downloadIfNeeded(
        _ url: URL, timeout: Duration = .seconds(30), fileManager: FileManager = .default
    ) async -> Bool {
        guard isPresent(url, fileManager: fileManager) else { return false }
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        if values?.isUbiquitousItem != true, fileManager.fileExists(atPath: url.path) {
            return true
        }
        if values?.ubiquitousItemDownloadingStatus == .current { return true }
        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            logger.error(
                "Could not download read-along file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return false }
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if status == .current { return true }
        }
        logger.info(
            "Read-along file \(url.lastPathComponent, privacy: .public) didn't download in time")
        return false
    }

    // MARK: - Stored word boxes (`pdf_block_page.word_boxes`)

    /// Encodes one segment's words for storage; nil when the segment has none.
    static func encodeWordBoxes(_ words: [Word]) -> String? {
        guard !words.isEmpty, let data = try? JSONEncoder().encode(words) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeWordBoxes(_ json: String) -> [Word]? {
        try? JSONDecoder().decode([Word].self, from: Data(json.utf8))
    }
}

/// Where one spoken word is printed: its page and its boxes in PDF page space.
/// A hyphenated word broken across two lines has two boxes.
nonisolated struct PDFWordBox: Equatable, Sendable {
    let pageIndex: Int
    let rects: [CGRect]

    init?(_ word: PDFReadAlongFile.Word) {
        guard let page = word.p, !word.r.isEmpty else { return nil }
        pageIndex = page
        rects = word.r.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    }
}
