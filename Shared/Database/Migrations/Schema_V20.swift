// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V20 — persistent macOS batch-processing queue.
enum Schema_V20 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "batch_queue") { t in
            t.autoIncrementedPrimaryKey("id")
            // No FK/index on audiobook_id is DELIBERATE: a queue entry legitimately
            // references a not-yet-imported book, so the audiobook row may not exist
            // (and may never, if the import fails) at enqueue time.
            t.column("audiobook_id", .text).notNull()
            t.column("source_bookmark", .blob).notNull()
            // Nullable security-scoped bookmark for the companion EPUB, captured at
            // enqueue time while the user-selected folder's scope is still active.
            // Nil when the audio file has no companion EPUB.
            t.column("companion_bookmark", .blob)
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
