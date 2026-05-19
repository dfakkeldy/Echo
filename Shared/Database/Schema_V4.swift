import GRDB

/// V4 migration — Dual-Path Timeline Feed.
///
/// Adds columns for EPUB references, image assets, and a new `image_asset` table.
/// Recreates the unified `timeline` VIEW with:
///   - Renamed item_type values: chapter→chapterMarker, flashcard→ankiCard, transcription→textSegment
///   - New columns: audio_end_time, text_payload, epub_reference, image_path
///   - audio_start_time replacing media_timestamp
enum Schema_V4 {
    static func migrate(_ db: Database) throws {
        // ── New columns on existing tables (all nullable, safe to ALTER) ──
        try db.alter(table: "chapter") { t in
            t.add(column: "epub_reference", .text)
            t.add(column: "image_path", .text)
        }
        try db.alter(table: "transcription_segment") { t in
            t.add(column: "epub_reference", .text)
            t.add(column: "epub_sequence_index", .integer)
        }

        // ── New table for embedded artwork / EPUB images ──
        try db.create(table: "image_asset") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("title", .text)
            t.column("image_path", .text).notNull()
            t.column("media_timestamp", .double).notNull()
            t.column("epub_reference", .text)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("playlist_position", .double)
        }
        try db.create(index: "idx_image_asset_audiobook", on: "image_asset",
                       columns: ["audiobook_id", "media_timestamp"])

        // ── Recreate the unified timeline VIEW ──
        try db.execute(sql: "DROP VIEW IF EXISTS timeline")
        try db.execute(sql: """
            CREATE VIEW timeline AS
            SELECT id, audiobook_id, 'track' AS item_type,
                   title, NULL AS subtitle,
                   sort_order AS audio_start_time, NULL AS audio_end_time,
                   NULL AS text_payload, NULL AS epub_reference, NULL AS image_path,
                   NULL AS epub_sequence_index,
                   is_enabled, playlist_position,
                   NULL AS created_at, NULL AS modified_at
            FROM track
            UNION ALL
            SELECT CAST(id AS TEXT), audiobook_id, 'chapterMarker' AS item_type,
                   title, NULL AS subtitle,
                   start_seconds AS audio_start_time, end_seconds AS audio_end_time,
                   NULL AS text_payload, epub_reference, image_path,
                   NULL AS epub_sequence_index,
                   is_enabled, playlist_position,
                   NULL AS created_at, NULL AS modified_at
            FROM chapter
            UNION ALL
            SELECT id, audiobook_id, 'bookmark' AS item_type,
                   title, note AS subtitle,
                   media_timestamp AS audio_start_time, NULL AS audio_end_time,
                   note AS text_payload, NULL AS epub_reference, image_path,
                   NULL AS epub_sequence_index,
                   is_enabled, playlist_position, created_at, modified_at
            FROM bookmark
            UNION ALL
            SELECT id, audiobook_id, 'ankiCard' AS item_type,
                   front_text AS title, back_text AS subtitle,
                   media_timestamp AS audio_start_time, end_timestamp AS audio_end_time,
                   back_text AS text_payload, NULL AS epub_reference, NULL AS image_path,
                   NULL AS epub_sequence_index,
                   is_enabled, playlist_position, created_at, modified_at
            FROM flashcard
            UNION ALL
            SELECT CAST(id AS TEXT), audiobook_id, 'textSegment' AS item_type,
                   text AS title, NULL AS subtitle,
                   start_time AS audio_start_time, end_time AS audio_end_time,
                   text AS text_payload, epub_reference, NULL AS image_path,
                   epub_sequence_index,
                   1 AS is_enabled, NULL AS playlist_position,
                   NULL AS created_at, NULL AS modified_at
            FROM transcription_segment
            UNION ALL
            SELECT id, audiobook_id, 'note' AS item_type,
                   text AS title, NULL AS subtitle,
                   media_timestamp AS audio_start_time, NULL AS audio_end_time,
                   text AS text_payload, NULL AS epub_reference, NULL AS image_path,
                   NULL AS epub_sequence_index,
                   is_enabled, playlist_position, created_at, modified_at
            FROM note
            UNION ALL
            SELECT id, audiobook_id, 'imageAsset' AS item_type,
                   title, NULL AS subtitle,
                   media_timestamp AS audio_start_time, NULL AS audio_end_time,
                   NULL AS text_payload, epub_reference, image_path,
                   NULL AS epub_sequence_index,
                   is_enabled, playlist_position,
                   NULL AS created_at, NULL AS modified_at
            FROM image_asset
            """)
    }
}
