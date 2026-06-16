// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV18Tests {
    @Test func v18CreatesAbsServerTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(abs_server)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(columns.contains("id"))
        #expect(columns.contains("base_url"))
        #expect(columns.contains("username"))
        #expect(columns.contains("default_library_id"))
    }
}
