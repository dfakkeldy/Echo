// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V39 — durable private Article Workshop sync state and pending changes.
enum Schema_V39 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "article_sync_state") { t in
            t.column("id", .text).primaryKey().check(sql: "id = 'default'")
            t.column("engine_state", .blob)
            t.column("account_status", .text).notNull().defaults(to: "unknown")
            t.column("last_error_code", .text)
            t.column("updated_at", .text).notNull()
        }

        try db.create(table: "article_sync_outbox") { t in
            t.column("record_name", .text).primaryKey()
            t.column("record_type", .text).notNull()
            t.column("entity_id", .text).notNull()
            t.column("operation", .text).notNull()
            t.column("queued_at", .text).notNull()
        }
    }
}
