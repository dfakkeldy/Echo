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

        #expect(document.version == 2)
        #expect(document.source.epub == "book.epub")
        let root = try encodedRoot(of: document)
        #expect(Set(root.keys) == ["blocks", "source", "version"])
        let source = try #require(root["source"] as? [String: Any])
        #expect(source["epub"] as? String == "book.epub")
        #expect(source["epubSHA256"] is NSNull)
        #expect(Set(source.keys) == ["epub", "epubSHA256"])
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

    @Test func bindsRegularEPUBExportsToExactFileBytes() throws {
        let epubURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-export-bytes-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: epubURL) }
        try Data([
            0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0xAF, 0xBE,
            0xEF, 0x00, 0x01, 0x02, 0x03,
        ]).write(to: epubURL)

        let resolved = try BlockExportSourceResolver.resolve(at: epubURL)
        let document = BlockExportDocument(
            epubName: resolved.epubName,
            epubSHA256: resolved.epubSHA256,
            records: [])
        let source = try encodedSource(of: document)

        #expect(source["epub"] as? String == epubURL.lastPathComponent)
        #expect(
            source["epubSHA256"] as? String
                == "e26d8566b08629bd81db1593023d05777307b6fb7173e2c56d4e0e41057b9574")
    }

    @Test func marksExpandedEPUBExportsAsNotFileBound() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "block-export-directory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let metaInfURL = directoryURL.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInfURL, withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(
            to: directoryURL.appendingPathComponent("mimetype"))
        try Data("<container/>".utf8).write(to: metaInfURL.appendingPathComponent("container.xml"))
        let resolved = try BlockExportSourceResolver.resolve(at: directoryURL)
        let document = BlockExportDocument(
            epubName: resolved.epubName,
            epubSHA256: resolved.epubSHA256,
            records: [])
        let source = try encodedSource(of: document)

        #expect(source["epub"] as? String == directoryURL.lastPathComponent)
        #expect(source["epubSHA256"] is NSNull)
    }

    private func encodedBlockObjects(of document: BlockExportDocument) throws -> [[String: Any]] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try #require(object as? [String: Any])
        return try #require(root["blocks"] as? [[String: Any]])
    }

    private func encodedSource(of document: BlockExportDocument) throws -> [String: Any] {
        let root = try encodedRoot(of: document)
        return try #require(root["source"] as? [String: Any])
    }

    private func encodedRoot(of document: BlockExportDocument) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
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
