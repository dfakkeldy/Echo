// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V20 — persistent macOS batch-processing queue.
enum Schema_V20 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "batch_queue") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull()
            t.column("source_bookmark", .blob).notNull()
            t.column("display_name", .text).notNull()
            t.column("queue_position", .integer).notNull()
            t.column("status", .text).notNull().defaults(to: BatchItemStatus.queued.rawValue)
            t.column("progress", .double).notNull().defaults(to: 0.0)
            t.column("status_message", .text)
            t.column("error_message", .text)
            t.column("enqueued_at", .text).notNull()
            t.column("started_at", .text)
            t.column("completed_at", .text)
        }
    }
}
