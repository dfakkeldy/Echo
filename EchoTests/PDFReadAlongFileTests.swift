// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct PDFReadAlongFileTests {
    // MARK: - Fixture

    private struct SegmentSpec {
        var kind = "paragraph"
        var level: Int?
        var text: String
        var page: Int
        var printed = true
    }

    /// A read-along file whose printed words each get one box, laid out left to
    /// right on the segment's page.
    private func fileJSON(
        pageCount: Int, sha256: String? = nil, format: String = PDFReadAlongFile.formatName,
        version: Int = 1, segments: [SegmentSpec]
    ) -> Data {
        let segs: [[String: Any]] = segments.map { s in
            let words: [[String: Any]] =
                s.printed
                ? WordTokenizer.words(in: s.text).enumerated().map { i, _ in
                    ["p": s.page, "r": [[54.0 + Double(i) * 30, 700, 28, 12]]]
                } : []
            var d: [String: Any] = ["kind": s.kind, "text": s.text, "page": s.page, "words": words]
            if let level = s.level { d["level"] = level }
            return d
        }
        var pdf: [String: Any] = ["file": "book.pdf", "pageCount": pageCount]
        if let sha256 { pdf["sha256"] = sha256 }
        let doc: [String: Any] = [
            "format": format, "version": version, "pdf": pdf, "segments": segs,
        ]
        return try! JSONSerialization.data(withJSONObject: doc)
    }

    private let sampleSegments: [SegmentSpec] = [
        SegmentSpec(text: "The *Other* Side_of the Table.", page: 0),
        SegmentSpec(kind: "heading", level: 1, text: "Chapter 1. Opening notes", page: 0),
        SegmentSpec(text: "Words a stranger can check.", page: 0),
        SegmentSpec(text: "Pause here to write.", page: 0, printed: false),
        SegmentSpec(kind: "heading", level: 2, text: "Six seconds", page: 1),
        SegmentSpec(text: "In 2012, thirty recruiters.", page: 1),
        SegmentSpec(kind: "heading", level: 1, text: "Chapter 2. Closing notes", page: 2),
        SegmentSpec(text: "The end of the book.", page: 2),
    ]

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Decoding and validation

    @Test func validFileDecodesAndValidates() throws {
        let file = try PDFReadAlongFile.decode(fileJSON(pageCount: 3, segments: sampleSegments))
        try file.validate(pageCount: 3, pdfSHA256: nil)
        #expect(file.segments.count == sampleSegments.count)
        #expect(file.segments[3].words.isEmpty)
    }

    @Test func rejectsAnotherFormatOrVersion() throws {
        let other = try PDFReadAlongFile.decode(
            fileJSON(pageCount: 3, format: "something-else", segments: sampleSegments))
        #expect(throws: PDFReadAlongFile.Problem.wrongFormat("something-else")) {
            try other.validate(pageCount: 3, pdfSHA256: nil)
        }
        let newer = try PDFReadAlongFile.decode(
            fileJSON(pageCount: 3, version: 2, segments: sampleSegments))
        #expect(throws: PDFReadAlongFile.Problem.unsupportedVersion(2)) {
            try newer.validate(pageCount: 3, pdfSHA256: nil)
        }
    }

    @Test func rejectsAFileMadeForADifferentPDF() throws {
        let file = try PDFReadAlongFile.decode(
            fileJSON(pageCount: 3, sha256: String(repeating: "a", count: 64), segments: sampleSegments))
        #expect(throws: PDFReadAlongFile.Problem.pageCountMismatch(file: 3, pdf: 4)) {
            try file.validate(pageCount: 4, pdfSHA256: nil)
        }
        #expect(throws: PDFReadAlongFile.Problem.pdfChanged) {
            try file.validate(pageCount: 3, pdfSHA256: String(repeating: "b", count: 64))
        }
        try file.validate(pageCount: 3, pdfSHA256: String(repeating: "A", count: 64))
    }

    @Test func rejectsBoxesThatDontCoverEveryWord() throws {
        var json = try JSONSerialization.jsonObject(
            with: fileJSON(pageCount: 3, segments: sampleSegments)) as! [String: Any]
        var segs = json["segments"] as! [[String: Any]]
        var words = segs[2]["words"] as! [[String: Any]]
        words.removeLast()
        segs[2]["words"] = words
        json["segments"] = segs
        let file = try PDFReadAlongFile.decode(JSONSerialization.data(withJSONObject: json))
        #expect(throws: PDFReadAlongFile.Problem.wordCountMismatch(segment: 2, words: 5, boxes: 4)) {
            try file.validate(pageCount: 3, pdfSHA256: nil)
        }
    }

    @Test func rejectsPagesOutsideThePDF() throws {
        var segments = sampleSegments
        segments[7].page = 3
        let file = try PDFReadAlongFile.decode(fileJSON(pageCount: 3, segments: segments))
        #expect(throws: PDFReadAlongFile.Problem.pageOutOfRange(segment: 7)) {
            try file.validate(pageCount: 3, pdfSHA256: nil)
        }
    }

    @Test func sha256MatchesKnownDigest() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: url)
        #expect(
            try PDFReadAlongFile.sha256Hex(of: url)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func loadMatchingSkipsMissingAndMismatchedFiles() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdfURL = folder.appendingPathComponent("book.pdf")
        try Data("not really a pdf".utf8).write(to: pdfURL)
        let sha = try PDFReadAlongFile.sha256Hex(of: pdfURL)

        let stale = folder.appendingPathComponent("stale.readalong.json")
        try fileJSON(pageCount: 3, sha256: String(repeating: "0", count: 64), segments: sampleSegments)
            .write(to: stale)
        let good = PDFReadAlongFile.url(forPDF: pdfURL)
        try fileJSON(pageCount: 3, sha256: sha, segments: sampleSegments).write(to: good)

        let missing = folder.appendingPathComponent("missing.readalong.json")
        #expect(PDFReadAlongFile.loadMatching(pdfURL: pdfURL, candidates: [missing, stale], pageCount: 3) == nil)
        let found = PDFReadAlongFile.loadMatching(
            pdfURL: pdfURL, candidates: [missing, stale, good], pageCount: 3)
        #expect(found?.segments.count == sampleSegments.count)
        #expect(good.lastPathComponent == "book.readalong.json")
    }

    // MARK: - Blocks

    @Test func laidOutParseKeepsOneVerbatimBlockPerSegment() throws {
        let file = try PDFReadAlongFile.decode(fileJSON(pageCount: 3, segments: sampleSegments))
        let parse = parseLaidOutText(
            audiobookID: "book", units: file.units,
            sourceURL: URL(fileURLWithPath: "/tmp/book.pdf"))
        #expect(parse.blocks.map(\.text) == sampleSegments.map(\.text))
        #expect(parse.blocks[0].isFrontMatter)
        #expect(parse.blocks[1].blockKind == EPubBlockRecord.Kind.heading.rawValue)
        #expect(parse.blocks[4].blockKind == EPubBlockRecord.Kind.heading.rawValue)
        // Level-1 headings start chapters; the level-2 heading stays inside one.
        #expect(parse.blocks[1].spineIndex != parse.blocks[0].spineIndex)
        #expect(parse.blocks[4].spineIndex == parse.blocks[1].spineIndex)
        #expect(parse.blocks[6].spineIndex == parse.blocks[1].spineIndex + 1)
    }

    @Test func wordBoxesRoundTripThroughStorage() throws {
        let file = try PDFReadAlongFile.decode(fileJSON(pageCount: 3, segments: sampleSegments))
        let json = try #require(PDFReadAlongFile.encodeWordBoxes(file.segments[2].words))
        let words = try #require(PDFReadAlongFile.decodeWordBoxes(json))
        #expect(words == file.segments[2].words)
        let box = try #require(PDFWordBox(words[1]))
        #expect(box.pageIndex == 0)
        #expect(box.rects == [CGRect(x: 84, y: 700, width: 28, height: 12)])
        #expect(PDFReadAlongFile.encodeWordBoxes([]) == nil)
        #expect(PDFWordBox(PDFReadAlongFile.Word(p: 0, r: [])) == nil)
    }

    @Test func v44AddsWordBoxesColumn() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = PDFBlockPageDAO(db: db.writer)
        try dao.insert(
            PDFBlockPageRecord(
                id: nil, audiobookID: "b1", epubBlockID: "blk1", pageIndex: 2,
                wordBoxes: #"[{"p":2,"r":[[1,2,3,4]]}]"#))
        try dao.insert(PDFBlockPageRecord(id: nil, audiobookID: "b1", epubBlockID: "blk2", pageIndex: 2))
        let rows = try dao.rows(for: "b1").sorted { $0.epubBlockID < $1.epubBlockID }
        #expect(rows.map(\.wordBoxes) == [#"[{"p":2,"r":[[1,2,3,4]]}]"#, nil])
    }

    // MARK: - Import

    private func importFixture(sha256: (URL) throws -> String?) async throws
        -> (blocks: [EPubBlockRecord], pages: [PDFBlockPageRecord])
    {
        let db = try DatabaseService(inMemory: ())
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdfURL = try TestPDFFixture.threePagesWithoutChapterMarkers(in: folder)
        try fileJSON(pageCount: 3, sha256: sha256(pdfURL), segments: sampleSegments)
            .write(to: PDFReadAlongFile.url(forPDF: pdfURL))
        let audiobookID = folder.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 120)",
                arguments: [audiobookID])
        }
        _ = await PDFAutoImportScanner.importPDFFile(
            pdfURL: pdfURL, audiobookID: audiobookID, databaseService: db,
            chapters: [], duration: nil, force: true)
        let blocks = try EPubBlockDAO(db: db.writer).allBlocks(for: audiobookID)
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
        let pages = try PDFBlockPageDAO(db: db.writer).rows(for: audiobookID)
        return (blocks, pages)
    }

    @Test func importUsesTheReadAlongFileInsteadOfExtractedText() async throws {
        let result = try await importFixture { try PDFReadAlongFile.sha256Hex(of: $0) }
        #expect(result.blocks.map(\.text) == sampleSegments.map(\.text))
        #expect(!result.blocks.contains { ($0.text ?? "").contains("ordinary prose") })

        let pageByBlock = Dictionary(uniqueKeysWithValues: result.pages.map { ($0.epubBlockID, $0) })
        for (block, spec) in zip(result.blocks, sampleSegments) {
            let row = try #require(pageByBlock[block.id])
            #expect(row.pageIndex == spec.page)
            #expect((row.wordBoxes != nil) == spec.printed)
        }
    }

    @Test func importFallsBackToTextWhenTheFileIsForAnotherPDF() async throws {
        let result = try await importFixture { _ in String(repeating: "0", count: 64) }
        #expect(result.blocks.contains { ($0.text ?? "").contains("ordinary prose") })
        #expect(result.pages.allSatisfy { $0.wordBoxes == nil })
    }
}
