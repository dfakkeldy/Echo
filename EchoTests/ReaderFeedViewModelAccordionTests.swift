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

    /// Regression for C1: spliced bookmarks must appear in `displaySections` when
    /// their chapter is toggled open. Before the fix, `chapterGroups` was built from
    /// the unspliced `parsedSections` so extras were visible in `sections` but never
    /// reached `displaySections`.
    @Test func bookmarkSplicedIntoExpandedChapterDisplaySection() throws {
        let db = try seed()
        try db.write { db in
            // Bookmark at t=100; the existing anchor (a1) at audio_time=100 on
            // block c1-p (chapter 1) makes placement() resolve this to chapter 1.
            try db.execute(
                sql: """
                    INSERT INTO bookmark
                      (id, audiobook_id, title, media_timestamp, is_enabled, created_at, modified_at)
                    VALUES ('bm1', 'bk', 'Test BM', 100, 1, '2026-06-23T00:00:00Z', '2026-06-23T00:00:00Z')
                    """)
        }
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        // Open chapter 1 so its content sections render in displaySections.
        vm.toggleChapter(1)
        #expect(vm.openChapterKey == 1)

        // The open chapter's section(s) must include at least one item whose id
        // starts with "bm-" (the spliced bookmark item).
        let allItemIDs = vm.displaySections
            .filter { $0.id.hasPrefix("ch1-") }
            .flatMap(\.items)
            .map(\.id)
        #expect(
            allItemIDs.contains(where: { $0.hasPrefix("bm-") }),
            "Expected a spliced bookmark item in chapter 1's display sections, got: \(allItemIDs)")
    }

    /// Regression for C2: a chapter with TWO sections must not produce duplicate
    /// item IDs in displaySections when extras (bookmark + flashcard) are spliced in.
    /// Before the fix, `buildExtrasByChapter` bucketed extras by chapter key and the
    /// splice loop applied the SAME extras array to every section of that chapter,
    /// causing duplicate `bm-`/`fc-` IDs → NSInternalInconsistencyException crash.
    @Test func noduplicateItemIDsInTwoSectionChapter() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk2','T2',3600)")
            // Chapter 0: heading h0, paragraph p0 → section s0;
            //            second non-junk heading h1, paragraph p1 → section s1.
            for (id, seq, kind, text) in [
                ("h0", 0, "heading", "Introduction"),
                ("p0", 1, "paragraph", "Body of intro"),
                ("h1", 2, "heading", "Background"),
                ("p1", 3, "paragraph", "Body of background"),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, text,
                           chapter_index, is_hidden, created_at, modified_at)
                        VALUES (?, 'bk2', 'ch0.xhtml', 0, ?, ?, ?, ?,
                                0, 0, '2026-06-23T00:00:00Z', '2026-06-23T00:00:00Z')
                        """,
                    arguments: [id, seq, seq, kind, text])
            }
            // Anchor at t=10 on p0 (section s0) so placement() resolves to (chapter=0, block=p0).
            try db.execute(
                sql: """
                    INSERT INTO alignment_anchor
                      (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                    VALUES ('a-p0','bk2','p0',10,'point','autoAlignment')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO timeline_item
                      (id, audiobook_id, epub_block_id, audio_start_time, item_type, title)
                    VALUES ('ti-p0','bk2','p0',10,'textSegment','Para0')
                    """)
            // Bookmark anchored to p0 (lives in section s0).
            try db.execute(
                sql: """
                    INSERT INTO bookmark
                      (id, audiobook_id, title, media_timestamp, is_enabled, created_at, modified_at)
                    VALUES ('bm-anchor','bk2','Anchored BM',10,1,'2026-06-23T00:00:00Z','2026-06-23T00:00:00Z')
                    """)
            // Flashcard with no source block and no resolvable timestamp → unanchored,
            // must land in chapter 0's LAST section (s1 tail), not both sections.
            try db.execute(
                sql: """
                    INSERT INTO flashcard
                      (id, audiobook_id, front_text, back_text, card_type,
                       media_timestamp, trigger_timing, interval_days, ease_factor,
                       repetitions, is_enabled, created_at, modified_at)
                    VALUES ('fc-unanchored','bk2','Q','A','normal',
                            9999,'manualOnly',0,2.5,0,1,
                            '2026-06-23T00:00:00Z','2026-06-23T00:00:00Z')
                    """)
        }
        let vm = ReaderFeedViewModel(audiobookID: "bk2", db: db.writer)
        vm.reload()

        // Open chapter 0 — this is where the C2 crash manifests.
        vm.toggleChapter(0)
        #expect(vm.openChapterKey == 0)

        // Collect ALL item IDs across every display section that belongs to chapter 0.
        let chapterItemIDs = vm.displaySections
            .filter { $0.id.hasPrefix("ch0-") || $0.id == "ch0-s0" }
            .flatMap(\.items)
            .map(\.id)

        // Core invariant: no duplicates.
        #expect(
            Set(chapterItemIDs).count == chapterItemIDs.count,
            "Duplicate item IDs in chapter 0 display sections: \(chapterItemIDs)")

        // The bookmark and card must each appear exactly once.
        let bmCount = chapterItemIDs.filter { $0 == "bm-bm-anchor" }.count
        let fcCount = chapterItemIDs.filter { $0 == "fc-fc-unanchored" }.count
        #expect(
            bmCount == 1,
            "Expected bookmark to appear exactly once, got \(bmCount). IDs: \(chapterItemIDs)")
        #expect(
            fcCount == 1,
            "Expected flashcard to appear exactly once, got \(fcCount). IDs: \(chapterItemIDs)")
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
