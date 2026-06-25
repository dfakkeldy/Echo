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

    @Test func migratingFromBaselinePreservesDecksAndFlashcards() throws {
        let queue = try makePreStudyPlanDatabase()
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

    private func makePreStudyPlanDatabase() throws -> DatabaseQueue {
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
