// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V33 - per-plan AI card pacing controls.
enum Schema_V33 {
    nonisolated static func migrate(_ db: Database) throws {
        let columns = try Set(db.columns(in: "study_plan").map(\.name))

        if !columns.contains("new_cards_per_day") {
            try db.alter(table: "study_plan") { t in
                t.add(column: "new_cards_per_day", .integer).notNull().defaults(to: 2)
            }
        }

        if !columns.contains("chapter_pacing") {
            try db.alter(table: "study_plan") { t in
                t.add(column: "chapter_pacing", .text).notNull().defaults(to: "card_drain")
            }
        }
    }
}
