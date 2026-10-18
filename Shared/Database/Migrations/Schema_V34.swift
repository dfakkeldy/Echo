// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V34 - Study auto-export destination and retry state.
enum Schema_V34 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "study_export_destination", ifNotExists: true) { t in
            t.column("id", .text).primaryKey().check(sql: "id = 'default'")
            t.column("bookmark", .blob).notNull()
            t.column("display_path", .text).notNull()
            t.column("needs_repick", .boolean).notNull().defaults(to: false)
            t.column("added_at", .text).notNull()
        }

        try db.create(table: "study_export_state", ifNotExists: true) { t in
            t.column("book_id", .text).primaryKey()
            t.column("file_name", .text)
            t.column("dirty", .boolean).notNull().defaults(to: true)
            t.column("content_sha256", .text)
            t.column("last_exported_at", .text)
            t.column("last_error", .text)
        }

        try db.create(
            index: "idx_study_export_state_dirty",
            on: "study_export_state",
            columns: ["dirty"],
            ifNotExists: true
        )
    }
}
