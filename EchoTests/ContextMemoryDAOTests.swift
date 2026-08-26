// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing
@testable import Echo

@MainActor
@Suite struct ContextMemoryDAOTests {
    @Test func deleteAllClearsStoredPlacesWithoutDeletingUserRecords() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ContextMemoryDAO(db: database.writer)

        try database.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book', 'Book', 3600, '2026-06-25T08:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO bookmark (
                    id, audiobook_id, title, media_timestamp,
                    latitude, longitude, place_name
                )
                VALUES ('bookmark', 'book', 'Bookmark', 42, 44.65, -63.57, 'Halifax')
                """)
            try db.execute(sql: """
                INSERT INTO playback_event (
                    id, audiobook_id, started_at, ended_at,
                    start_position, end_position, speed, event_type
                )
                VALUES (1, 'book', '2026-06-25T08:00:00Z', '2026-06-25T08:10:00Z', 0, 600, 1.0, 'play')
                """)
            try db.execute(sql: """
                INSERT INTO session_location (
                    playback_event_id, latitude, longitude, place_name, created_at
                )
                VALUES (1, 44.65, -63.57, 'Halifax', '2026-06-25T08:10:00Z')
                """)
        }

        let summary = try dao.deleteAll()

        #expect(summary.bookmarkCount == 1)
        #expect(summary.sessionLocationCount == 1)

        try database.read { db in
            let bookmarkCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark")
            #expect(bookmarkCount == 1)

            let locationCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_location")
            #expect(locationCount == 0)

            let fetchedRow = try Row.fetchOne(db, sql: """
                SELECT latitude, longitude, place_name
                FROM bookmark
                WHERE id = 'bookmark'
                """)
            let row = try #require(fetchedRow)
            #expect((row["latitude"] as Double?) == nil)
            #expect((row["longitude"] as Double?) == nil)
            #expect((row["place_name"] as String?) == nil)
        }
    }
}
