// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@Suite struct SchemaV24CompatibilityTests {
    @Test(
        "Every pre-squash schema version reaches the current schema without data loss",
        arguments: Array(2...23)
    )
    func upgradesPreSquashInstallation(lastAppliedVersion: Int) throws {
        let writer = try makeLegacyDatabase(through: lastAppliedVersion)

        try DatabaseService.makeMigrator().migrate(writer)

        try assertCurrentSchemaAndPreservedData(in: writer)
    }

    @Test func upgradesInstallationAlreadyProcessedByEmergencyV41Repair() throws {
        let writer = try makeLegacyDatabase(through: 22)
        try makeSquashedBaselineMigrator().migrate(writer)

        try writer.read { db in
            let audiobookColumns = Set(try db.columns(in: "audiobook").map(\.name))
            #expect(!audiobookColumns.contains("source_type"))
            #expect(try db.tableExists("voice_memo"))
        }

        try DatabaseService.makeMigrator().migrate(writer)

        try assertCurrentSchemaAndPreservedData(in: writer)
    }

    @Test func squashedFreshInstallIsStampedWithoutReplayingHistoricalDDL() throws {
        let writer = try DatabaseQueue()
        try DatabaseService.makeMigrator().migrate(writer)
        try DatabaseService.makeMigrator().migrate(writer)

        try writer.read { db in
            let applied = try String.fetchSet(
                db,
                sql: "SELECT identifier FROM grdb_migrations"
            )
            #expect(applied.contains("v24_feed_note_position_voice_memo"))
            #expect(applied.isDisjoint(with: legacyMergedIdentifiers))
            #expect(try DatabaseService.makeMigrator().hasCompletedMigrations(db))
        }
    }
}

private let legacyMigrationIdentifiersByVersion = [
    1: "v1_create_schema",
    2: "v2_timeline_support",
    3: "v3_missing_indexes",
    4: "v4_materialized_timeline",
    5: "v5_epub_alignment",
    6: "v6_indexes_and_fixes",
    7: "v7_epub_reader_columns",
    8: "v8_epub_block_word_count",
    9: "v9_epub_block_markers",
    10: "v10_epub_block_chapter_theme",
    11: "v11_bookmark_pdf_state",
    12: "v12_epub_block_front_matter",
    13: "v13_epub_toc_entries",
    14: "v14_capture_and_context",
    15: "v15_anki_decks",
    16: "v16_fsrs_cloze_transcript",
    17: "v17_track_narration_voice",
    18: "v18_abs_server",
    19: "v19_word_timing",
    20: "v20_batch_queue",
    21: "v21_batch_kind",
    22: "v22_fsrs_seed",
    23: "v23_audiobook_abs_provenance",
]

private let legacyMergedIdentifiers = Set(
    legacyMigrationIdentifiersByVersion.compactMap { entry in
        entry.key >= 2 ? entry.value : nil
    })

private func makeLegacyDatabase(through version: Int) throws -> DatabaseQueue {
    let writer = try DatabaseQueue()
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_create_schema") { try LegacySchema_V1.migrate($0) }
    migrator.registerMigration("v2_timeline_support") { try Schema_V2.migrate($0) }
    migrator.registerMigration("v3_missing_indexes") { try Schema_V3.migrate($0) }
    migrator.registerMigration("v4_materialized_timeline") { try Schema_V4.migrate($0) }
    migrator.registerMigration("v5_epub_alignment") { try Schema_V5.migrate($0) }
    migrator.registerMigration("v6_indexes_and_fixes") { try Schema_V6.migrate($0) }
    migrator.registerMigration("v7_epub_reader_columns") { try Schema_V7.migrate($0) }
    migrator.registerMigration("v8_epub_block_word_count") { try Schema_V8.migrate($0) }
    migrator.registerMigration("v9_epub_block_markers") { try Schema_V9.migrate($0) }
    migrator.registerMigration("v10_epub_block_chapter_theme") { try Schema_V10.migrate($0) }
    migrator.registerMigration("v11_bookmark_pdf_state") { try Schema_V11.migrate($0) }
    migrator.registerMigration("v12_epub_block_front_matter") { try Schema_V12.migrate($0) }
    migrator.registerMigration("v13_epub_toc_entries") { try Schema_V13.migrate($0) }
    migrator.registerMigration("v14_capture_and_context") { try Schema_V14.migrate($0) }
    migrator.registerMigration("v15_anki_decks") { try Schema_V15.migrate($0) }
    migrator.registerMigration("v16_fsrs_cloze_transcript") { try Schema_V16.migrate($0) }
    migrator.registerMigration("v17_track_narration_voice") { try Schema_V17.migrate($0) }
    migrator.registerMigration("v18_abs_server") { try Schema_V18.migrate($0) }
    migrator.registerMigration("v19_word_timing") { try Schema_V19.migrate($0) }
    migrator.registerMigration("v20_batch_queue") { try Schema_V20.migrate($0) }
    migrator.registerMigration("v21_batch_kind") { try Schema_V21.migrate($0) }
    migrator.registerMigration("v22_fsrs_seed") { try Schema_V22.migrate($0) }
    migrator.registerMigration("v23_audiobook_abs_provenance") { try Schema_V23.migrate($0) }

    guard let targetIdentifier = legacyMigrationIdentifiersByVersion[version] else {
        Issue.record("Missing legacy migration identifier for V\(version)")
        return writer
    }

    try migrator.migrate(writer, upTo: "v1_create_schema")
    try writer.write { db in
        try db.execute(
            sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
            arguments: ["legacy-book", "Legacy Book", 120]
        )
        try db.execute(
            sql: """
                INSERT INTO flashcard (
                    id, audiobook_id, front_text, back_text, media_timestamp,
                    interval_days, ease_factor, repetitions
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: ["legacy-card", "legacy-book", "Front", "Back", 10, 12, 2.5, 3]
        )
    }

    try migrator.migrate(writer, upTo: targetIdentifier)
    try writer.write { db in
        try db.execute(
            sql: """
                INSERT INTO note (id, audiobook_id, text, media_timestamp)
                VALUES (?, ?, ?, ?)
                """,
            arguments: ["legacy-note", "legacy-book", "Preserve me", 10]
        )
    }
    return writer
}

/// Reproduces the migrator shipped immediately after the squash, including the
/// V41 emergency repair but without the restored merged V24 compatibility step.
private func makeSquashedBaselineMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_create_schema") { try Schema_V1.migrate($0) }
    migrator.registerMigration("v25_study_plans") { try Schema_V25.migrate($0) }
    migrator.registerMigration("v26_timeline_segment_key") { try Schema_V26.migrate($0) }
    migrator.registerMigration("v27_library") { try Schema_V27.migrate($0) }
    migrator.registerMigration("v28_pdf_block_page") { try Schema_V28.migrate($0) }
    migrator.registerMigration("v29_audiobook_text_origin") { try Schema_V29.migrate($0) }
    migrator.registerMigration("v30_narration_quality_issue") { try Schema_V30.migrate($0) }
    migrator.registerMigration("v31_abs_server_multi") { try Schema_V31.migrate($0) }
    migrator.registerMigration("v32_narration_text") { try Schema_V32.migrate($0) }
    migrator.registerMigration("v33_study_plan_card_pacing") { try Schema_V33.migrate($0) }
    migrator.registerMigration("v34_study_auto_export") { try Schema_V34.migrate($0) }
    migrator.registerMigration("v35_library_edition_grouping") { try Schema_V35.migrate($0) }
    migrator.registerMigration("v36_code_language") { try Schema_V36.migrate($0) }
    migrator.registerMigration("v37_article_workshop") { try Schema_V37.migrate($0) }
    migrator.registerMigration("v37_repair_anthology_build_attempt_receipts") {
        try Schema_V37.repairBuildAttemptReceipts($0)
    }
    migrator.registerMigration("v38_generated_chapter_key") { try Schema_V38.migrate($0) }
    migrator.registerMigration("v39_article_sync") { try Schema_V39.migrate($0) }
    migrator.registerMigration("v40_narration_quality_issue_origin") { try Schema_V40.migrate($0) }
    migrator.registerMigration("v41_repair_squashed_baseline_gap") { try Schema_V41.migrate($0) }
    return migrator
}

private func assertCurrentSchemaAndPreservedData(in writer: DatabaseWriter) throws {
    let requiredColumns: [String: Set<String>] = [
        "audiobook": ["source_type", "server_id", "remote_item_id", "topics_json"],
        "track": ["narration_voice"],
        "bookmark": ["pdf_view_state_json", "latitude", "longitude", "place_name"],
        "flashcard": [
            "deck_id", "tags", "media_json", "source_block_id", "stability", "difficulty",
            "card_type", "cloze_index",
        ],
        "transcription_word": ["id"],
        "note": ["is_global", "voice_memo_path", "epub_block_id"],
        "timeline_item": [
            "epub_block_id", "timestamp_source", "alignment_status", "alignment_confidence",
            "pdf_view_state_json",
        ],
        "epub_block": [
            "html_content", "card_color", "word_count", "markers", "text_formats",
            "chapter_theme_color", "is_front_matter",
        ],
        "deck": ["anki_deck_id"],
        "batch_queue": ["kind"],
        "voice_memo": ["epub_block_id", "media_timestamp", "file_path"],
    ]

    try writer.read { db in
        for (table, expectedColumns) in requiredColumns {
            let actualColumns = Set(try db.columns(in: table).map(\.name))
            #expect(
                actualColumns.isSuperset(of: expectedColumns),
                "\(table) is missing historical columns"
            )
        }

        for table in [
            "planned_session", "real_time_event", "alignment_anchor", "epub_toc_entry",
            "session_location", "marked_passage", "standalone_transcript", "abs_server",
            "word_timing", "voice_memo",
        ] {
            #expect(try db.tableExists(table), "missing historical table \(table)")
        }

        #expect(
            try db.indexes(on: "planned_session").contains {
                $0.name == "idx_planned_session_audiobook"
            })
        #expect(
            try db.indexes(on: "voice_memo").contains {
                $0.name == "idx_voice_memo_audiobook_time"
            })
        try db.checkForeignKeys()

        let title = try String.fetchOne(
            db,
            sql: "SELECT title FROM audiobook WHERE id = ?",
            arguments: ["legacy-book"]
        )
        let noteText = try String.fetchOne(
            db,
            sql: "SELECT text FROM note WHERE id = ?",
            arguments: ["legacy-note"]
        )
        let memoryState = try Row.fetchOne(
            db,
            sql: "SELECT stability, difficulty FROM flashcard WHERE id = ?",
            arguments: ["legacy-card"]
        )
        let stability: Double? = memoryState?["stability"]
        let difficulty: Double? = memoryState?["difficulty"]
        #expect(title == "Legacy Book")
        #expect(noteText == "Preserve me")
        #expect(stability != nil)
        #expect(difficulty != nil)

        let applied = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
        #expect(applied.contains("v24_feed_note_position_voice_memo"))
        #expect(applied.isDisjoint(with: legacyMergedIdentifiers))
        #expect(try DatabaseService.makeMigrator().hasCompletedMigrations(db))
    }
}
