// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ReaderFeedViewModelCaptureTests {
    /// Seeds a book with one paragraph block so a note can anchor to it.
    private func seed(_ service: DatabaseService) throws {
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: ["bk1", "Book", 3600])
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES ('b1', 'bk1', 'c.xhtml', 0, 0, 0, 'paragraph', 'Para', 0, 0)
                    """)
        }
    }

    @Test func addNoteThreadsNoteIntoFeedAfterBlock() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let vm = ReaderFeedViewModel(audiobookID: "bk1", db: service.writer)
        vm.reload()
        vm.addNote(text: "my note", atBlockID: "b1")

        // Phase 1 renders from `displaySections` (the expanded/collapsed view),
        // not the raw `sections`. Assert on displaySections after expanding the
        // chapter so block items are visible.
        let chapterIndex = 0
        vm.expandChapter(chapterIndex)  // ensure items are expanded
        let ids = vm.displaySections.flatMap { $0.items.map(\.id) }
        #expect(ids.contains("b-b1"))
        #expect(ids.contains { $0.hasPrefix("note-") })
        // Note sits immediately after its block.
        let bi = ids.firstIndex(of: "b-b1")!
        #expect(ids[bi + 1].hasPrefix("note-"))
    }

    @Test func addVoiceMemoThreadsMemoIntoFeed() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let vm = ReaderFeedViewModel(audiobookID: "bk1", db: service.writer)
        vm.reload()
        let url = URL(fileURLWithPath: "/tmp/memo.m4a")
        vm.addVoiceMemo(fileURL: url, duration: 3.0, atBlockID: "b1")

        // Assert on displaySections (Phase 1 rendering layer), not sections.
        let chapterIndex = 0
        vm.expandChapter(chapterIndex)
        let ids = vm.displaySections.flatMap { $0.items.map(\.id) }
        #expect(ids.contains { $0.hasPrefix("vm-") })
    }
}
