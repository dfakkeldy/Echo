// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V36 — adds `code_language` column to `epub_block` for `.code` blocks
/// (language hint sniffed at import, e.g. "python"). Nullable — nil means
/// no hint / not a code block (backward-compatible with all existing books).
enum Schema_V36 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "code_language", .text)
        }
    }
}
