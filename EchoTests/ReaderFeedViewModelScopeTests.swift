// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ReaderFeedViewModelScopeTests {
    /// Seed: book "bk", two chapters, one timeline_item in ch1 at t=100.
    /// Mirrors the accordion-tests seed so the scope filter has real blocks to narrow.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Bk',3600)")
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
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (id, audiobook_id, epub_block_id, audio_start_time, item_type, title)
                    VALUES ('ti-c1-p','bk','c1-p',100,'textSegment','Para')
                    """)
        }
        return db
    }

    /// C1-class regression: setting a session scope must narrow `displaySections`
    /// to only the chapters whose blocks fall inside the audio window.
    /// A window of [0, 0.0001] matches nothing (no anchor at t≈0),
    /// so the scoped displaySections must be strictly narrower than whole-book.
    @Test func settingSessionScopeNarrowsDisplaySections() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        // Whole-book: 2 chapters → 2 header rows in the collapsed accordion.
        let wholeBookCount = vm.displaySections.count
        #expect(wholeBookCount > 0)

        // Scope to a window that does NOT include t=100 (the only anchor).
        vm.sessionScope = .session(start: 0, end: 0.0001)
        // didSet triggers reload(); displaySections must be narrower.
        #expect(
            vm.displaySections.count < wholeBookCount,
            "scoped feed should have fewer rows than whole-book (\(vm.displaySections.count) vs \(wholeBookCount))"
        )
    }

    /// Restoring .wholeBook after a scoped session must bring the full feed back.
    @Test func restoringWholeBookRestoresFullFeed() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        let wholeBookCount = vm.displaySections.count

        vm.sessionScope = .session(start: 0, end: 0.0001)
        let scopedCount = vm.displaySections.count

        vm.sessionScope = .wholeBook
        #expect(
            vm.displaySections.count == wholeBookCount,
            "restoring .wholeBook should restore full count; got \(vm.displaySections.count), want \(wholeBookCount)"
        )
        _ = scopedCount  // suppress unused-variable warning
    }

    /// A window that INCLUDES the only anchor (t=100) should keep that chapter
    /// in displaySections.
    @Test func sessionScopeIncludingAnchorKeepsChapter() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        // Window covers t=100 exactly.
        vm.sessionScope = .session(start: 99, end: 101)
        // At minimum the chapter that owns the anchor at t=100 must appear.
        #expect(
            vm.displaySections.count >= 1,
            "a window covering the anchor should keep at least 1 display section")
    }

    // MARK: - sessionScopedSections (I-1 fix)

    /// `sessionScopedSections` under `.wholeBook` must return every block in the book
    /// (same count as `sections`).
    @Test func sessionScopedSectionsWholeBookReturnsAll() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        // .wholeBook is the default; sections contains all 4 blocks across 2 chapters.
        let allBlockCount = vm.sections.flatMap(\.items).filter {
            if case .block = $0 { return true }
            return false
        }.count
        let scopedBlockCount = vm.sessionScopedSections.flatMap(\.items).filter {
            if case .block = $0 { return true }
            return false
        }.count
        #expect(allBlockCount > 0, "seed must produce at least one block")
        #expect(
            scopedBlockCount == allBlockCount,
            "wholeBook scope must return all blocks; got \(scopedBlockCount), want \(allBlockCount)"
        )
    }

    /// `sessionScopedSections` scoped to a window containing t=100 must include the
    /// in-scope block (c1-p) and exclude the out-of-scope block (c0-p has no anchor).
    /// This test was RED before the `sessionScopedSections` accessor existed (the view
    /// was reading `sections`, not a scoped property).
    @Test func sessionScopedSectionsFiltersToWindow() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        // Window covers t=100 (the only timeline_item, anchoring block "c1-p").
        vm.sessionScope = .session(start: 90, end: 110)

        let scopedBlocks = vm.sessionScopedSections.flatMap(\.items).compactMap { item -> String? in
            if case .block(let record) = item { return record.id }
            return nil
        }
        // The in-scope block must appear.
        #expect(scopedBlocks.contains("c1-p"), "block c1-p (at t=100) must be in scoped sections")
        // Blocks with no audio anchor (c0-h, c0-p, c1-h) must NOT appear since the
        // SessionScopeReducer only includes blocks whose audioStartTime is in [90,110].
        let outOfScopeIDs = ["c0-h", "c0-p", "c1-h"]
        for id in outOfScopeIDs {
            #expect(
                !scopedBlocks.contains(id),
                "block \(id) has no anchor in [90,110] and must be excluded from sessionScopedSections"
            )
        }
    }

    @Test func unmatchedSearchShowsNoResultsRecoveryState() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        #expect(!vm.showsNoResults)

        vm.searchQuery = "not in this book"

        #expect(vm.displaySections.count == 1)
        #expect(vm.displaySections.flatMap(\.items).isEmpty)
        #expect(vm.showsNoResults)
    }

    @Test func activeFilterWithNoItemsShowsNoResultsRecoveryState() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        vm.filter.contentType = .pics

        #expect(vm.displaySections.isEmpty)
        #expect(vm.showsNoResults)
    }
}
