// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V21 — `batch_queue.kind` discriminates audiobook-alignment items from
/// text-only EPUB narration items. Additive `ALTER ADD … DEFAULT`, so existing
/// rows keep working (they backfill to `.align`) and no EPUB re-import or
/// alignment re-run is forced.
enum Schema_V21 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "batch_queue") { t in
            t.add(column: "kind", .text).notNull().defaults(to: BatchItemKind.align.rawValue)
        }
    }
}
