// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV29Tests {
    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    @Test func v29AddsTextOriginColumn() throws {
        let db = try DatabaseService(inMemory: ())
        let cols = try columnNames(table: "audiobook", db: db)
        #expect(cols.contains("text_origin"))
    }

    @Test func audiobookRecordRoundTripsTextOrigin() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.insert(
            AudiobookRecord(
                id: "file:///b1/", title: "Book", author: nil, duration: 100,
                addedAt: "2026-06-29T00:00:00Z", textOrigin: "transcript"))
        let fetched = try dao.get("file:///b1/")
        #expect(fetched?.textOrigin == "transcript")
    }

    @Test func legacyAudiobookHasNilTextOrigin() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('file:///legacy/', 'Old', 60, '2026-06-29T00:00:00Z')"
            )
        }
        let fetched = try AudiobookDAO(db: db.writer).get("file:///legacy/")
        #expect(fetched?.textOrigin == nil)
    }
}
