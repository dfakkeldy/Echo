import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct PlaybackEventDAOTests {

    private func makeDB() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book1', 'Test Book', 3600, '2026-06-01T00:00:00Z')
                """)
        }
        return db
    }

    @Test func insertOpenWritesSelfConsistentRow() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let id = try dao.insertOpen(
            audiobookID: "book1", trackID: nil,
            startedAt: start, startPosition: 120, speed: 1.5, source: "user"
        )
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM playback_event WHERE id = ?", arguments: [id])
        }
        // Self-consistent zero-length segment: crash before first heartbeat
        // still leaves valid (if tiny) data — no NULLs ever reach aggregation.
        #expect(row?["ended_at"] == start.ISO8601Format())
        #expect(row?["end_position"] == 120.0)
        #expect(row?["speed"] == 1.5)
        #expect(row?["event_type"] == "play")
    }

    @Test func extendUpdatesEndFields() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let id = try dao.insertOpen(
            audiobookID: "book1", trackID: nil,
            startedAt: start, startPosition: 120, speed: 1.5, source: "user"
        )
        try dao.extend(id: id, endedAt: start.addingTimeInterval(30), endPosition: 165)
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT ended_at, end_position FROM playback_event WHERE id = ?", arguments: [id])
        }
        #expect(row?["ended_at"] == start.addingTimeInterval(30).ISO8601Format())
        #expect(row?["end_position"] == 165.0)
    }

    @Test func deleteRemovesDiscardedMicroSegment() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        let id = try dao.insertOpen(
            audiobookID: "book1", trackID: nil,
            startedAt: Date(), startPosition: 0, speed: 1.0, source: "user"
        )
        try dao.delete(id: id)
        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_event") ?? 0
        }
        #expect(count == 0)
    }

    @Test func insertOpenRejectsUnknownAudiobook() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        #expect(throws: (any Error).self) {
            _ = try dao.insertOpen(
                audiobookID: "missing", trackID: nil,
                startedAt: Date(), startPosition: 0, speed: 1.0, source: "user"
            )
        }
    }
}
