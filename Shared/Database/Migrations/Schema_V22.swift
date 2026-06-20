// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V22 — Audiobookshelf provenance on the audiobook record. All nullable: a local
/// import leaves them NULL and behaves exactly as before. `topics_json` is a
/// JSON-encoded `[String]` of genres/tags/series carried from the ABS item.
enum Schema_V22 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "audiobook") { t in
            t.add(column: "source_type", .text)  // "audiobookshelf" or NULL (local)
            t.add(column: "server_id", .text)
            t.add(column: "remote_item_id", .text)
            t.add(column: "topics_json", .text)
        }
    }
}
