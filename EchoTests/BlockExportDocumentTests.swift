// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct BlockExportDocumentTests {
    @Test func mapsRecordsToPortableIDsSortedBySequenceIndex() throws {
        let document = BlockExportDocument(
            epubName: "book.epub",
            records: [
                block(spine: 1, index: 0, sequence: 2, kind: .paragraph, text: "Second"),
                block(spine: 0, index: 0, sequence: 0, kind: .heading, text: "Title"),
                block(spine: 0, index: 1, sequence: 1, kind: .sentence, text: "First"),
                block(spine: 1, index: 1, sequence: 3, kind: .code, text: "print(\"Hi\")"),
            ]
        )

        #expect(document.version == 1)
        #expect(document.source.epub == "book.epub")
        #expect(document.blocks.map(\.id) == ["s0-b0", "s0-b1", "s1-b0", "s1-b1"])
        #expect(document.blocks.map(\.kind) == ["heading", "sentence", "paragraph", "code"])
        #expect(document.blocks.map(\.sequenceIndex) == [0, 1, 2, 3])
        let counts = document.kindCounts
        #expect(counts == (paragraphs: 1, headings: 1, sentences: 1, images: 0, code: 1))
    }

    @Test func encodesNilChapterIndexAndWordCountAsNull() throws {
        let document = BlockExportDocument(
            epubName: "book.epub",
            records: [
                block(
                    spine: 0, index: 0, sequence: 0, kind: .paragraph, text: nil,
                    chapterIndex: nil, wordCount: nil)
            ]
        )

        let json = try encodedBlockObjects(of: document)
        #expect(json.count == 1)
        #expect(json[0]["text"] as? String == "")
        #expect(json[0]["chapterIndex"] is NSNull)
        #expect(json[0]["wordCount"] is NSNull)
        #expect(json[0]["imagePath"] == nil)
    }

    @Test func encodesImagePathOnlyForImageBlocks() throws {
        let document = BlockExportDocument(
            epubName: "book.epub",
            records: [
                block(
                    spine: 0, index: 0, sequence: 0, kind: .image, text: "A caption",
                    chapterIndex: 0, wordCount: 2, imagePath: "OEBPS/x.png"),
                block(
                    spine: 0, index: 1, sequence: 1, kind: .paragraph, text: "Prose",
                    chapterIndex: 0, wordCount: 1, imagePath: "OEBPS/ignored.png"),
            ]
        )

        let json = try encodedBlockObjects(of: document)
        #expect(json.count == 2)
        #expect(json[0]["imagePath"] as? String == "OEBPS/x.png")
        #expect(json[0]["text"] as? String == "A caption")
        #expect(json[0]["chapterIndex"] as? Int == 0)
        #expect(json[1]["imagePath"] == nil)
        #expect(json[1]["wordCount"] as? Int == 1)
    }

    private func encodedBlockObjects(of document: BlockExportDocument) throws -> [[String: Any]] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try #require(object as? [String: Any])
        return try #require(root["blocks"] as? [[String: Any]])
    }

    private func block(
        spine: Int,
        index: Int,
        sequence: Int,
        kind: EPubBlockRecord.Kind,
        text: String?,
        chapterIndex: Int? = 0,
        wordCount: Int? = 1,
        imagePath: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-book-s\(spine)-b\(index)",
            audiobookID: "book",
            spineHref: "ch\(spine).xhtml",
            spineIndex: spine,
            blockIndex: index,
            sequenceIndex: sequence,
            blockKind: kind.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: chapterIndex,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: wordCount,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}
