// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import GRDB
@testable import Echo

/// Import-level tests for front-matter classification.
///
/// Spine items before the body-matter start (per EPUB 2 `<guide>` /
/// EPUB 3 landmarks / `linear="no"`) must be flagged `isFrontMatter` and must
/// never receive synthesized chapter headings from TOC labels or document
/// titles — that's how "Cover" and "Praise for…" pages became junk chapters.
@MainActor
struct EPUBFrontMatterImportTests {

    /// Builds an expanded EPUB directory: cover (linear="no") and praise page
    /// without headings, a real chapter, and an epilogue without a heading,
    /// with an NCX providing labels and a guide marking ch01 as body start.
    private func makeFrontMatterEPUB(includeGuide: Bool) throws -> URL {
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
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let guideXML = includeGuide ? """
          <guide>
            <reference type="cover" title="Cover" href="cover.xhtml"/>
            <reference type="text" title="Start" href="ch01.xhtml"/>
          </guide>
        """ : ""

        try """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata><dc:title>Test Book</dc:title></metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="praise" href="praise.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1" href="ch01.xhtml" media-type="application/xhtml+xml"/>
            <item id="epi" href="epilogue.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="cover" linear="no"/>
            <itemref idref="praise"/>
            <itemref idref="ch1"/>
            <itemref idref="epi"/>
          </spine>
        \(guideXML)
        </package>
        """.write(to: tmp.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1" playOrder="1">
              <navLabel><text>Cover</text></navLabel>
              <content src="cover.xhtml"/>
            </navPoint>
            <navPoint id="n2" playOrder="2">
              <navLabel><text>Praise for the second edition of Test Book</text></navLabel>
              <content src="praise.xhtml"/>
            </navPoint>
            <navPoint id="n3" playOrder="3">
              <navLabel><text>Chapter One</text></navLabel>
              <content src="ch01.xhtml"/>
            </navPoint>
            <navPoint id="n4" playOrder="4">
              <navLabel><text>Epilogue</text></navLabel>
              <content src="epilogue.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """.write(to: tmp.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Cover</title></head>
        <body><p>Test Book by Test Author</p></body>
        </html>
        """.write(to: tmp.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Praise for the second edition of Test Book</title></head>
        <body><p>An amazing book, said a reviewer.</p></body>
        </html>
        """.write(to: tmp.appendingPathComponent("praise.xhtml"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter One</title></head>
        <body>
          <h1>Chapter One</h1>
          <p>It was a dark and stormy night.</p>
        </body>
        </html>
        """.write(to: tmp.appendingPathComponent("ch01.xhtml"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Epilogue</title></head>
        <body><p>And they all lived happily ever after.</p></body>
        </html>
        """.write(to: tmp.appendingPathComponent("epilogue.xhtml"), atomically: true, encoding: .utf8)

        return tmp
    }

    private func importBlocks(includeGuide: Bool) async throws -> [EPubBlockRecord] {
        let db = try DatabaseService(inMemory: ())
        let epubDir = try makeFrontMatterEPUB(includeGuide: includeGuide)
        defer { try? FileManager.default.removeItem(at: epubDir) }

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let service = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))
        return try await service.import(
            audiobookID: "book-1",
            epubURL: epubDir,
            chapters: [],
            bookDuration: nil
        )
    }

    @Test func guideMarksSpinesBeforeBodyStartAsFrontMatter() async throws {
        let blocks = try await importBlocks(includeGuide: true)

        let coverBlocks = blocks.filter { $0.spineIndex == 0 }
        let praiseBlocks = blocks.filter { $0.spineIndex == 1 }
        let chapterBlocks = blocks.filter { $0.spineIndex == 2 }

        #expect(!coverBlocks.isEmpty && coverBlocks.allSatisfy { $0.isFrontMatter })
        #expect(!praiseBlocks.isEmpty && praiseBlocks.allSatisfy { $0.isFrontMatter })
        #expect(!chapterBlocks.isEmpty && chapterBlocks.allSatisfy { !$0.isFrontMatter })
    }

    @Test func frontMatterSpinesGetNoSynthesizedHeadings() async throws {
        let blocks = try await importBlocks(includeGuide: true)

        let headings = blocks.filter { $0.blockKind == EPubBlockRecord.Kind.heading.rawValue }
        #expect(!headings.contains { $0.text == "Cover" })
        #expect(!headings.contains { ($0.text ?? "").hasPrefix("Praise for") })
        #expect(headings.contains { $0.text == "Chapter One" })
    }

    @Test func bodyMatterWithoutHeadingStillGetsSynthesizedTitle() async throws {
        let blocks = try await importBlocks(includeGuide: true)

        let epilogueHeading = blocks.first {
            $0.spineIndex == 3 && $0.blockKind == EPubBlockRecord.Kind.heading.rawValue
        }
        #expect(epilogueHeading?.text == "Epilogue")
        #expect(epilogueHeading?.isFrontMatter == false)
    }

    @Test func withoutStructuralInfoNonContentTitlesStillClassifyLeadingSpines() async throws {
        let blocks = try await importBlocks(includeGuide: false)

        // cover.xhtml: linear="no" → structural front matter even without a guide.
        let coverBlocks = blocks.filter { $0.spineIndex == 0 }
        #expect(!coverBlocks.isEmpty && coverBlocks.allSatisfy { $0.isFrontMatter })

        // praise.xhtml: no structural signal, but its only available title
        // classifies as non-content and no content heading was seen yet.
        let praiseBlocks = blocks.filter { $0.spineIndex == 1 }
        #expect(!praiseBlocks.isEmpty && praiseBlocks.allSatisfy { $0.isFrontMatter })
        let headings = blocks.filter { $0.blockKind == EPubBlockRecord.Kind.heading.rawValue }
        #expect(!headings.contains { ($0.text ?? "").hasPrefix("Praise for") })

        // epilogue.xhtml: also titled via NCX only, but appears after body
        // content began — it keeps its synthesized heading and is not flagged.
        let epilogueHeading = blocks.first {
            $0.spineIndex == 3 && $0.blockKind == EPubBlockRecord.Kind.heading.rawValue
        }
        #expect(epilogueHeading?.text == "Epilogue")
        #expect(epilogueHeading?.isFrontMatter == false)
    }

    @Test func frontMatterFlagRoundTripsThroughDatabase() async throws {
        let db = try DatabaseService(inMemory: ())
        let epubDir = try makeFrontMatterEPUB(includeGuide: true)
        defer { try? FileManager.default.removeItem(at: epubDir) }

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let service = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))
        _ = try await service.import(audiobookID: "book-1", epubURL: epubDir, chapters: [], bookDuration: nil)

        let stored = try EPubBlockDAO(db: db.writer).blocks(for: "book-1")
        #expect(stored.contains { $0.isFrontMatter })
        #expect(stored.contains { !$0.isFrontMatter })
    }
}
