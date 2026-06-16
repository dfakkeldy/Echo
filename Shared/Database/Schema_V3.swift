// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V3 migration — adds composite indexes on audiobook_id for tables
/// that need them.
enum Schema_V3 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(index: "idx_planned_session_audiobook", on: "planned_session",
                       columns: ["audiobook_id", "start_time"],
                       unique: false, ifNotExists: true)
    }
}
