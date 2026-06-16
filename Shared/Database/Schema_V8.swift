// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V8 migration — adds word_count column to epub_block for proportional alignment.
enum Schema_V8 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "word_count", .integer)
        }
    }
}
