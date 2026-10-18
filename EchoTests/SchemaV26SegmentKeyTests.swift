// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV26SegmentKeyTests {
    @Test func v26AddsNullableSegmentKeyToTimelineItem() throws {
        let db = try DatabaseService(inMemory: ())
        let segmentColumn = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(timeline_item)")
                .first { row in
                    let name: String = row["name"]
                    return name == "segment_key"
                }
        }
        let row = try #require(segmentColumn)
        let notNull: Int = row["notnull"]

        #expect(notNull == 0)
    }

    @Test func migratingFromV25PreservesTimelineRowsAndLeavesSegmentKeyNil() throws {
        let queue = try makePreSegmentKeyDatabase()
        try seedTimelineRow(in: queue)

        try makeMigrator(includeV26: true).migrate(queue)

        let snapshot = try queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM timeline_item"),
                try String.fetchOne(
                    db,
                    sql: "SELECT segment_key FROM timeline_item WHERE id = 'ti-v25'")
            )
        }

        #expect(snapshot.0 == 1)
        #expect(snapshot.1 == nil)
    }

    private func makePreSegmentKeyDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        let queue = try DatabaseQueue(path: ":memory:", configuration: config)
        try makeMigrator(includeV26: false).migrate(queue)
        return queue
    }

    private func makeMigrator(includeV26: Bool) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in try Schema_V1.migrate(db) }
        migrator.registerMigration("v25_study_plans") { db in
            try Schema_V25.migrate(db)
        }
        if includeV26 {
            migrator.registerMigration("v26_timeline_segment_key") { db in
                try Schema_V26.migrate(db)
            }
        }
        return migrator
    }

    private func seedTimelineRow(in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('book-v25', 'Existing Book', 3600, '2026-06-25T00:00:00Z')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (
                        id,
                        audiobook_id,
                        item_type,
                        title,
                        audio_start_time,
                        audio_end_time,
                        granularity_level,
                        is_enabled
                    )
                    VALUES (
                        'ti-v25',
                        'book-v25',
                        'textSegment',
                        'Existing row',
                        0,
                        5,
                        1,
                        1
                    )
                    """)
        }
    }
}
