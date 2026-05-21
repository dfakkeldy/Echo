import GRDB

/// V5 migration — adds epub_block and alignment_anchor tables for the
/// manual EPUB timeline alignment system, and extends timeline_item with
/// alignment-specific columns.
enum Schema_V5 {
    static func migrate(_ db: Database) throws {
        // ── EPUB block store ──
        try db.create(table: "epub_block") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("spine_href", .text).notNull()
            t.column("spine_index", .integer).notNull()
            t.column("block_index", .integer).notNull()
            t.column("sequence_index", .integer).notNull()
            t.column("block_kind", .text).notNull()
            t.column("text", .text)
            t.column("image_path", .text)
            t.column("chapter_index", .integer)
            t.column("is_hidden", .boolean).notNull().defaults(to: false)
            t.column("hidden_reason", .text)
            t.column("created_at", .text)
            t.column("modified_at", .text)
        }

        try db.create(index: "idx_epub_block_sequence",
                       on: "epub_block",
                       columns: ["audiobook_id", "sequence_index"])
        try db.create(index: "idx_epub_block_chapter",
                       on: "epub_block",
                       columns: ["audiobook_id", "chapter_index"])
        try db.create(index: "idx_epub_block_hidden",
                       on: "epub_block",
                       columns: ["audiobook_id", "is_hidden"])

        // ── Manual alignment anchors ──
        try db.create(table: "alignment_anchor") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("epub_block_id", .text).notNull()
                .references("epub_block", onDelete: .cascade)
            t.column("audio_time", .double).notNull()
            t.column("audio_end_time", .double)
            t.column("anchor_kind", .text).notNull()
            t.column("source", .text).notNull()
            t.column("note", .text)
            t.column("created_at", .text)
            t.column("modified_at", .text)
        }

        try db.create(index: "idx_alignment_anchor_time",
                       on: "alignment_anchor",
                       columns: ["audiobook_id", "audio_time"])
        try db.create(index: "idx_alignment_anchor_block",
                       on: "alignment_anchor",
                       columns: ["audiobook_id", "epub_block_id"])

        // ── Extend timeline_item with alignment columns ──
        try db.alter(table: "timeline_item") { t in
            t.add(column: "epub_block_id", .text)
            t.add(column: "timestamp_source", .text)
            t.add(column: "alignment_status", .text)
            t.add(column: "alignment_confidence", .double)
        }
    }
}
