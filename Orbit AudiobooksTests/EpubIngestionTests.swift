import Testing
import Foundation
import GRDB
@testable import Orbit_Audiobooks

@MainActor
struct EpubIngestionTests {

    @Test func epubBlockIngestionIncludesChaptersAndBlocks() async throws {
        let db = try DatabaseService(inMemory: ())

        // Insert audiobook + EPUB blocks
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let blocks: [EPubBlockRecord] = [
            EPubBlockRecord(id: "b0", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                           blockKind: "heading", text: "Chapter 1", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(id: "b1", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 1, sequenceIndex: 1,
                           blockKind: "paragraph", text: "It was a dark night.", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(id: "b2", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 2, sequenceIndex: 2,
                           blockKind: "paragraph", text: "The rain fell.", chapterIndex: 0, isHidden: false),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)

        let chapters: [Chapter] = [
            Chapter(index: 0, title: "Chapter 1", startSeconds: 0, endSeconds: 1800, isEnabled: true),
        ]

        let strategy = EPUBBlockIngestionStrategy()
        let items = try await strategy.ingest(
            audiobookID: "book-1",
            audioURL: URL(fileURLWithPath: "/tmp/test.m4b"),
            chapters: chapters,
            transcript: nil,
            enhancedTranscript: nil,
            epubBlocks: blocks,
            alignmentAnchors: nil,
            bookmarks: nil,
            flashcards: nil
        )

        // Chapters + 3 blocks = 4 items
        #expect(items.count == 4)
        #expect(items.contains(where: { $0.itemType == .chapterMarker }))
        #expect(items.contains(where: { $0.itemType == .textSegment }))

        // All EPUB blocks have correct source linkage
        for item in items where item.sourceTable == "epub_block" {
            #expect(item.epubBlockID != nil)
            #expect(item.alignmentStatus != nil)
        }
    }

    @Test func epubBlockIngestionWithAnchorsSetsTimestamps() async throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let blocks: [EPubBlockRecord] = [
            EPubBlockRecord(id: "b0", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                           blockKind: "paragraph", text: "First block.", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(id: "b1", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 1, sequenceIndex: 1,
                           blockKind: "paragraph", text: "Second block.", chapterIndex: 0, isHidden: false),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)

        let anchors: [AlignmentAnchorRecord] = [
            AlignmentAnchorRecord(id: "a0", audiobookID: "book-1", epubBlockID: "b0",
                                 audioTime: 42.0, anchorKind: "point", source: "moveToNow"),
            AlignmentAnchorRecord(id: "a1", audiobookID: "book-1", epubBlockID: "b1",
                                 audioTime: 120.0, anchorKind: "point", source: "moveToNow"),
        ]

        let strategy = EPUBBlockIngestionStrategy()
        let items = try await strategy.ingest(
            audiobookID: "book-1",
            audioURL: URL(fileURLWithPath: "/tmp/test.m4b"),
            chapters: [],
            transcript: nil,
            enhancedTranscript: nil,
            epubBlocks: blocks,
            alignmentAnchors: anchors,
            bookmarks: nil,
            flashcards: nil
        )

        let epubItems = items.filter { $0.sourceTable == "epub_block" }
        #expect(epubItems.count == 2)

        let b0 = epubItems.first { $0.epubBlockID == "b0" }
        #expect(b0?.audioStartTime == 42.0)
        #expect(b0?.alignmentStatus == AlignmentStatus.lockedAnchor.rawValue)

        let b1 = epubItems.first { $0.epubBlockID == "b1" }
        #expect(b1?.audioStartTime == 120.0)
    }

    @Test func epubBlockIngestionHiddenBlocksAreOmitted() async throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let blocks: [EPubBlockRecord] = [
            EPubBlockRecord(id: "b0", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                           blockKind: "paragraph", text: "Visible.", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(id: "b1", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 1, sequenceIndex: 1,
                           blockKind: "paragraph", text: "Hidden.", chapterIndex: 0, isHidden: true),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)

        let strategy = EPUBBlockIngestionStrategy()
        let items = try await strategy.ingest(
            audiobookID: "book-1",
            audioURL: URL(fileURLWithPath: "/tmp/test.m4b"),
            chapters: [],
            transcript: nil,
            enhancedTranscript: nil,
            epubBlocks: blocks,
            alignmentAnchors: nil,
            bookmarks: nil,
            flashcards: nil
        )

        let hidden = items.first { $0.epubBlockID == "b1" }
        #expect(hidden?.isEnabled == false)
        #expect(hidden?.alignmentStatus == AlignmentStatus.omitted.rawValue)
    }
}
