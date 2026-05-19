import GRDB

/// V4 migration — materialized timeline_item table replacing the timeline VIEW
/// for dense/sparse dual-path feed queries.
enum Schema_V4 {
    static func migrate(_ db: Database) throws {
        try db.create(table: "timeline_item") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("item_type", .text).notNull()
            t.column("title", .text).notNull()
            t.column("subtitle", .text)
            t.column("text_payload", .text)
            t.column("image_path", .text)
            t.column("audio_start_time", .double).notNull()
            t.column("audio_end_time", .double)
            t.column("epub_sequence_index", .integer)
            t.column("granularity_level", .integer).notNull().defaults(to: 2)
            t.column("playlist_position", .double)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("source_table", .text)
            t.column("source_rowid", .text)
            t.column("metadata_json", .text)
            t.column("created_at", .text)
            t.column("modified_at", .text)
        }

        // Range query: "what's playing at position X?"
        try db.create(index: "idx_timeline_time_range",
                       on: "timeline_item",
                       columns: ["audiobook_id", "audio_start_time", "audio_end_time"])

        // EPUB structural order: survives alignment failures
        try db.create(index: "idx_timeline_epub_order",
                       on: "timeline_item",
                       columns: ["audiobook_id", "epub_sequence_index"])

        // Granularity filtering: chapter-level for scrubbing, sentence-level for reading
        try db.create(index: "idx_timeline_granularity",
                       on: "timeline_item",
                       columns: ["audiobook_id", "granularity_level"])

        // Playlist reorder + effective position sort
        try db.create(index: "idx_timeline_playlist",
                       on: "timeline_item",
                       columns: ["audiobook_id", "playlist_position", "audio_start_time"])

        // Source table sync: find materialized row by backing row
        try db.create(index: "idx_timeline_source",
                       on: "timeline_item",
                       columns: ["source_table", "source_rowid"])
    }
}
