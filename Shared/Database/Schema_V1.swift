import GRDB

/// V1 schema — creates all tables, views, and FTS5 indexes for the unified timeline.
enum Schema_V1 {
    static func migrate(_ db: Database) throws {
        // ── Foundation ──
        try db.create(table: "audiobook") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("author", .text)
            t.column("duration", .double).notNull()
            t.column("file_count", .integer)
            t.column("added_at", .text).notNull().defaults(sql: "datetime('now')")
        }

        // ── Five item types ──
        try db.create(table: "track") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("title", .text).notNull()
            t.column("duration", .double).notNull()
            t.column("file_path", .text).notNull()
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("playlist_position", .double)
        }

        try db.create(table: "chapter") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("title", .text).notNull()
            t.column("start_seconds", .double).notNull()
            t.column("end_seconds", .double).notNull()
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("sort_order", .integer).notNull()
            t.column("playlist_position", .double)
        }

        try db.create(table: "bookmark") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("track_id", .text).references("track")
            t.column("title", .text).notNull()
            t.column("media_timestamp", .double).notNull()
            t.column("note", .text)
            t.column("voice_memo_path", .text)
            t.column("image_path", .text)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("playlist_position", .double)
            t.column("created_at", .text).notNull().defaults(sql: "datetime('now')")
            t.column("modified_at", .text).notNull().defaults(sql: "datetime('now')")
        }

        try db.create(table: "flashcard") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("front_text", .text).notNull()
            t.column("back_text", .text).notNull()
            t.column("media_timestamp", .double).notNull()
            t.column("end_timestamp", .double)
            t.column("trigger_timing", .text).notNull().defaults(to: "beginning")
            // SM-2 scheduling
            t.column("next_review_date", .text)
            t.column("interval_days", .integer).notNull().defaults(to: 0)
            t.column("ease_factor", .double).notNull().defaults(to: 2.5)
            t.column("repetitions", .integer).notNull().defaults(to: 0)
            t.column("last_reviewed_at", .text)
            t.column("last_grade", .integer)
            //
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("playlist_position", .double)
            t.column("created_at", .text).notNull().defaults(sql: "datetime('now')")
            t.column("modified_at", .text).notNull().defaults(sql: "datetime('now')")
        }

        try db.create(table: "transcription_segment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("start_time", .double).notNull()
            t.column("end_time", .double).notNull()
            t.column("text", .text).notNull()
        }

        try db.create(virtualTable: "transcription_fts", using: FTS5()) { t in
            t.synchronize(withTable: "transcription_segment")
            t.column("text")
        }

        try db.create(table: "transcription_word") { t in
            t.column("segment_id", .integer).notNull().references("transcription_segment", onDelete: .cascade)
            t.column("word", .text).notNull()
            t.column("start_time", .double).notNull()
            t.column("end_time", .double).notNull()
            t.column("position", .integer).notNull()
        }

        // ── Real-world time ──
        try db.create(table: "playback_event") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("track_id", .text).references("track")
            t.column("started_at", .text).notNull()
            t.column("ended_at", .text)
            t.column("start_position", .double).notNull()
            t.column("end_position", .double)
            t.column("speed", .double).notNull().defaults(to: 1.0)
            t.column("event_type", .text).notNull().defaults(to: "play")
            t.column("source", .text)
        }

        // ── Supporting tables ──
        try db.create(table: "playback_state") { t in
            t.column("audiobook_id", .text).primaryKey().references("audiobook", onDelete: .cascade)
            t.column("last_position", .double).notNull().defaults(to: 0)
            t.column("speed", .double).notNull().defaults(to: 1.0)
            t.column("last_played_at", .text)
        }

        try db.create(table: "settings") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text).notNull()
        }

        // ── Unified timeline view ──
        try db.execute(sql: """
            CREATE VIEW timeline AS
            SELECT id, audiobook_id, 'track' AS item_type, title, NULL AS subtitle,
                   sort_order AS media_timestamp, is_enabled, playlist_position,
                   NULL AS created_at, NULL AS modified_at
            FROM track
            UNION ALL
            SELECT CAST(id AS TEXT), audiobook_id, 'chapter' AS item_type, title, NULL AS subtitle,
                   start_seconds AS media_timestamp, is_enabled, playlist_position,
                   NULL AS created_at, NULL AS modified_at
            FROM chapter
            UNION ALL
            SELECT id, audiobook_id, 'bookmark' AS item_type, title, note AS subtitle,
                   media_timestamp, is_enabled, playlist_position, created_at, modified_at
            FROM bookmark
            UNION ALL
            SELECT id, audiobook_id, 'flashcard' AS item_type, front_text AS title, back_text AS subtitle,
                   media_timestamp, is_enabled, playlist_position, created_at, modified_at
            FROM flashcard
            UNION ALL
            SELECT CAST(id AS TEXT), audiobook_id, 'transcription' AS item_type, text AS title, NULL AS subtitle,
                   start_time AS media_timestamp, 1 AS is_enabled, NULL AS playlist_position,
                   NULL AS created_at, NULL AS modified_at
            FROM transcription_segment
            """)

        // ── Indexes ──
        try db.create(index: "idx_bookmark_audiobook", on: "bookmark", columns: ["audiobook_id", "media_timestamp"])
        try db.create(index: "idx_flashcard_due", on: "flashcard", columns: ["next_review_date"])
        try db.create(index: "idx_transcription_segment_audiobook", on: "transcription_segment", columns: ["audiobook_id", "start_time"])
        try db.create(index: "idx_playback_event_audiobook", on: "playback_event", columns: ["audiobook_id", "started_at"])
    }
}
