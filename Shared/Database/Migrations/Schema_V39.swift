// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V39 — durable private Article Workshop sync state and pending changes.
enum Schema_V39 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "article_sync_state") { t in
            t.column("id", .text).primaryKey().check(sql: "id = 'default'")
            t.column("engine_state", .blob)
            t.column("account_owner_id", .text)
            t.column("account_status", .text).notNull().defaults(to: "unknown")
            t.column("last_error_code", .text)
            t.column("updated_at", .text).notNull()
        }

        try db.create(table: "article_sync_outbox") { t in
            t.column("record_name", .text).notNull()
            t.column("record_type", .text).notNull()
            t.column("entity_id", .text).notNull()
            t.column("operation", .text).notNull()
            t.column("generation", .integer).notNull().defaults(to: 1)
            t.column("account_owner_id", .text).notNull().defaults(to: "")
            t.column("queued_at", .text).notNull()
            t.primaryKey(["record_name", "account_owner_id"])
        }

        try db.create(table: "article_sync_record") { t in
            t.column("record_name", .text).notNull()
            t.column("record_type", .text).notNull()
            t.column("entity_id", .text).notNull()
            t.column("system_fields", .blob).notNull()
            t.column("content_fingerprint", .text).notNull()
            t.column("acknowledged_generation", .integer).notNull().defaults(to: 0)
            t.column("account_owner_id", .text).notNull()
            t.column("updated_at", .text).notNull()
            t.primaryKey(["record_name", "account_owner_id"])
        }
    }
}
