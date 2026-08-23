// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V7 migration — adds html_content and card_color columns to epub_block
/// for the EPUB reader feed (Phase 5.1).
enum Schema_V7 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "html_content", .text)
            t.add(column: "card_color", .text)
        }
    }
}
