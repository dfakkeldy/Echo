// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct EPubBlockDAOHideTests {
    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',0)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph','hi',2,0),
                           ('b1','bk','c.xhtml',0,1,1,'paragraph','yo',2,0),
                           ('b2','bk','c.xhtml',0,2,2,'paragraph','other',3,0)
                    """)
        }
    }

    @Test func unhideChapterRestoresOnlyThatChapter() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db)
        let dao = EPubBlockDAO(db: db.writer)
        try dao.hideChapter(chapterIndex: 2, audiobookID: "bk", reason: "skip")
        // Chapter 2 hidden, chapter 3 untouched.
        #expect(try dao.visibleBlocks(for: "bk").map(\.id) == ["b2"])

        try dao.unhideChapter(chapterIndex: 2, audiobookID: "bk")
        #expect(try dao.visibleBlocks(for: "bk").map(\.id).sorted() == ["b0", "b1", "b2"])
    }

    @Test func searchBlocksExcludesHiddenBlocks() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db)
        let dao = EPubBlockDAO(db: db.writer)

        try dao.hideBlock(id: "b0", reason: "front matter")

        #expect(try dao.searchBlocks(for: "bk", query: "hi").isEmpty)
        #expect(try dao.searchBlocks(for: "bk", query: "yo").map(\.id) == ["b1"])
    }
}
