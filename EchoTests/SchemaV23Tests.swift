// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV23Tests {
    @Test func v23AddsProvenanceColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(audiobook)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(columns.contains("source_type"))
        #expect(columns.contains("server_id"))
        #expect(columns.contains("remote_item_id"))
        #expect(columns.contains("topics_json"))
    }
}
