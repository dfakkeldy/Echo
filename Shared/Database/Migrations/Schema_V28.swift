// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V28 — per-block source PDF page index, for page-mode read-along auto-follow.
/// (Char-offset geometry was infeasible; see the M3 spec §5.)
///
/// Registered after V27 (`v27_library`, on-device Library); this work originally
/// used V27 but `v27_library` landed on nightly first, so it was renumbered.
enum Schema_V28 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "pdf_block_page", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull()
            t.column("epub_block_id", .text).notNull()
            t.column("page_index", .integer).notNull()
        }
        try db.create(
            index: "idx_pdf_block_page_book", on: "pdf_block_page",
            columns: ["audiobook_id", "epub_block_id"], ifNotExists: true)
        try db.create(
            index: "idx_pdf_block_page_page", on: "pdf_block_page",
            columns: ["audiobook_id", "page_index"], ifNotExists: true)
    }
}
