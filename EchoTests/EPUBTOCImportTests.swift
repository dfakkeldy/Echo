import Testing
import Foundation
import GRDB
@testable import Echo

/// Import-level tests for hierarchical TOC persistence.
///
/// The importer must persist the NCX tree as `epub_toc_entry` rows, resolve
/// each entry to a concrete block via spine href + fragment anchors, and
/// promote fragment targets that aren't `<h1>`–`<h6>` (table-marked topic
/// titles) to heading blocks so the reader styles and navigates them.
@MainActor
struct EPUBTOCImportTests {

    /// A miniature Pragmatic Programmer: a foreword, a chapter opener whose
    /// title is split across spans + <br/>, and a topic file whose title is a
    /// layout table (not a heading tag) with an h3 subsection.
    private func makeHierarchicalEPUB() throws -> URL {
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

        try """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata><dc:title>Test Book</dc:title></metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="fw" href="foreword.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1" href="ch01.xhtml" media-type="application/xhtml+xml"/>
            <item id="t3" href="topic03.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="fw"/>
            <itemref idref="ch1"/>
            <itemref idref="t3"/>
          </spine>
          <guide>
            <reference type="text" title="Start" href="foreword.xhtml"/>
          </guide>
        </package>
        """.write(to: tmp.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="n1" playOrder="1">
              <navLabel><text>Foreword</text></navLabel>
              <content src="foreword.xhtml#fw_anchor"/>
            </navPoint>
            <navPoint id="n2" playOrder="2">
              <navLabel><text>1. A Pragmatic Philosophy</text></navLabel>
              <content src="ch01.xhtml#ch1_anchor"/>
              <navPoint id="n3" playOrder="3">
                <navLabel><text>Topic 3. Software Entropy</text></navLabel>
                <content src="topic03.xhtml#t3_anchor"/>
              </navPoint>
            </navPoint>
          </navMap>
        </ncx>
        """.write(to: tmp.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Foreword</title></head>
        <body>
          <h1 class="chapter-title" id="fw_anchor"><span class="chapter-number"/><br/><span class="chapter-name">Foreword</span></h1>
          <p>I remember when Dave and Andy first tweeted about this book.</p>
        </body>
        </html>
        """.write(to: tmp.appendingPathComponent("foreword.xhtml"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body>
          <h1 class="chapter-title" id="ch1_anchor"><span class="chapter-number">Chapter
             1</span><br/><span class="chapter-name">A Pragmatic Philosophy</span></h1>
          <p>This book is about you.</p>
        </body>
        </html>
        """.write(to: tmp.appendingPathComponent("ch01.xhtml"), atomically: true, encoding: .utf8)

        try """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Topic 3</title></head>
        <body>
        <table class="arr-recipe" id="t3_anchor"><tr><td class="arr-recipe-number"><div class="arrow-right"><span class="topic-label">Topic 3</span></div></td><td class="arr-recipe-name">Software Entropy</td></tr></table>
        <p>While software development is immune from almost all physical laws, entropy hits us hard.</p>
        <h3>Challenges</h3>
        <p>How do you react when someone comes to you with a lame excuse?</p>
        </body>
        </html>
        """.write(to: tmp.appendingPathComponent("topic03.xhtml"), atomically: true, encoding: .utf8)

        return tmp
    }

    private func runImport() async throws -> (db: DatabaseService, blocks: [EPubBlockRecord]) {
        let db = try DatabaseService(inMemory: ())
        let epubDir = try makeHierarchicalEPUB()
        defer { try? FileManager.default.removeItem(at: epubDir) }

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let service = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))
        let blocks = try await service.import(
            audiobookID: "book-1",
            epubURL: epubDir,
            chapters: [],
            bookDuration: nil
        )
        return (db, blocks)
    }

    @Test func tocEntriesPersistWithHierarchyAndNCXTitles() async throws {
        let (db, _) = try await runImport()
        let entries = try EPubTOCEntryDAO(db: db.writer).entries(for: "book-1")

        let roots = entries.filter { $0.parentID == nil }.sorted { $0.orderIndex < $1.orderIndex }
        #expect(roots.map(\.title) == ["Foreword", "1. A Pragmatic Philosophy"])

        let chapter = try #require(roots.last)
        let children = entries.filter { $0.parentID == chapter.id }
        #expect(children.map(\.title) == ["Topic 3. Software Entropy"])
        #expect(children.first?.depth == 1)
    }

    @Test func tocEntriesResolveToBlocksViaFragmentAnchors() async throws {
        let (db, blocks) = try await runImport()
        let entries = try EPubTOCEntryDAO(db: db.writer).entries(for: "book-1")

        let chapterEntry = try #require(entries.first { $0.title == "1. A Pragmatic Philosophy" })
        let chapterBlock = try #require(blocks.first { $0.id == chapterEntry.blockID })
        #expect(chapterBlock.text == "Chapter 1 A Pragmatic Philosophy")
        #expect(chapterBlock.spineIndex == 1)

        let topicEntry = try #require(entries.first { $0.title == "Topic 3. Software Entropy" })
        let topicBlock = try #require(blocks.first { $0.id == topicEntry.blockID })
        #expect(topicBlock.text == "Topic 3 Software Entropy")
        #expect(topicBlock.spineIndex == 2)
    }

    @Test func fragmentResolvedTopicTitleIsPromotedToHeading() async throws {
        let (_, blocks) = try await runImport()

        // The topic title is a layout table in the source — without promotion
        // it imports as a paragraph and the reader can't style or anchor it.
        let topicBlock = try #require(blocks.first { $0.text == "Topic 3 Software Entropy" })
        #expect(topicBlock.blockKind == EPubBlockRecord.Kind.heading.rawValue)

        // Body prose must never be promoted, even in the same file.
        let prose = try #require(blocks.first { $0.text?.hasPrefix("While software") == true })
        #expect(prose.blockKind == EPubBlockRecord.Kind.paragraph.rawValue)
    }

    @Test func reimportReplacesTOCEntries() async throws {
        let db = try DatabaseService(inMemory: ())
        let epubDir = try makeHierarchicalEPUB()
        defer { try? FileManager.default.removeItem(at: epubDir) }
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let service = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))
        _ = try await service.import(audiobookID: "book-1", epubURL: epubDir, chapters: [], bookDuration: nil)
        _ = try await service.import(audiobookID: "book-1", epubURL: epubDir, chapters: [], bookDuration: nil)

        let entries = try EPubTOCEntryDAO(db: db.writer).entries(for: "book-1")
        #expect(entries.count == 3)
    }

    @Test func tocEntryRecordRoundTripsThroughDatabase() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let dao = EPubTOCEntryDAO(db: db.writer)
        try dao.insertAll([
            EPubTOCEntryRecord(
                id: "toc-book-1-0", audiobookID: "book-1", parentID: nil,
                orderIndex: 0, depth: 0, title: "1. A Pragmatic Philosophy",
                blockID: "epub-book-1-s1-b0", spineIndex: 1
            ),
            EPubTOCEntryRecord(
                id: "toc-book-1-1", audiobookID: "book-1", parentID: "toc-book-1-0",
                orderIndex: 1, depth: 1, title: "Topic 3. Software Entropy",
                blockID: nil, spineIndex: 2
            ),
        ])
        let fetched = try dao.entries(for: "book-1")
        #expect(fetched.count == 2)
        #expect(fetched.first?.title == "1. A Pragmatic Philosophy")
        #expect(fetched.last?.parentID == "toc-book-1-0")
        #expect(fetched.last?.blockID == nil)

        try dao.deleteAll(for: "book-1")
        #expect(try dao.entries(for: "book-1").isEmpty)
    }
}
