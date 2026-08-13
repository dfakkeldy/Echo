// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V31 — converts `abs_server` from a single-row table into a true multi-row
/// table with an `is_active` flag, enabling macOS's multiple-saved-servers UI.
/// `current()` keeps meaning "the active server" for iOS, which still only
/// ever activates one row in its only add-a-server flow.
enum Schema_V31 {
    nonisolated static func migrate(_ db: Database) throws {
        // Idempotency guard mirrors Schema_V29's pattern (`hasColumn` check
        // before ALTER) rather than relying on `ifNotExists`, which
        // `add(column:)` does not support.
        let hasIsActive = try db.columns(in: "abs_server").contains { $0.name == "is_active" }
        guard !hasIsActive else { return }
        try db.alter(table: "abs_server") { t in
            t.add(column: "is_active", .boolean).notNull().defaults(to: false)
        }
        // Preserve "exactly one connected server" across the upgrade.
        try db.execute(sql: "UPDATE abs_server SET is_active = 1")
    }
}
