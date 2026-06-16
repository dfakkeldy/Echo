// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V12 migration — adds is_front_matter to epub_block. Front-matter blocks
/// (cover, praise pages, printed TOC, …) are grouped separately in the reader
/// TOC and never receive synthesized chapter headings.
enum Schema_V12 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "is_front_matter", .boolean).notNull().defaults(to: false)
        }
    }
}
