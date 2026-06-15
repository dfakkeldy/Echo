import Foundation
import GRDB
import Testing

@testable import Echo

/// Phase A1 (CODE_AUDIT.md §5.1): the shared `parseEPUBBlocks` driver must be
/// the single source of truth for EPUB block IDs so that Mac-produced alignment
/// anchors resolve against the iOS database.
///
/// There is no macOS unit-test target, so we cannot diff the Mac parser against
/// the iOS importer directly. Instead these tests prove that `parseEPUBBlocks`
/// emits exactly the block IDs and text that `EPUBImportService.import()`
/// persists. Because both the iOS importer and the macOS aligner call this one
/// driver, Mac/iOS block-set parity then follows by construction.
@MainActor
struct EPUBBlockParserParityTests {

    /// Builds a fixture that exercises the only block-*set*-changing step the
    /// importer performs: the synthetic-heading insertion. `chapter2.xhtml` has
    /// a document `<title>` but no `<hN>` heading and a non-heading paragraph,
    /// so the importer prepends a synthetic "Morning" heading — shifting every
    /// subsequent block index in that spine. The old `MacEPUBParser` ignored
    /// this, guaranteeing divergent IDs.
    private func makeFixtureEPUB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let metaInf = tmp.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(
            to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata><dc:title>Test Book</dc:title></metadata>
          <manifest>
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """.write(to: tmp.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // Real heading + paragraphs + an image block.
        try """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter One</title></head>
        <body>
          <h1>Chapter One</h1>
          <p>It was a dark and stormy night.</p>
          <img src="images/scene.jpg"/>
          <p>The rain fell in torrents.</p>
        </body>
        </html>
        """.write(
            to: tmp.appendingPathComponent("chapter1.xhtml"), atomically: true, encoding: .utf8)

        // No <hN>; title comes from <title>, paragraph is not heading-like.
        // → importer inserts a synthetic "Morning" heading at block index 0.
        try """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Morning</title></head>
        <body>
          <p>The morning brought clear skies and a gentle breeze.</p>
          <p>Everyone felt the day would be a good one.</p>
        </body>
        </html>
        """.write(
            to: tmp.appendingPathComponent("chapter2.xhtml"), atomically: true, encoding: .utf8)

        return tmp
    }

    /// The shared driver's block IDs and text must equal, element-for-element,
    /// what the iOS importer writes to the DB (ordered by sequence index).
    @Test func parseEPUBBlocksMatchesImportedBlockIDsAndText() async throws {
        let db = try DatabaseService(inMemory: ())
        let epubDir = try makeFixtureEPUB()
        defer { try? FileManager.default.removeItem(at: epubDir) }

        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let service = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))
        _ = try await service.import(
            audiobookID: "book-1",
            epubURL: epubDir,
            chapters: [],
            bookDuration: nil
        )

        let dbBlocks = try EPubBlockDAO(db: db.writer).blocks(for: "book-1")
            .sorted { $0.sequenceIndex < $1.sequenceIndex }

        let parse = try parseEPUBBlocks(audiobookID: "book-1", epubURL: epubDir)

        #expect(parse.blocks.map(\.id) == dbBlocks.map(\.id))
        #expect(parse.blocks.map(\.text) == dbBlocks.map(\.text))
    }

    /// IDs must follow the iOS formula `epub-<audiobookID>-s<i>-b<j>` and be
    /// unique — this is the format Mac anchors must reproduce to resolve.
    @Test func parseEPUBBlocksEmitsIOSFormatUniqueIDs() async throws {
        let epubDir = try makeFixtureEPUB()
        defer { try? FileManager.default.removeItem(at: epubDir) }

        let parse = try parseEPUBBlocks(audiobookID: "book-1", epubURL: epubDir)

        #expect(!parse.blocks.isEmpty)
        for block in parse.blocks {
            #expect(block.id == "epub-book-1-s\(block.spineIndex)-b\(block.blockIndex)")
        }
        let ids = parse.blocks.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// The synthetic heading the importer inserts for a heading-less, titled
    /// spine must be present in the shared driver's output — this is precisely
    /// the block the old Mac parser dropped, causing every later anchor in that
    /// spine to reference the wrong block.
    @Test func parseEPUBBlocksIncludesSyntheticHeading() async throws {
        let epubDir = try makeFixtureEPUB()
        defer { try? FileManager.default.removeItem(at: epubDir) }

        let parse = try parseEPUBBlocks(audiobookID: "book-1", epubURL: epubDir)

        // chapter2 (spine index 1) first block is the synthetic "Morning" heading.
        let synthetic = try #require(parse.blocks.first { $0.id == "epub-book-1-s1-b0" })
        #expect(synthetic.text == "Morning")
        #expect(synthetic.blockKind == EPubBlockRecord.Kind.heading.rawValue)
    }
}
