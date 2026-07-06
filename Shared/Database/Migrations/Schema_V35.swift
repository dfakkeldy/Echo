// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V35 - Library edition grouping.
///
/// Audio and text editions of the same title can share one shelf card. The
/// opt-out flag lets a future "separate this edition" action survive rescans.
enum Schema_V35 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "audiobook") { table in
            table.add(column: "edition_group_id", .text)
            table.add(column: "edition_group_optout", .boolean).notNull().defaults(to: false)
        }
    }
}
