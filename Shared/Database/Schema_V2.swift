// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V2 migration — adds timeline support tables (note, planned_session, real_time_event)
/// and extends the unified timeline VIEW to include notes.
enum Schema_V2 {
    nonisolated static func migrate(_ db: Database) throws {
        // ── Free-text notes at media timestamps ──
        try db.create(table: "note", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull().references("audiobook", onDelete: .cascade)
            t.column("text", .text).notNull()
            t.column("media_timestamp", .double).notNull()
            t.column("real_timestamp", .text)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("playlist_position", .double)
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("modified_at", .text).notNull().defaults(sql: "(datetime('now'))")
        }

        // ── User-scheduled listening blocks ──
        try db.create(table: "planned_session", ifNotExists: true) { t in
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

        // ── Materialized real-time event store ──
        try db.create(table: "real_time_event", ifNotExists: true) { t in
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

        // ── Replace timeline VIEW to include notes ──
        try db.execute(sql: "DROP VIEW IF EXISTS timeline")
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

        // ── Indexes ──
        try db.create(index: "idx_note_audiobook", on: "note",
                       columns: ["audiobook_id", "media_timestamp"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_note_real_timestamp", on: "note",
                       columns: ["real_timestamp"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_planned_session_time", on: "planned_session",
                       columns: ["start_time", "end_time"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_real_time_event_time", on: "real_time_event",
                       columns: ["started_at"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_real_time_event_type", on: "real_time_event",
                       columns: ["event_type"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_real_time_event_audiobook", on: "real_time_event",
                       columns: ["audiobook_id", "started_at"],
                       unique: false, ifNotExists: true)
    }
}
