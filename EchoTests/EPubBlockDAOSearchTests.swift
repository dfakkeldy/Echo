// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct EPubBlockDAOSearchTests {

    /// In-book search must not surface blocks the reading feed hides: the feed
    /// loads via `visibleBlocks` (which excludes `is_hidden`), so a hidden hit
    /// would be a tappable search result with no place in the feed.
    @Test func searchExcludesHiddenBlocks() throws {
        let db = try DatabaseService(inMemory: ())
        let audiobookID = "book-1"
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        let dao = EPubBlockDAO(db: db.writer)
        try dao.insertAll([
            EPubBlockRecord(
                id: "visible", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                blockKind: "paragraph", text: "the phoenix rises",
                chapterIndex: 0, isHidden: false),
            EPubBlockRecord(
                id: "hidden", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 1, sequenceIndex: 1,
                blockKind: "paragraph", text: "phoenix ashes",
                chapterIndex: 0, isHidden: true),
        ])

        let results = try dao.searchBlocks(for: audiobookID, query: "phoenix")

        #expect(results.map(\.id) == ["visible"])
    }
}
