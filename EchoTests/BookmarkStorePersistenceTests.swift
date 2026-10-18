// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing
@testable import Echo

@MainActor
struct BookmarkStorePersistenceTests {
    @Test func failedReplacementPreservesBookmarksAndTimeline() throws {
        let database = try DatabaseService(inMemory: ())
        try AudiobookDAO(db: database.writer).insert(
            AudiobookRecord(id: "book", title: "Synthetic book", duration: 60,
                            addedAt: "2026-09-12T00:00:00Z"))
        let original = Bookmark(title: "Original", folderKey: "book", timestamp: 10)
        try BookmarkStore.replaceBookmarks([original], for: "book", database: database)
        let valid = Bookmark(title: "Replacement", folderKey: "book", timestamp: 20)
        let invalid = Bookmark(title: "Invalid foreign key", folderKey: "missing", timestamp: 30)
        #expect(throws: (any Error).self) {
            try BookmarkStore.replaceBookmarks([valid, invalid], for: "book", database: database)
        }
        let records = try BookmarkDAO(db: database.writer).bookmarks(for: "book")
        #expect(records.map(\.id) == [original.id.uuidString])
        let timelineIDs = try database.read { db in
            try String.fetchAll(db, sql: "SELECT source_rowid FROM timeline_item WHERE source_table = 'bookmark'")
        }
        #expect(timelineIDs == [original.id.uuidString])
    }
}
