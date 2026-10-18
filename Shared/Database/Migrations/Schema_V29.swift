// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V29 — per-book text provenance marker.
///
/// `text_origin` distinguishes books whose reader text is canonical source
/// (`epub` / `pdf`) from books whose reader text was materialized from ASR
/// (`transcript`). M1 sets `transcript` after transcript materialization so
/// M2/labelling never treats an ASR-derived book as canonical source.
/// nil = legacy book imported before this column existed.
enum Schema_V29 {
    nonisolated static func migrate(_ db: Database) throws {
        let hasTextOrigin = try db.columns(in: "audiobook").contains { column in
            column.name == "text_origin"
        }
        if !hasTextOrigin {
            try db.alter(table: "audiobook") { table in
                table.add(column: "text_origin", .text)
            }
        }
    }
}
