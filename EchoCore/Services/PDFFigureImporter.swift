// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os

/// A figure's stable, portable anchor + its stored image path, for deck authoring.
struct FigureManifestEntry: Codable, Sendable {
    let pageIndex: Int
    let portableAnchor: String  // s<i>-b<j>
    let imagePath: String
}

/// Persists extracted PDF figures as first-class `epub_block` image blocks
/// (text == nil → silent to narration; image_path set → renderable) and a
/// `pdf_block_page` row each. Returns a manifest for deck authoring.
///
/// All figures land in a synthetic spine `s<maxSpine+1>`, one past the highest
/// spine index among the PDF's text blocks, so figure block IDs never collide
/// with text block IDs.
enum PDFFigureImporter {
    private static let logger = Logger(category: "PDFFigureImporter")

    static func importFigures(
        _ figures: [ExtractedFigure],
        audiobookID: String,
        textBlocks: [EPubBlockRecord],
        pageMapping: [(blockID: String, pageIndex: Int)],
        databaseService: DatabaseService
    ) -> [FigureManifestEntry] {
        guard !figures.isEmpty else { return [] }
        let storage = EPUBAssetStorage(databaseService: databaseService)
        let figureSpine = (textBlocks.map(\.spineIndex).max() ?? 0) + 1

        // page -> chapterIndex, inherited from a text block on that page.
        var chapterByPage: [Int: Int] = [:]
        let chapterByBlockID = Dictionary(
            uniqueKeysWithValues: textBlocks.map { ($0.id, $0.chapterIndex) })
        for m in pageMapping where chapterByPage[m.pageIndex] == nil {
            if let chapter = chapterByBlockID[m.blockID] ?? nil {
                chapterByPage[m.pageIndex] = chapter
            }
        }

        var manifest: [FigureManifestEntry] = []
        var rows: [EPubBlockRecord] = []
        var pageRows: [PDFBlockPageRecord] = []
        for (ordinal, fig) in figures.enumerated() {
            let filename = "figure-p\(fig.pageIndex)-o\(fig.order).png"
            guard
                let path = storage.writeImageData(
                    fig.pngData, audiobookID: audiobookID, filename: filename)
            else { continue }
            let blockID = "epub-\(audiobookID)-s\(figureSpine)-b\(ordinal)"
            rows.append(
                EPubBlockRecord(
                    id: blockID, audiobookID: audiobookID, spineHref: "pdf-figures",
                    spineIndex: figureSpine, blockIndex: ordinal,
                    sequenceIndex: 1_000_000 + ordinal,
                    blockKind: EPubBlockRecord.Kind.image.rawValue, text: nil, htmlContent: nil,
                    cardColor: nil, chapterThemeColor: nil, imagePath: path,
                    chapterIndex: chapterByPage[fig.pageIndex], isHidden: false, hiddenReason: nil,
                    isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
                    narrationText: nil, createdAt: nil, modifiedAt: nil))
            pageRows.append(
                PDFBlockPageRecord(
                    id: nil, audiobookID: audiobookID, epubBlockID: blockID,
                    pageIndex: fig.pageIndex))
            manifest.append(
                FigureManifestEntry(
                    pageIndex: fig.pageIndex, portableAnchor: "s\(figureSpine)-b\(ordinal)",
                    imagePath: path))
        }

        guard !rows.isEmpty else { return [] }

        do {
            try databaseService.writer.write { db in
                for var row in rows { try row.insert(db) }
                for var pageRow in pageRows { try pageRow.insert(db) }
            }
        } catch {
            logger.error("Failed to persist figure blocks: \(error.localizedDescription)")
            return []
        }
        return manifest
    }
}
