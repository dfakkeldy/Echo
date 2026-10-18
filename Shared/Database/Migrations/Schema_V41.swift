// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V41 — repair databases stranded by the V1 baseline squash.
///
/// `chore(db): reset GRDB schema baseline` folded V2…V24 into `Schema_V1` and
/// deleted their `registerMigration` calls. `DatabaseMigrator` computes applied
/// migrations by filtering `grdb_migrations` down to *registered* identifiers,
/// so on a database that had already reached V1…V23 the legacy rows became
/// invisible: the out-of-order guard never fired, `v1_create_schema` read as
/// applied, and only V25 onward ran. Everything V24 introduced was therefore
/// never created on those installs, and the gap never self-healed because
/// `grdb_migrations` already recorded `v1_create_schema`.
///
/// Two objects existed only in V24 and are restored here:
/// 1. `note.epub_block_id` — document-order threading for notes in the reader
///    feed. Without it `NoteDAO` cannot position notes and in-text threading is
///    dead.
/// 2. `voice_memo` (and its index) — standalone feed memos. Without the table
///    every insert fails after the audio file is already on disk, and the memo
///    list reads as permanently empty.
///
/// Both steps are additive and idempotent, so this is a no-op on the fresh
/// installs that got the objects from `Schema_V1`. The DDL is spelled with
/// string literals rather than record constants: a repair migration has to
/// reproduce a historical shape, and must not drift if a record is later
/// renamed.
enum Schema_V41 {
    nonisolated static func migrate(_ db: Database) throws {
        // 1. Document-order position for notes. `alter` has no `ifNotExists`
        //    for columns, so gate on the live table shape.
        let noteColumns = try db.columns(in: "note").map(\.name)
        if !noteColumns.contains("epub_block_id") {
            try db.alter(table: "note") { t in
                t.add(column: "epub_block_id", .text)
            }
        }

        // 2. Standalone voice memos. Mirrors the V24 definition exactly, which
        //    is also what `Schema_V1` now creates for fresh installs.
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
            ifNotExists: true)
    }
}
