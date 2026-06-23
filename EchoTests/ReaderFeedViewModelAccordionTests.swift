// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
struct ReaderFeedViewModelAccordionTests {
    /// `bk`: chapter 0 = heading + paragraph; chapter 1 = heading + paragraph.
    /// A timeline_item maps the chapter-1 paragraph to t=100 with an anchor, so
    /// chapter 1 "has audio" and is the resolvable active block at t=100.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','T',3600)")
            for (id, idx, kind, seq) in [
                ("c0-h", 0, "heading", 0), ("c0-p", 0, "paragraph", 1),
                ("c1-h", 1, "heading", 2), ("c1-p", 1, "paragraph", 3),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                        VALUES (?, 'bk', 'c.xhtml', ?, ?, ?, ?, ?)
                        """,
                    arguments: [id, idx, seq, seq, kind, idx])
            }
            // Anchor + timeline row on chapter 1's paragraph.
            try db.execute(
                sql: """
                    INSERT INTO alignment_anchor (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                    VALUES ('a1','bk','c1-p',100,'point','autoAlignment')
                    """)
            // `timeline_item.title` is NOT NULL with no default, and `id` is the
            // primary key — both must be supplied or the seed throws.
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (id, audiobook_id, epub_block_id, audio_start_time, item_type, title)
                    VALUES ('ti-c1-p','bk','c1-p',100,'textSegment','Para')
                    """)
        }
        return db
    }

    @Test func reloadStartsCollapsedWithOneRowPerChapter() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        #expect(vm.openChapterKey == nil)
        // Two chapters -> two header-only display sections.
        #expect(vm.displaySections.count == 2)
        #expect(vm.displaySections.allSatisfy { $0.items.count == 1 })
        #expect(vm.chapterHasAudio[1] == true)
        #expect(vm.chapterHasAudio[0] == false)
    }

    @Test func toggleChapterExpandsThenCollapses() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        vm.toggleChapter(0)
        #expect(vm.openChapterKey == 0)
        // Chapter 0 now shows header + its two blocks (one sub-section here).
        #expect(vm.displaySections.first(where: { $0.id == "ch0-s0" })?.items.count ?? 0 >= 2)
        vm.toggleChapter(0)
        #expect(vm.openChapterKey == nil)
    }

    @Test func playbackAutoExpandsPlayingChapter() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        #expect(vm.openChapterKey == nil)
        // Paused at t=100: resolves the active block but must NOT auto-expand
        // (default-collapsed TOC).
        vm.updateActiveBlock(time: 100, currentTrackChapterIndices: nil, isPlaying: false)
        #expect(vm.activeBlockID == "c1-p")
        #expect(vm.openChapterKey == nil)
        // Now actually playing: the playing chapter (1) auto-expands.
        vm.updateActiveBlock(time: 100, currentTrackChapterIndices: nil, isPlaying: true)
        #expect(vm.openChapterKey == 1)
    }
}
