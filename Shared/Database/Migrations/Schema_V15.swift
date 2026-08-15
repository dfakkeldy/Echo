// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V15 migration — WS6 Anki core: deck table, flashcard deck/tags/media columns,
/// and marked_passage table for the mark-later inbox.
enum Schema_V15 {
    nonisolated static func migrate(_ db: Database) throws {
        // ── Deck table ──
        try db.create(table: "deck") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("source", .text).notNull().defaults(to: "manual")
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        // ── Flashcard: deck FK + tags + media ──
        try db.alter(table: "flashcard") { t in
            t.add(column: "deck_id", .text).references("deck", onDelete: .setNull)
            t.add(column: "tags", .text)
            t.add(column: "media_json", .text)
            t.add(column: "source_block_id", .text)
        }
        try db.create(index: "idx_flashcard_deck", on: "flashcard", columns: ["deck_id"])

        // ── Marked passage table (mark-later inbox) ──
        try db.create(table: "marked_passage") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("media_timestamp", .double).notNull()
            t.column("end_timestamp", .double)
            t.column("transcript_snippet", .text)
            t.column("status", .text).notNull().defaults(to: "inbox")
            t.column("converted_card_id", .text)
            t.column("note", .text)
            t.column("created_at", .text).notNull()
        }
        try db.create(
            index: "idx_marked_passage_book",
            on: "marked_passage",
            columns: ["audiobook_id", "status"]
        )
    }
}
