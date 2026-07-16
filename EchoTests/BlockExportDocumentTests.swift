// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct BlockExportDocumentTests {
    @Test func mapsRecordsToPortableIDsSortedBySequenceIndexAndCarriesTheSourceSignature() throws {
        let records = [
            block(spine: 1, index: 0, sequence: 2, kind: .paragraph, text: "Second"),
            block(
                spine: 0, index: 0, sequence: 0, kind: .heading, text: "Title",
                isFrontMatter: true),
            block(spine: 0, index: 1, sequence: 1, kind: .sentence, text: "First"),
        ]
        let document = BlockExportDocument(epubName: "book.epub", records: records)

        #expect(document.version == 2)
        #expect(document.source.epub == "book.epub")
        #expect(document.blocks.map(\.id) == ["s0-b0", "s0-b1", "s1-b0"])
        #expect(document.blocks.map(\.kind) == ["heading", "sentence", "paragraph"])
        #expect(document.blocks.map(\.sequenceIndex) == [0, 1, 2])
        #expect(document.blocks.map(\.isFrontMatter) == [true, false, false])
        #expect(document.sourceSignature == EchoSourceSignature.make(records: records))
        let counts = document.kindCounts
        #expect(counts == (paragraphs: 1, headings: 1, sentences: 1, images: 0))
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
        #expect(json[0]["isFrontMatter"] as? Bool == false)
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

    @Test func imageBlocksRemainInExportRegardlessOfHiddenOrFrontMatterState() throws {
        // A hidden, front-matter cover image (the common real-world shape) must
        // still round-trip into the export: `BlockExportDocument` is a portable
        // snapshot, not a feed-display filter — mutable reader state like
        // `isHidden` is for the app UI, not for what a deck importer sees.
        let document = BlockExportDocument(
            epubName: "book.epub",
            records: [
                block(
                    spine: 0, index: 0, sequence: 0, kind: .image, text: "Cover",
                    chapterIndex: nil, wordCount: nil, imagePath: "OEBPS/cover.png",
                    isFrontMatter: true, isHidden: true),
                block(
                    spine: 0, index: 1, sequence: 1, kind: .paragraph, text: "Prose",
                    chapterIndex: 0, wordCount: 1),
            ]
        )

        #expect(document.blocks.count == 2)
        #expect(document.blocks[0].kind == "image")
        #expect(document.blocks[0].imagePath == "OEBPS/cover.png")
        #expect(document.blocks[0].isFrontMatter == true)
    }

    @Test func signatureIsStableAcrossVolatileExportFields() throws {
        // Same canonical content, different device-local/mutable state: audiobook
        // id, chapter assignment, hidden flag, image storage path, and even the
        // epub filename used for `source.epub`. The signature must agree so two
        // devices exporting the "same" book produce a joinable deck.
        let recordsOnMac = [
            block(
                spine: 0, index: 0, sequence: 0, kind: .heading, text: "Title",
                chapterIndex: 0, wordCount: 1, audiobookID: "device-mac"),
            block(
                spine: 0, index: 1, sequence: 1, kind: .image, text: "Caption",
                chapterIndex: 0, wordCount: nil, imagePath: "OEBPS/a.png",
                isFrontMatter: false, isHidden: false, audiobookID: "device-mac"),
        ]
        let recordsOnPhone = [
            block(
                spine: 0, index: 0, sequence: 0, kind: .heading, text: "Title",
                chapterIndex: 3, wordCount: 1, audiobookID: "device-phone"),
            block(
                spine: 0, index: 1, sequence: 1, kind: .image, text: "Caption",
                chapterIndex: 9, wordCount: nil,
                imagePath: "Library/Application Support/EPUBAssets/different/b.png",
                isFrontMatter: false, isHidden: true, audiobookID: "device-phone"),
        ]

        let documentOnMac = BlockExportDocument(epubName: "book-mac.epub", records: recordsOnMac)
        let documentOnPhone = BlockExportDocument(
            epubName: "book-phone.epub", records: recordsOnPhone)

        #expect(documentOnMac.sourceSignature == documentOnPhone.sourceSignature)
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
        imagePath: String? = nil,
        isFrontMatter: Bool = false,
        isHidden: Bool = false,
        audiobookID: String = "book"
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-\(audiobookID)-s\(spine)-b\(index)",
            audiobookID: audiobookID,
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
            isHidden: isHidden,
            hiddenReason: isHidden ? "user" : nil,
            isFrontMatter: isFrontMatter,
            wordCount: wordCount,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}
