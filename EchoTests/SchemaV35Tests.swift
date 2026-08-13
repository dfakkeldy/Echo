// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV35Tests {
    @Test func v35AddsEditionGroupColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try db.writer.read { db in
            try db.columns(in: "audiobook").map(\.name)
        }

        #expect(columns.contains("edition_group_id"))
        #expect(columns.contains("edition_group_optout"))
    }

    @Test func audiobookRecordRoundTripsEditionFields() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "file:///Books/DuneAudio/",
                title: "Dune",
                author: "Frank Herbert",
                duration: 100,
                fileCount: 1,
                addedAt: "2026-07-05T00:00:00Z",
                editionGroupID: "edition-frank-herbert-dune",
                editionGroupOptOut: true))

        let fetched = try dao.get("file:///Books/DuneAudio/")
        #expect(fetched?.editionGroupID == "edition-frank-herbert-dune")
        #expect(fetched?.editionGroupOptOut == true)
    }
}
