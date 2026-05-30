import GRDB

/// V6 migration — performance indexes, transcription_word primary key, and data integrity fixes.
enum Schema_V6 {
    static func migrate(_ db: Database) throws {
        // ── Missing performance indexes ──
        try db.create(index: "idx_audiobook_added_at", on: "audiobook",
                       columns: ["added_at"], unique: false, ifNotExists: true)
        try db.create(index: "idx_playback_state_last_played", on: "playback_state",
                       columns: ["last_played_at"], unique: false, ifNotExists: true)
        try db.create(index: "idx_transcription_word_segment", on: "transcription_word",
                       columns: ["segment_id"], unique: false, ifNotExists: true)

        // ── transcription_word: add explicit primary key ──
        // The original table had no PK, making MutablePersistableRecord semantics unreliable.
        // Recreate with an auto-increment integer primary key.
        try db.execute(sql: """
            CREATE TABLE transcription_word_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                segment_id INTEGER NOT NULL REFERENCES transcription_segment(id) ON DELETE CASCADE,
                word TEXT NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                position INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            INSERT INTO transcription_word_new (segment_id, word, start_time, end_time, position)
            SELECT segment_id, word, start_time, end_time, position FROM transcription_word
            """)
        try db.execute(sql: "DROP TABLE transcription_word")
        try db.execute(sql: "ALTER TABLE transcription_word_new RENAME TO transcription_word")

        // Re-create the segment_id index on the new table
        try db.create(index: "idx_transcription_word_segment", on: "transcription_word",
                       columns: ["segment_id"], unique: false, ifNotExists: true)
    }
}
