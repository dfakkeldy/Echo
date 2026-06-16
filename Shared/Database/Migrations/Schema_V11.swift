// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

enum Schema_V11 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "bookmark") { t in
            t.add(column: "pdf_view_state_json", .text)
        }
        
        try db.alter(table: "timeline_item") { t in
            t.add(column: "pdf_view_state_json", .text)
        }
    }
}