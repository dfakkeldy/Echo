// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Portable JSON document describing an EPUB's visible source blocks using the
/// same content-stable `s<i>-b<j>` block ids as alignment sidecars
/// (`AlignmentSidecar.portableSuffix(of:)`), so external tooling can join
/// exported blocks against sidecar anchors. Consumed by `echo-cli export-blocks`.
nonisolated struct BlockExportDocument: Encodable {
    /// Bump when the JSON contract changes shape.
    static let currentVersion = 1

    struct Source: Encodable {
        let epub: String
    }

    struct Block: Encodable {
        let id: String
        let kind: String
        let text: String
        let chapterIndex: Int?
        let sequenceIndex: Int
        let wordCount: Int?
        /// Only meaningful for image blocks; encoded only when `kind == "image"`.
        let imagePath: String?

        init(record: EPubBlockRecord) {
            self.id = AlignmentSidecar.portableSuffix(of: record.id)
            self.kind = record.blockKind
            self.text = record.text ?? ""
            self.chapterIndex = record.chapterIndex
            self.sequenceIndex = record.sequenceIndex
            self.wordCount = record.wordCount
            self.imagePath =
                record.blockKind == EPubBlockRecord.Kind.image.rawValue ? record.imagePath : nil
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, text, chapterIndex, sequenceIndex, wordCount, imagePath
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encode(text, forKey: .text)
            // Deliberately `encode`, not `encodeIfPresent`: nil must appear as
            // JSON null (front-matter blocks legitimately have no chapter index).
            try container.encode(chapterIndex, forKey: .chapterIndex)
            try container.encode(sequenceIndex, forKey: .sequenceIndex)
            try container.encode(wordCount, forKey: .wordCount)
            if kind == EPubBlockRecord.Kind.image.rawValue {
                try container.encode(imagePath, forKey: .imagePath)
            }
        }
    }

    let version: Int
    let source: Source
    let blocks: [Block]

    init(epubName: String, records: [EPubBlockRecord]) {
        self.version = Self.currentVersion
        self.source = Source(epub: epubName)
        self.blocks =
            records
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
            .map(Block.init(record:))
    }

    /// Per-kind block counts for the CLI summary line.
    var kindCounts: (paragraphs: Int, headings: Int, sentences: Int, images: Int) {
        var paragraphs = 0
        var headings = 0
        var sentences = 0
        var images = 0
        for block in blocks {
            switch EPubBlockRecord.Kind(rawValue: block.kind) {
            case .paragraph: paragraphs += 1
            case .heading: headings += 1
            case .sentence: sentences += 1
            case .image: images += 1
            case nil: break
            }
        }
        return (paragraphs, headings, sentences, images)
    }
}
