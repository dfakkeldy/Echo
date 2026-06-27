// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
struct AudiobookRecordLibraryFieldsTests {
    @Test func libraryFieldsRoundTripThroughSQLite() throws {
        let db = try DatabaseService(inMemory: ())
        let record = AudiobookRecord(
            id: "file:///Books/Dune/",
            title: "Dune",
            author: "Frank Herbert",
            duration: 1234,
            fileCount: 1,
            addedAt: "2026-06-27T00:00:00Z",
            coverArtPath: "covers/dune.jpg",
            narrator: "Scott Brick",
            indexState: 0,
            isAvailable: true,
            lastSeenAt: "2026-06-27T00:00:00Z",
            authorSort: "frank herbert",
            sourceRootID: "root-1")
        try AudiobookDAO(db: db.writer).save(record)

        let fetched = try AudiobookDAO(db: db.writer).get("file:///Books/Dune/")
        #expect(fetched?.coverArtPath == "covers/dune.jpg")
        #expect(fetched?.narrator == "Scott Brick")
        #expect(fetched?.indexState == 0)
        #expect(fetched?.isAvailable == true)
        #expect(fetched?.authorSort == "frank herbert")
        #expect(fetched?.sourceRootID == "root-1")
        #expect(fetched?.lastSeenAt == "2026-06-27T00:00:00Z")
    }

    @Test func defaultsApplyWhenLibraryFieldsOmitted() throws {
        let record = AudiobookRecord(
            id: "b", title: "T", author: nil, duration: 0, fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z")
        #expect(record.indexState == 0)
        #expect(record.isAvailable == true)
        #expect(record.coverArtPath == nil)
        #expect(record.narrator == nil)
        #expect(record.lastSeenAt == nil)
        #expect(record.sourceRootID == nil)
    }
}
