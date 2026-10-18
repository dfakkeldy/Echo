// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

enum Schema_V38 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: EPubBlockRecord.databaseTableName) { table in
            table.add(column: "source_chapter_key", .text)
        }
    }
}
