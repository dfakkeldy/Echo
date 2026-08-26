// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V26 - segment-scoped read-along timeline rows.
///
/// Segment narration files reset their per-track clock to 0 inside the same
/// chapter, so chapter-only read-along scoping can still collide. `segment_key`
/// is nullable to preserve existing whole-chapter and imported audio rows.
enum Schema_V26 {
    nonisolated static func migrate(_ db: Database) throws {
        let hasSegmentKey = try db.columns(in: "timeline_item").contains { column in
            column.name == "segment_key"
        }

        if !hasSegmentKey {
            try db.alter(table: "timeline_item") { table in
                table.add(column: "segment_key", .text)
            }
        }

        try db.create(
            index: "idx_timeline_segment_key",
            on: "timeline_item",
            columns: ["audiobook_id", "segment_key"],
            ifNotExists: true
        )
    }
}
