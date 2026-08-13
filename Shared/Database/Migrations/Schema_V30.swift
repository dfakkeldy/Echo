// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V30 — per-book generated-narration QA issues (heard-vs-source divergences).
/// Additive; FK to `audiobook` cascades so issues vanish when a book is deleted.
enum Schema_V30 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "narration_quality_issue", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("source_block_id", .text)
            t.column("source_word_start", .integer)
            t.column("source_word_end", .integer)
            t.column("audio_start_time", .double).notNull()
            t.column("audio_end_time", .double).notNull()
            t.column("expected_text", .text).notNull()
            t.column("heard_text", .text).notNull()
            t.column("issue_type", .text).notNull()
            t.column("confidence", .double).notNull()
            t.column("suggested_fix_json", .text)
            t.column("status", .text).notNull()
            t.column("created_at", .text).notNull()
            t.column("resolved_at", .text)
        }
        try db.create(
            index: "idx_narration_quality_issue_book_status",
            on: "narration_quality_issue",
            columns: ["audiobook_id", "status"], ifNotExists: true)
    }
}
