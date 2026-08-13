// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

/// The V1 baseline squash folded V2…V24 into `Schema_V1` and deregistered their
/// identifiers. `DatabaseMigrator` filters `grdb_migrations` down to *registered*
/// identifiers before checking migration order, so a database that had reached
/// V1…V23 kept `v1_create_schema` marked applied, tripped no guard, and ran only
/// V25 onward — silently skipping everything V24 introduced. V41 repairs those
/// installs.
@Suite struct SchemaV41Tests {
    @Test func strandedDatabaseGainsVoiceMemoTableAndNoteBlockColumn() throws {
        let writer = try DatabaseQueue()
        try makeStrandedDatabase(writer)

        // Control: the stranded shape really is missing both objects, and the
        // legacy identifiers really are recorded.
        try writer.read { db in
            let hasTable = try db.tableExists("voice_memo")
            let hasColumn = try db.columns(in: "note").contains { $0.name == "epub_block_id" }
            #expect(hasTable == false)
            #expect(hasColumn == false)
            let applied = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(applied.contains("v1_create_schema"))
            #expect(applied.contains("v23_audiobook_abs_provenance"))
        }

        try DatabaseService.makeMigrator().migrate(writer)

        try writer.read { db in
            #expect(try db.columns(in: "note").contains { $0.name == "epub_block_id" })

            let memoColumns = Set(try db.columns(in: "voice_memo").map(\.name))
            #expect(
                memoColumns == [
                    "id", "audiobook_id", "epub_block_id", "media_timestamp", "file_path",
                    "duration", "is_enabled", "created_at", "modified_at",
                ])

            #expect(
                try db.indexes(on: "voice_memo").contains {
                    $0.name == "idx_voice_memo_audiobook_time"
                })
        }
    }

    /// The reported symptom: a memo's audio file lands on disk and then the row
    /// insert fails with "no such table: voice_memo", so the list stays empty
    /// forever. After the repair the insert and the read-back both work.
    @Test func repairedDatabaseRoundTripsVoiceMemosAndBlockThreadedNotes() throws {
        let writer = try DatabaseQueue()
        try makeStrandedDatabase(writer)
        try DatabaseService.makeMigrator().migrate(writer)

        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 1)")
            var memo = VoiceMemoRecord(
                id: "memo",
                audiobookID: "book",
                epubBlockID: "block-7",
                mediaTimestamp: 12.5,
                filePath: "memo.m4a",
                duration: 3,
                isEnabled: true,
                createdAt: "t0",
                modifiedAt: "t0")
            try memo.insert(db)
            var note = NoteRecord(
                id: "note",
                audiobookID: "book",
                text: "threaded",
                mediaTimestamp: 12.5,
                realTimestamp: nil,
                isEnabled: true,
                playlistPosition: nil,
                createdAt: "t0",
                modifiedAt: "t0",
                epubBlockID: "block-7")
            try note.insert(db)
        }

        try writer.read { db in
            // Hoisted rather than inlined into `#expect`: the macro decomposes
            // binary expressions to report both operands, and a `try` inside an
            // optional chain across `==` lands in a non-throwing closure.
            let memo = try VoiceMemoRecord.fetchOne(db, key: "memo")
            let note = try NoteRecord.fetchOne(db, key: "note")
            #expect(memo?.epubBlockID == "block-7")
            #expect(note?.epubBlockID == "block-7")
        }
    }

    /// The repair has to survive the migrator running again, and has to be a
    /// no-op on the fresh installs that already got both objects from
    /// `Schema_V1`.
    @Test func repairIsIdempotentAndLeavesFreshInstallsUnchanged() throws {
        let stranded = try DatabaseQueue()
        try makeStrandedDatabase(stranded)
        try DatabaseService.makeMigrator().migrate(stranded)
        try DatabaseService.makeMigrator().migrate(stranded)

        let fresh = try DatabaseQueue()
        try DatabaseService.makeMigrator().migrate(fresh)

        for writer in [stranded, fresh] {
            try writer.read { db in
                // Exactly one — a second `ALTER TABLE … ADD COLUMN` would throw
                // rather than duplicate, so this also pins the guard's shape.
                let blockColumns = try db.columns(in: "note").filter {
                    $0.name == "epub_block_id"
                }
                #expect(blockColumns.count == 1)
                #expect(try db.tableExists("voice_memo"))
                #expect(try DatabaseService.makeMigrator().hasCompletedMigrations(db))
            }
        }
    }

    @Test @MainActor func freshInstallAppliesTheRepairMigration() throws {
        let service = try DatabaseService(inMemory: ())
        let applied = try service.read { db in
            try DatabaseService.makeMigrator().appliedMigrations(db)
        }
        #expect(applied.contains("v41_repair_squashed_baseline_gap"))
    }
}

/// Identifiers registered by `DatabaseService` before the V1 baseline squash
/// (commit `9774be2f`). A device that last ran a pre-squash build carries these
/// rows in `grdb_migrations`.
private let legacyMigrationIdentifiers = [
    "v1_create_schema",
    "v2_timeline_support",
    "v3_missing_indexes",
    "v4_materialized_timeline",
    "v5_epub_alignment",
    "v6_indexes_and_fixes",
    "v7_epub_reader_columns",
    "v8_epub_block_word_count",
    "v9_epub_block_markers",
    "v10_epub_block_chapter_theme",
    "v11_bookmark_pdf_state",
    "v12_epub_block_front_matter",
    "v13_epub_toc_entries",
    "v14_capture_and_context",
    "v15_anki_decks",
    "v16_fsrs_cloze_transcript",
    "v17_track_narration_voice",
    "v18_abs_server",
    "v19_word_timing",
    "v20_batch_queue",
    "v21_batch_kind",
    "v22_fsrs_seed",
    "v23_audiobook_abs_provenance",
]

/// Reproduces a database left at V23 by a pre-squash build: the pre-V24 schema
/// shape, stamped with the legacy identifiers.
///
/// The shape is derived by subtracting V24's two objects from today's
/// `Schema_V1` rather than by replaying the 23 deleted migration files. Both
/// routes converge on the same schema, and the subtraction cannot drift out of
/// step with the baseline it is testing.
private func makeStrandedDatabase(_ writer: DatabaseWriter) throws {
    try writer.write { db in
        try Schema_V1.migrate(db)
        try db.execute(sql: "DROP TABLE voice_memo")
        try db.execute(sql: "ALTER TABLE note DROP COLUMN epub_block_id")
        try db.execute(
            sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)"
        )
        for identifier in legacyMigrationIdentifiers {
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [identifier])
        }
    }
}
