// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV31Tests {
    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    @Test func v31AddsIsActiveColumn() throws {
        let db = try DatabaseService(inMemory: ())
        let cols = try columnNames(table: "abs_server", db: db)
        #expect(cols.contains("is_active"))
    }

    @Test func v31BackfillsExistingServerAsActive() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "abs_server") { t in
                t.column("id", .text).primaryKey()
                t.column("base_url", .text).notNull()
                t.column("username", .text).notNull()
                t.column("default_library_id", .text)
                t.column("added_at", .text).notNull()
            }
            try db.execute(
                sql: """
                    INSERT INTO abs_server (id, base_url, username, default_library_id, added_at)
                    VALUES ('server-one', 'https://one.local:13378', 'reader', NULL, '2026-06-01T00:00:00Z')
                    """)
            try Schema_V31.migrate(db)
        }
        let isActive = try queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT is_active FROM abs_server WHERE id = 'server-one'")
        }
        #expect(isActive == true)
    }
}
