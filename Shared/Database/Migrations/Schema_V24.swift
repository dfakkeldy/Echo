// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V24 — Unified-feed Phase 4 content types.
///
/// 1. `note.epub_block_id` (nullable FK to `epub_block.id`) lets notes thread
///    into the reader feed at their EPUB document position, mirroring how
///    `timeline_item.epub_block_id` positions other items. Existing notes leave
///    it NULL and continue to be positioned by `media_timestamp` only.
/// 2. `voice_memo` is a net-new standalone-memo table (the file + a row). It is
///    distinct from `bookmark.voice_memo_path`, which remains an *attachment*
///    on a bookmark. A feed voice memo does not imply a bookmark.
enum Schema_V24 {
    nonisolated static func migrate(_ db: Database) throws {
        // 1. Document-order position for notes.
        try db.alter(table: "note") { t in
            t.add(column: "epub_block_id", .text)
        }

        // 2. Standalone voice memos.
        try db.create(table: "voice_memo", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("epub_block_id", .text)
            t.column("media_timestamp", .double).notNull()
            t.column("file_path", .text).notNull()
            t.column("duration", .double)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("modified_at", .text).notNull().defaults(sql: "(datetime('now'))")
        }

        try db.create(
            index: "idx_voice_memo_audiobook_time",
            on: "voice_memo",
            columns: ["audiobook_id", "media_timestamp"],
            ifNotExists: true
        )
    }
}
