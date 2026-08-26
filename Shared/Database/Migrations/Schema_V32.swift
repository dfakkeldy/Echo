// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V32 — adds `narration_text` column to `epub_block` so FM-normalized text
/// can be persisted alongside the original source. Narration renders from this
/// column when present; QA compares against it. Nullable — nil means "use the
/// original `text` column" (backward-compatible with all existing books).
enum Schema_V32 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "narration_text", .text)
        }
    }
}
