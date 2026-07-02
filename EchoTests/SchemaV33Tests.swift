// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV33Tests {
    @Test func databaseServiceAddsStudyPlanCardPacingColumns() throws {
        let service = try DatabaseService(inMemory: ())
        let columns = try studyPlanColumns(in: service)

        #expect(columns["new_cards_per_day"]?.type.uppercased() == "INTEGER")
        #expect(columns["new_cards_per_day"]?.notNull == true)
        #expect(columns["new_cards_per_day"]?.defaultValue == "2")
        #expect(columns["chapter_pacing"]?.type.uppercased() == "TEXT")
        #expect(columns["chapter_pacing"]?.notNull == true)
        #expect(columns["chapter_pacing"]?.defaultValue == "'card_drain'")
    }

    @Test func v33BackfillsExistingStudyPlans() throws {
        let queue = try DatabaseQueue()

        try queue.write { db in
            try Schema_V1.migrate(db)
            try Schema_V25.migrate(db)
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book', 'Study Book', 3600, '2026-06-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO study_plan (
                        id, audiobook_id, cadence_unit, new_chapter_limit, include_images,
                        queue_mode_default, catch_up_policy, start_date, is_paused, created_at,
                        modified_at
                    ) VALUES (
                        'plan', 'book', 'day', 1, 0, 'book_by_book', 'gentle',
                        '2026-06-01T00:00:00Z', 0, '2026-06-01T00:00:00Z',
                        '2026-06-01T00:00:00Z'
                    )
                    """
            )

            try Schema_V33.migrate(db)
        }

        let row = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT new_cards_per_day, chapter_pacing FROM study_plan WHERE id = 'plan'"
            )
        }

        #expect(row?["new_cards_per_day"] as Int? == 2)
        #expect(row?["chapter_pacing"] as String? == StudyPlanChapterPacing.cardDrain.rawValue)
    }

    private func studyPlanColumns(in service: DatabaseService) throws -> [String: ColumnInfo] {
        try service.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(study_plan)")
            return Dictionary(
                uniqueKeysWithValues: rows.map { row in
                    (
                        row["name"] as String,
                        ColumnInfo(
                            type: row["type"] as String,
                            notNull: (row["notnull"] as Int) == 1,
                            defaultValue: row["dflt_value"] as? String
                        )
                    )
                }
            )
        }
    }

    private struct ColumnInfo {
        let type: String
        let notNull: Bool
        let defaultValue: String?
    }
}
