import GRDB

/// V16 — SRS 2.0 (FSRS columns, cloze support, anki_deck_id)
/// + standalone_transcript table for Solo Transcription.
enum Schema_V16 {
    nonisolated static func migrate(_ db: Database) throws {
        // ── SRS 2.0: flashcard FSRS + cloze + deck interop ──
        try db.alter(table: "flashcard") { t in
            t.add(column: "stability", .double)
            t.add(column: "difficulty", .double)
            t.add(column: "card_type", .text).notNull().defaults(to: "normal")
            t.add(column: "cloze_index", .integer)
        }
        try db.alter(table: "deck") { t in
            t.add(column: "anki_deck_id", .integer)
        }

        // ── Solo Transcription ──
        try db.create(table: "standalone_transcript") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("chapter_index", .integer).notNull()
            t.column("segment_index", .integer).notNull()
            t.column("text", .text).notNull()
            t.column("start_time", .double).notNull()
            t.column("end_time", .double).notNull()
            t.column("words_json", .text)
            t.column("created_at", .text).notNull()
        }
        try db.create(
            index: "idx_standalone_transcript_book_time",
            on: "standalone_transcript",
            columns: ["audiobook_id", "start_time"]
        )
    }
}
