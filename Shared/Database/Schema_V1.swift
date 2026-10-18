// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// Baseline schema for fresh installs.
///
/// This is the former multi-step database shape squashed before Echo's first
/// external TestFlight build. Future changes should be additive migrations.
enum Schema_V1 {
    nonisolated static func migrate(_ db: Database) throws {
        try createCoreTables(db)
        try createTimelineTables(db)
        try createReaderTables(db)
        try createMemoryTables(db)
        try createIntegrationTables(db)
        try createViews(db)
        try createIndexes(db)
    }

    private nonisolated static func createCoreTables(_ db: Database) throws {
        try db.create(table: "audiobook") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("author", .text)
            t.column("duration", .double).notNull()
            t.column("file_count", .integer)
            t.column("added_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("source_type", .text)
            t.column("server_id", .text)
            t.column("remote_item_id", .text)
            t.column("topics_json", .text)
        }

        try db.create(table: "track") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("title", .text).notNull()
            t.column("duration", .double).notNull()
            t.column("file_path", .text).notNull()
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("sort_order", .integer).notNull().defaults(to: 0)
            t.column("playlist_position", .double)
            t.column("narration_voice", .text)
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
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("modified_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("pdf_view_state_json", .text)
            t.column("latitude", .double)
            t.column("longitude", .double)
            t.column("place_name", .text)
        }

        try db.create(table: "deck") { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("source", .text).notNull().defaults(to: "manual")
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
            t.column("anki_deck_id", .integer)
        }

        try db.create(table: "flashcard") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("front_text", .text).notNull()
            t.column("back_text", .text).notNull()
            t.column("media_timestamp", .double).notNull()
            t.column("end_timestamp", .double)
            t.column("trigger_timing", .text).notNull().defaults(to: "beginning")
            t.column("next_review_date", .text)
            t.column("interval_days", .integer).notNull().defaults(to: 0)
            t.column("ease_factor", .double).notNull().defaults(to: 2.5)
            t.column("repetitions", .integer).notNull().defaults(to: 0)
            t.column("last_reviewed_at", .text)
            t.column("last_grade", .integer)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("playlist_position", .double)
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("modified_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("deck_id", .text).references("deck", onDelete: .setNull)
            t.column("tags", .text)
            t.column("media_json", .text)
            t.column("source_block_id", .text)
            t.column("stability", .double)
            t.column("difficulty", .double)
            t.column("card_type", .text).notNull().defaults(to: "normal")
            t.column("cloze_index", .integer)
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

        try db.execute(sql: """
            CREATE TABLE transcription_word (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                segment_id INTEGER NOT NULL REFERENCES transcription_segment(id) ON DELETE CASCADE,
                word TEXT NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                position INTEGER NOT NULL
            )
            """)

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
    }

    private nonisolated static func createTimelineTables(_ db: Database) throws {
        try db.create(table: "note") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("text", .text).notNull()
            t.column("media_timestamp", .double).notNull()
            t.column("real_timestamp", .text)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("playlist_position", .double)
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("modified_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("is_global", .boolean).notNull().defaults(to: false)
            t.column("voice_memo_path", .text)
            t.column("epub_block_id", .text)
        }

        try db.create(table: "planned_session") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("title", .text).notNull().defaults(to: "Listening Session")
            t.column("start_time", .text).notNull()
            t.column("end_time", .text).notNull()
            t.column("start_position", .double)
            t.column("end_position", .double)
            t.column("target_speed", .double).notNull().defaults(to: 1.0)
            t.column("is_completed", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
        }

        try db.create(table: "real_time_event") { t in
            t.column("id", .text).primaryKey()
            t.column("event_type", .text).notNull()
            t.column("audiobook_id", .text).references("audiobook", onDelete: .setNull)
            t.column("media_timestamp", .double)
            t.column("started_at", .text).notNull()
            t.column("ended_at", .text)
            t.column("title", .text)
            t.column("subtitle", .text)
            t.column("metadata_json", .text)
            t.column("source_item_id", .text)
            t.column("source_item_type", .text)
        }

        try db.create(table: "timeline_item") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
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
            t.column("epub_block_id", .text)
            t.column("timestamp_source", .text)
            t.column("alignment_status", .text)
            t.column("alignment_confidence", .double)
            t.column("pdf_view_state_json", .text)
        }
    }

    private nonisolated static func createReaderTables(_ db: Database) throws {
        try db.create(table: "epub_block") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
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
            t.column("html_content", .text)
            t.column("card_color", .text)
            t.column("word_count", .integer)
            t.column("markers", .text)
            t.column("text_formats", .text)
            t.column("chapter_theme_color", .text)
            t.column("is_front_matter", .boolean).notNull().defaults(to: false)
        }

        try db.create(table: "alignment_anchor") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("epub_block_id", .text).notNull().references("epub_block", onDelete: .cascade)
            t.column("audio_time", .double).notNull()
            t.column("audio_end_time", .double)
            t.column("anchor_kind", .text).notNull()
            t.column("source", .text).notNull()
            t.column("note", .text)
            t.column("created_at", .text)
            t.column("modified_at", .text)
        }

        try db.create(table: "epub_toc_entry") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("parent_id", .text)
            t.column("order_index", .integer).notNull()
            t.column("depth", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("block_id", .text)
            t.column("spine_index", .integer)
        }
    }

    private nonisolated static func createMemoryTables(_ db: Database) throws {
        try db.create(table: "session_location") { t in
            t.column("playback_event_id", .integer).primaryKey()
                .references("playback_event", onDelete: .cascade)
            t.column("latitude", .double).notNull()
            t.column("longitude", .double).notNull()
            t.column("place_name", .text)
            t.column("created_at", .text).notNull()
        }

        try db.create(table: "marked_passage") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("media_timestamp", .double).notNull()
            t.column("end_timestamp", .double)
            t.column("transcript_snippet", .text)
            t.column("status", .text).notNull().defaults(to: "inbox")
            t.column("converted_card_id", .text)
            t.column("note", .text)
            t.column("created_at", .text).notNull()
        }

        try db.create(table: "voice_memo") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("epub_block_id", .text)
            t.column("media_timestamp", .double).notNull()
            t.column("file_path", .text).notNull()
            t.column("duration", .double)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("modified_at", .text).notNull().defaults(sql: "(datetime('now'))")
        }
    }

    private nonisolated static func createIntegrationTables(_ db: Database) throws {
        try db.create(table: "standalone_transcript") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("chapter_index", .integer).notNull()
            t.column("segment_index", .integer).notNull()
            t.column("text", .text).notNull()
            t.column("start_time", .double).notNull()
            t.column("end_time", .double).notNull()
            t.column("words_json", .text)
            t.column("created_at", .text).notNull()
        }

        try db.create(table: "abs_server") { t in
            t.column("id", .text).primaryKey()
            t.column("base_url", .text).notNull()
            t.column("username", .text).notNull()
            t.column("default_library_id", .text)
            t.column("added_at", .text).notNull()
        }

        try db.create(table: "word_timing") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull().indexed()
                .references("audiobook", onDelete: .cascade)
            t.column("epub_block_id", .text).notNull()
            t.column("word_index", .integer).notNull()
            t.column("word", .text).notNull()
            t.column("audio_start_time", .double).notNull()
            t.column("audio_end_time", .double).notNull()
            t.column("confidence", .double).notNull().defaults(to: 0.5)
            t.column("source", .text).notNull().defaults(to: "interpolated")
        }

        try db.create(table: "batch_queue") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull()
            t.column("source_bookmark", .blob).notNull()
            t.column("companion_bookmark", .blob)
            t.column("display_name", .text).notNull()
            t.column("queue_position", .integer).notNull()
            t.column("status", .text).notNull().defaults(to: "queued")
            t.column("progress", .double).notNull().defaults(to: 0.0)
            t.column("status_message", .text)
            t.column("error_message", .text)
            t.column("enqueued_at", .text).notNull()
            t.column("started_at", .text)
            t.column("completed_at", .text)
            t.column("kind", .text).notNull().defaults(to: "align")
        }
    }

    private nonisolated static func createViews(_ db: Database) throws {
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
            UNION ALL
            SELECT id, audiobook_id, 'note' AS item_type, text AS title, NULL AS subtitle,
                   media_timestamp, is_enabled, playlist_position, created_at, modified_at
            FROM note
            """)
    }

    private nonisolated static func createIndexes(_ db: Database) throws {
        try db.create(index: "idx_track_audiobook_sort", on: "track", columns: ["audiobook_id", "sort_order"])
        try db.create(index: "idx_chapter_audiobook_sort", on: "chapter", columns: ["audiobook_id", "sort_order"])
        try db.create(index: "idx_bookmark_audiobook", on: "bookmark", columns: ["audiobook_id", "media_timestamp"])
        try db.create(index: "idx_flashcard_audiobook_due", on: "flashcard", columns: ["audiobook_id", "next_review_date"])
        try db.create(index: "idx_flashcard_due", on: "flashcard", columns: ["next_review_date"])
        try db.create(index: "idx_flashcard_deck", on: "flashcard", columns: ["deck_id"])
        try db.create(index: "idx_transcription_segment_audiobook", on: "transcription_segment", columns: ["audiobook_id", "start_time"])
        try db.create(index: "idx_transcription_word_segment", on: "transcription_word", columns: ["segment_id"])
        try db.create(index: "idx_playback_event_audiobook", on: "playback_event", columns: ["audiobook_id", "started_at"])
        try db.create(index: "idx_playback_event_started_at", on: "playback_event", columns: ["started_at"])
        try db.create(index: "idx_playback_state_last_played", on: "playback_state", columns: ["last_played_at"])
        try db.create(index: "idx_note_audiobook", on: "note", columns: ["audiobook_id", "media_timestamp"])
        try db.create(index: "idx_note_real_timestamp", on: "note", columns: ["real_timestamp"])
        try db.create(index: "idx_planned_session_time", on: "planned_session", columns: ["start_time", "end_time"])
        try db.create(index: "idx_planned_session_audiobook", on: "planned_session", columns: ["audiobook_id", "start_time"])
        try db.create(index: "idx_real_time_event_time", on: "real_time_event", columns: ["started_at"])
        try db.create(index: "idx_real_time_event_type", on: "real_time_event", columns: ["event_type"])
        try db.create(index: "idx_real_time_event_audiobook", on: "real_time_event", columns: ["audiobook_id", "started_at"])
        try db.create(index: "idx_timeline_time_range", on: "timeline_item", columns: ["audiobook_id", "audio_start_time", "audio_end_time"])
        try db.create(index: "idx_timeline_epub_order", on: "timeline_item", columns: ["audiobook_id", "epub_sequence_index"])
        try db.create(index: "idx_timeline_granularity", on: "timeline_item", columns: ["audiobook_id", "granularity_level"])
        try db.create(index: "idx_timeline_playlist", on: "timeline_item", columns: ["audiobook_id", "playlist_position", "audio_start_time"])
        try db.create(index: "idx_timeline_source", on: "timeline_item", columns: ["source_table", "source_rowid"])
        try db.create(index: "idx_epub_block_sequence", on: "epub_block", columns: ["audiobook_id", "sequence_index"])
        try db.create(index: "idx_epub_block_chapter", on: "epub_block", columns: ["audiobook_id", "chapter_index"])
        try db.create(index: "idx_epub_block_hidden", on: "epub_block", columns: ["audiobook_id", "is_hidden"])
        try db.create(index: "idx_alignment_anchor_time", on: "alignment_anchor", columns: ["audiobook_id", "audio_time"])
        try db.create(index: "idx_alignment_anchor_block", on: "alignment_anchor", columns: ["audiobook_id", "epub_block_id"])
        try db.create(index: "idx_audiobook_added_at", on: "audiobook", columns: ["added_at"])
        try db.create(index: "idx_epub_toc_entry_book", on: "epub_toc_entry", columns: ["audiobook_id", "order_index"])
        try db.create(index: "idx_marked_passage_book", on: "marked_passage", columns: ["audiobook_id", "status"])
        try db.create(index: "idx_standalone_transcript_book_time", on: "standalone_transcript", columns: ["audiobook_id", "start_time"])
        try db.create(index: "idx_word_timing_book_block", on: "word_timing", columns: ["audiobook_id", "epub_block_id", "word_index"])
        try db.create(index: "idx_voice_memo_audiobook_time", on: "voice_memo", columns: ["audiobook_id", "media_timestamp"])
    }
}
