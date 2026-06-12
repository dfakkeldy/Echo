import GRDB

/// V14 migration — WS0 capture layer + context-dependent memory columns:
/// indexes `playback_event` for stats range scans, adds the `session_location`
/// table and bookmark location columns (WS5), note global/voice-memo columns
/// (WS6b), and backfills event-integrity repairs for rows logged before the
/// WS0 fixes.
enum Schema_V14 {
    nonisolated static func migrate(_ db: Database) throws {
        // ── Stats: fast time-range scans over listening segments ──
        try db.create(index: "idx_playback_event_started_at", on: "playback_event", columns: ["started_at"])

        // ── Context-dependent memory: per-session location (WS5) ──
        try db.create(table: "session_location") { t in
            t.column("playback_event_id", .integer).primaryKey()
                .references("playback_event", onDelete: .cascade)
            t.column("latitude", .double).notNull()
            t.column("longitude", .double).notNull()
            t.column("place_name", .text)
            t.column("created_at", .text).notNull()
        }

        // ── Context-dependent memory: bookmark location (WS5) ──
        try db.alter(table: "bookmark") { t in
            t.add(column: "latitude", .double)
            t.add(column: "longitude", .double)
            t.add(column: "place_name", .text)
        }

        // ── Brain Dump / Book Notes (WS6b) ──
        try db.alter(table: "note") { t in
            t.add(column: "is_global", .boolean).notNull().defaults(to: false)
            t.add(column: "voice_memo_path", .text)
        }

        try backfillEventIntegrity(db)
    }

    /// Repairs rows written before the WS0 logging fixes:
    /// 1. Review events were logged with the literal "flashcardReviewed"
    ///    instead of RealTimeEventType.flashcardReviewed.rawValue.
    /// 2. Instantaneous events were logged with NULL ended_at, which made
    ///    them targets of the (now removed) push-forward rewrite.
    /// playback_session rows are genuinely durational and stay untouched.
    nonisolated static func backfillEventIntegrity(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE real_time_event
            SET event_type = 'flashcard_reviewed'
            WHERE event_type = 'flashcardReviewed'
            """)
        try db.execute(sql: """
            UPDATE real_time_event
            SET ended_at = started_at
            WHERE ended_at IS NULL
              AND event_type IN ('bookmark_created', 'flashcard_reviewed',
                                 'note_created', 'voice_memo_recorded',
                                 'chapter_transition', 'planned_session_completed')
            """)
    }
}
