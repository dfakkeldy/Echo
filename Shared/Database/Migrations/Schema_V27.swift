// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V27 — On-device Library: browsable shelf metadata on `audiobook` plus a
/// `library_root` table of registered, rescannable folders.
///
/// Additive only: new nullable columns (and two NOT NULL columns with defaults,
/// safe for SQLite `ALTER TABLE ADD COLUMN`), a new table, and indexes. Does not
/// edit shipped migrations and does not force an EPUB re-import or re-alignment.
enum Schema_V27 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "audiobook") { t in
            t.add(column: "cover_art_path", .text)
            t.add(column: "narrator", .text)
            t.add(column: "index_state", .integer).notNull().defaults(to: 0)
            t.add(column: "is_available", .boolean).notNull().defaults(to: true)
            t.add(column: "last_seen_at", .text)
            t.add(column: "author_sort", .text)
            // Plain column (no hard FK): root-removal clears it manually, and
            // SQLite can't add a FK constraint via ALTER TABLE ADD COLUMN.
            t.add(column: "source_root_id", .text)
        }

        try db.create(table: "library_root", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("display_name", .text).notNull()
            t.column("bookmark", .blob).notNull()
            t.column("added_at", .text).notNull()
            t.column("last_scanned_at", .text)
        }

        try db.create(
            index: "idx_audiobook_author_sort",
            on: "audiobook", columns: ["author_sort"], ifNotExists: true)
        try db.create(
            index: "idx_audiobook_available_added",
            on: "audiobook", columns: ["is_available", "added_at"], ifNotExists: true)
        try db.create(
            index: "idx_audiobook_source_root",
            on: "audiobook", columns: ["source_root_id"], ifNotExists: true)
    }
}
