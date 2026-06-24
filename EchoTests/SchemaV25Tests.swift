// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV25Tests {
    @Test func v25CreatesStudyPlanTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "study_plan", db: db)

        #expect(columns.contains("id"))
        #expect(columns.contains("audiobook_id"))
        #expect(columns.contains("deck_id"))
        #expect(columns.contains("cadence_unit"))
        #expect(columns.contains("new_chapter_limit"))
        #expect(columns.contains("include_images"))
        #expect(columns.contains("queue_mode_default"))
        #expect(columns.contains("catch_up_policy"))
        #expect(columns.contains("start_date"))
        #expect(columns.contains("is_paused"))
        #expect(columns.contains("created_at"))
        #expect(columns.contains("modified_at"))
    }

    @Test func v25CreatesStudyPlanItemTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "study_plan_item", db: db)

        #expect(columns.contains("id"))
        #expect(columns.contains("plan_id"))
        #expect(columns.contains("flashcard_id"))
        #expect(columns.contains("kind"))
        #expect(columns.contains("chapter_index"))
        #expect(columns.contains("source_block_id"))
        #expect(columns.contains("ordinal"))
        #expect(columns.contains("introduced_at"))
        #expect(columns.contains("is_enabled"))
        #expect(columns.contains("created_at"))
        #expect(columns.contains("modified_at"))
    }

    @Test func v25CreatesStudyPlanIndexes() throws {
        let db = try DatabaseService(inMemory: ())
        let planIndexes = try indexNames(table: "study_plan", db: db)
        let itemIndexes = try indexNames(table: "study_plan_item", db: db)

        #expect(planIndexes.contains("idx_study_plan_book"))
        #expect(planIndexes.contains("idx_study_plan_active"))
        #expect(itemIndexes.contains("idx_study_plan_item_plan_order"))
        #expect(itemIndexes.contains("idx_study_plan_item_pending"))
        #expect(itemIndexes.contains("idx_study_plan_item_flashcard"))
        #expect(itemIndexes.contains("idx_study_plan_item_source"))
    }

    @Test func migratingFromV24PreservesDecksAndFlashcards() throws {
        let queue = try makeV24Database()
        try seedLegacyStudyData(in: queue)

        try makeMigrator(includeV25: true).migrate(queue)

        let snapshot = try queue.read { db in
            (
                try String.fetchOne(db, sql: "SELECT name FROM deck WHERE id = 'deck-v24'"),
                try String.fetchOne(
                    db, sql: "SELECT front_text FROM flashcard WHERE id = 'card-v24'"),
                try columnNames(table: "study_plan", db: db),
                try columnNames(table: "study_plan_item", db: db)
            )
        }

        #expect(snapshot.0 == "Existing Deck")
        #expect(snapshot.1 == "Existing Front")
        #expect(snapshot.2.contains("audiobook_id"))
        #expect(snapshot.3.contains("plan_id"))
        #expect(snapshot.3.contains("flashcard_id"))
    }

    private func makeV24Database() throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        let queue = try DatabaseQueue(path: ":memory:", configuration: config)
        try makeMigrator(includeV25: false).migrate(queue)
        return queue
    }

    private func makeMigrator(includeV25: Bool) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in try Schema_V1.migrate(db) }
        migrator.registerMigration("v2_timeline_support") { db in try Schema_V2.migrate(db) }
        migrator.registerMigration("v3_missing_indexes") { db in try Schema_V3.migrate(db) }
        migrator.registerMigration("v4_materialized_timeline") { db in try Schema_V4.migrate(db) }
        migrator.registerMigration("v5_epub_alignment") { db in try Schema_V5.migrate(db) }
        migrator.registerMigration("v6_indexes_and_fixes") { db in try Schema_V6.migrate(db) }
        migrator.registerMigration("v7_epub_reader_columns") { db in try Schema_V7.migrate(db) }
        migrator.registerMigration("v8_epub_block_word_count") { db in try Schema_V8.migrate(db) }
        migrator.registerMigration("v9_epub_block_markers") { db in try Schema_V9.migrate(db) }
        migrator.registerMigration("v10_epub_block_chapter_theme") { db in
            try Schema_V10.migrate(db)
        }
        migrator.registerMigration("v11_bookmark_pdf_state") { db in try Schema_V11.migrate(db) }
        migrator.registerMigration("v12_epub_block_front_matter") { db in
            try Schema_V12.migrate(db)
        }
        migrator.registerMigration("v13_epub_toc_entries") { db in try Schema_V13.migrate(db) }
        migrator.registerMigration("v14_capture_and_context") { db in try Schema_V14.migrate(db) }
        migrator.registerMigration("v15_anki_decks") { db in try Schema_V15.migrate(db) }
        migrator.registerMigration("v16_fsrs_cloze_transcript") { db in try Schema_V16.migrate(db) }
        migrator.registerMigration("v17_track_narration_voice") { db in try Schema_V17.migrate(db) }
        migrator.registerMigration("v18_abs_server") { db in try Schema_V18.migrate(db) }
        migrator.registerMigration("v19_word_timing") { db in try Schema_V19.migrate(db) }
        migrator.registerMigration("v20_batch_queue") { db in try Schema_V20.migrate(db) }
        migrator.registerMigration("v21_batch_kind") { db in try Schema_V21.migrate(db) }
        migrator.registerMigration("v22_fsrs_seed") { db in try Schema_V22.migrate(db) }
        migrator.registerMigration("v23_audiobook_abs_provenance") { db in
            try Schema_V23.migrate(db)
        }
        migrator.registerMigration("v24_feed_note_position_voice_memo") { db in
            try Schema_V24.migrate(db)
        }
        if includeV25 {
            migrator.registerMigration("v25_study_plans") { db in
                try Schema_V25.migrate(db)
            }
        }
        return migrator
    }

    private func seedLegacyStudyData(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book-v24', 'Existing Book', 3600, '2026-06-24T00:00:00Z')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO deck (id, name, source, created_at, modified_at)
                    VALUES (
                        'deck-v24',
                        'Existing Deck',
                        'manual',
                        '2026-06-24T00:00:00Z',
                        '2026-06-24T00:00:00Z'
                    )
                    """)
            try db.execute(
                sql: """
                    INSERT INTO flashcard (
                        id,
                        audiobook_id,
                        deck_id,
                        front_text,
                        back_text,
                        media_timestamp,
                        trigger_timing,
                        is_enabled
                    )
                    VALUES (
                        'card-v24',
                        'book-v24',
                        'deck-v24',
                        'Existing Front',
                        'Existing Back',
                        12,
                        'manualOnly',
                        1
                    )
                    """)
        }
    }

    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            try columnNames(table: table, db: database)
        }
    }

    private func columnNames(table: String, db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"] as? String })
    }

    private func indexNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }
}
