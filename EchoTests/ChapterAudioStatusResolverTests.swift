// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

/// A chapter "has audio" when any of its blocks carries a real audio timestamp in
/// `timeline_item` (`audio_start_time >= 0`) — the source the reader, scrubber, and
/// read-along already use. This is honest for BOTH narrated books (anchor-locked
/// timestamps) AND imported/estimated books whose timestamps are interpolated into
/// `timeline_item` with NO `alignment_anchor` rows. The old resolver keyed on
/// `alignment_anchor`, so estimated-import chapters blanked under the Audio chip.
struct ChapterAudioStatusResolverTests {
    /// `book-1`: chapter 0 = heading `ch0-head` + paragraph `ch0-para`;
    /// chapter 1 = heading `ch1-head` only. No timeline rows seeded here.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1','Test',3600)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                    VALUES ('ch0-head', 'book-1', 'c1.xhtml', 0, 0, 0, 'heading', 0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                    VALUES ('ch0-para', 'book-1', 'c1.xhtml', 0, 1, 1, 'paragraph', 0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                    VALUES ('ch1-head', 'book-1', 'c2.xhtml', 1, 0, 2, 'heading', 1)
                    """)
        }
        return db
    }

    /// Seed a `timeline_item` for `block` with a real audio timestamp — the way both
    /// narration (anchored) and estimated import (interpolated) materialize audio.
    /// Crucially writes NO `alignment_anchor`, mirroring the imported/estimated path.
    private func insertTimelineAudio(_ db: DatabaseService, block: String, start: Double = 30)
        throws
    {
        try db.write { db in
            var item = TimelineItem(
                id: "ti-\(block)", audiobookID: "book-1", itemType: .textSegment,
                title: "t", subtitle: nil, textPayload: nil, imagePath: nil,
                audioStartTime: start, audioEndTime: nil, epubSequenceIndex: nil,
                granularityLevel: .paragraph, playlistPosition: nil, isEnabled: true,
                sourceTable: "epub_block", sourceRowid: block, metadataJSON: nil,
                epubBlockID: block, timestampSource: TimestampSource.interpolated.rawValue,
                alignmentStatus: AlignmentStatus.interpolated.rawValue, alignmentConfidence: nil,
                createdAt: nil, modifiedAt: nil)
            try item.insert(db)
        }
    }

    /// Seed an UNALIGNED `timeline_item` (audio_start_time == -1) — EPUB-only content
    /// that must NOT count as having audio.
    private func insertUnalignedTimeline(_ db: DatabaseService, block: String) throws {
        try insertTimelineAudio(db, block: block, start: -1)
    }

    /// The honesty test: the timestamp is on the CONTENT block (`ch0-para`), not the
    /// heading. hasAudio for chapter 0 must STILL be true.
    @Test func hasAudioTrueWhenTimestampOnContentBlockNotHeading() throws {
        let db = try seed()
        try insertTimelineAudio(db, block: "ch0-para")
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 0) == true)
    }

    /// REGRESSION (the reported bug): an imported/estimated chapter has timeline audio
    /// but ZERO alignment_anchor rows — it must report hasAudio == true.
    @Test func hasAudioTrueForInterpolatedImportWithoutAnchors() throws {
        let db = try seed()
        try insertTimelineAudio(db, block: "ch0-para")
        // Prove no anchors exist for this book.
        let anchorCount = try db.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM alignment_anchor WHERE audiobook_id = 'book-1'") ?? 0
        }
        #expect(anchorCount == 0)
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.chaptersWithAudio(audiobookID: "book-1") == Set([0]))
    }

    @Test func hasAudioFalseWhenChapterHasNoTimestampedBlocks() throws {
        let db = try seed()
        try insertTimelineAudio(db, block: "ch0-para")  // chapter 0 only; chapter 1 has none
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 1) == false)
    }

    @Test func hasAudioFalseWhenOnlyUnalignedTimelineRows() throws {
        let db = try seed()
        try insertUnalignedTimeline(db, block: "ch0-para")  // audio_start_time == -1
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 0) == false)
    }

    @Test func hasAudioFalseWhenChapterHasNoBlocks() throws {
        let db = try seed()
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 99) == false)
    }

    @Test func chaptersWithAudioReturnsOnlyChaptersWithTimestampedBlocks() throws {
        let db = try seed()
        try insertTimelineAudio(db, block: "ch0-para")  // chapter 0 content block only
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.chaptersWithAudio(audiobookID: "book-1") == Set([0]))
    }

    @Test func chaptersWithAudioEmptyWhenNoTimestamps() throws {
        let db = try seed()
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.chaptersWithAudio(audiobookID: "book-1").isEmpty)
    }

    @Test func chaptersWithAudioExcludesUnalignedRows() throws {
        let db = try seed()
        try insertUnalignedTimeline(db, block: "ch0-para")  // -1 only
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.chaptersWithAudio(audiobookID: "book-1").isEmpty)
    }
}
