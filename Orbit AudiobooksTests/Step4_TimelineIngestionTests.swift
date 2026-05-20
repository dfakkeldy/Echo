import Testing
import Foundation
@testable import Orbit_Audiobooks

struct TimelineIngestionServiceTests {

    @Test("TimelineIngestionService produces chapter items")
    func producesChapterItems() throws {
        let db = try DatabaseService(inMemory: ())
        let service = TimelineIngestionService(database: db)
        let chapters = [
            Chapter(index: 0, title: "Chapter 1", startSeconds: 0, endSeconds: 300, isEnabled: true),
            Chapter(index: 1, title: "Chapter 2", startSeconds: 300, endSeconds: 600, isEnabled: true),
        ]

        let items = try service.ingest(
            audiobookID: "test-book",
            chapters: chapters,
            epubBlocks: [],
            anchors: [],
            bookmarks: [],
            flashcards: [],
            plainTranscript: nil,
            enhancedTranscript: nil
        )

        let chapterItems = items.filter { $0.itemType == .chapterMarker }
        #expect(chapterItems.count == 2)
        #expect(chapterItems[0].audioStartTime == 0)
        #expect(chapterItems[1].audioStartTime == 300)
    }

    @Test("TimelineIngestionService includes EPUB text blocks with sequence ordering")
    func includesEPUBBlocks() throws {
        let db = try DatabaseService(inMemory: ())
        let epubDAO = EpubBlockDAO(db: db.writer)
        let chapter0Blocks: [EpubBlockRecord] = [
            EpubBlockRecord(id: "b0", audiobookID: "test", spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 0, sequenceIndex: 0, blockKind: "heading", text: "Chapter 1", imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil, createdAt: nil, modifiedAt: nil),
            EpubBlockRecord(id: "b1", audiobookID: "test", spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 1, sequenceIndex: 1, blockKind: "paragraph", text: "First paragraph.", imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil, createdAt: nil, modifiedAt: nil),
        ]
        try epubDAO.insertAll(chapter0Blocks, audiobookID: "test")

        let service = TimelineIngestionService(database: db)
        let chapters = [Chapter(index: 0, title: "Ch 1", startSeconds: 0, endSeconds: 300, isEnabled: true)]
        let items = try service.ingest(
            audiobookID: "test",
            chapters: chapters,
            epubBlocks: chapter0Blocks,
            anchors: [],
            bookmarks: [],
            flashcards: [],
            plainTranscript: nil,
            enhancedTranscript: nil
        )

        let textItems = items.filter { $0.itemType == .textSegment }
        #expect(textItems.count == 2)
        // Text items should have alignment_status = "unaligned" (no timestamps yet)
        #expect(textItems.allSatisfy { $0.audioStartTime == -1 })
    }

    @Test("TimelineIngestionService uses EPUB sequence order when no timestamps")
    func epubSequenceOrder() throws {
        let db = try DatabaseService(inMemory: ())
        let blocks: [EpubBlockRecord] = [
            EpubBlockRecord(id: "b-rev-0", audiobookID: "test", spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 0, sequenceIndex: 5, blockKind: "paragraph", text: "Should be second", imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil, createdAt: nil, modifiedAt: nil),
            EpubBlockRecord(id: "b-rev-1", audiobookID: "test", spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 1, sequenceIndex: 0, blockKind: "paragraph", text: "Should be first", imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil, createdAt: nil, modifiedAt: nil),
        ]

        let service = TimelineIngestionService(database: db)
        let items = try service.ingest(
            audiobookID: "test",
            chapters: [],
            epubBlocks: blocks,
            anchors: [],
            bookmarks: [],
            flashcards: [],
            plainTranscript: nil,
            enhancedTranscript: nil
        )

        let textItems = items.filter { $0.itemType == .textSegment }
        #expect(textItems.count == 2)
        #expect(textItems[0].epubSequenceIndex == 0)
        #expect(textItems[1].epubSequenceIndex == 5)
    }

    @Test("TimelineIngestionService excludes hidden blocks")
    func excludesHiddenBlocks() throws {
        let db = try DatabaseService(inMemory: ())
        let blocks: [EpubBlockRecord] = [
            EpubBlockRecord(id: "b-vis", audiobookID: "test", spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph", text: "Visible", imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil, createdAt: nil, modifiedAt: nil),
            EpubBlockRecord(id: "b-hid", audiobookID: "test", spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 1, sequenceIndex: 1, blockKind: "paragraph", text: "Hidden", imagePath: nil, chapterIndex: 0, isHidden: true, hiddenReason: "omitted", createdAt: nil, modifiedAt: nil),
        ]

        let service = TimelineIngestionService(database: db)
        let items = try service.ingest(
            audiobookID: "test",
            chapters: [],
            epubBlocks: blocks,
            anchors: [],
            bookmarks: [],
            flashcards: [],
            plainTranscript: nil,
            enhancedTranscript: nil
        )

        let textItems = items.filter { $0.itemType == .textSegment }
        #expect(textItems.count == 2)
        let hidden = textItems.first { $0.title == "Hidden" }
        #expect(hidden?.isEnabled == false)
    }

    @Test("TimelineIngestionService interleaves bookmarks with EPUB blocks")
    func interleavesBookmarks() throws {
        let db = try DatabaseService(inMemory: ())
        let service = TimelineIngestionService(database: db)

        let blocks: [EpubBlockRecord] = [
            EpubBlockRecord(id: "b0", audiobookID: "test", spineHref: "ch1.xhtml", spineIndex: 0, blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph", text: "Block 0", imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil, createdAt: nil, modifiedAt: nil),
        ]

        let bookmark = Bookmark(
            title: "My Bookmark", folderKey: "test", trackId: nil,
            timestamp: 15.0, note: "Important"
        )

        let items = try service.ingest(
            audiobookID: "test",
            chapters: [],
            epubBlocks: blocks,
            anchors: [],
            bookmarks: [bookmark],
            flashcards: [],
            plainTranscript: nil,
            enhancedTranscript: nil
        )

        let bookmarkItems = items.filter { $0.itemType == .bookmark }
        #expect(bookmarkItems.count == 1)
        #expect(bookmarkItems[0].audioStartTime == 15.0)
    }
}
