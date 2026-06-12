import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct SchemaV14Tests {

    @Test func v14CreatesSessionLocationTable() throws {
        let db = try DatabaseService(inMemory: ())
        let count = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_location'
                """) ?? 0
        }
        #expect(count == 1)
    }

    @Test func v14AddsBookmarkLocationColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(bookmark)").map { $0["name"] as? String ?? "" }
        })
        #expect(names.contains("latitude"))
        #expect(names.contains("longitude"))
        #expect(names.contains("place_name"))
    }

    @Test func v14AddsNoteGlobalAndVoiceMemoColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(note)").map { $0["name"] as? String ?? "" }
        })
        #expect(names.contains("is_global"))
        #expect(names.contains("voice_memo_path"))
    }

    @Test func v14AddsPlaybackEventStartedAtIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let count = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_playback_event_started_at'
                """) ?? 0
        }
        #expect(count == 1)
    }

    @Test func v14BackfillRenamesMistypedReviewEvents() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO real_time_event (id, event_type, started_at, ended_at)
                VALUES ('e1', 'flashcardReviewed', '2026-06-01T10:00:00Z', NULL)
                """)
            try Schema_V14.backfillEventIntegrity(db)
        }
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT event_type, ended_at FROM real_time_event WHERE id = 'e1'")
        }
        #expect(row?["event_type"] == "flashcard_reviewed")
        #expect(row?["ended_at"] == "2026-06-01T10:00:00Z")
    }

    @Test func v14BackfillClosesInstantaneousEvents() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO real_time_event (id, event_type, started_at, ended_at)
                VALUES ('e2', 'bookmark_created', '2026-06-02T08:00:00Z', NULL),
                       ('e3', 'playback_session', '2026-06-02T09:00:00Z', NULL)
                """)
            try Schema_V14.backfillEventIntegrity(db)
        }
        let bookmark = try db.read { db in
            try String.fetchOne(db, sql: "SELECT ended_at FROM real_time_event WHERE id = 'e2'")
        }
        let session = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT ended_at FROM real_time_event WHERE id = 'e3'")
        }
        #expect(bookmark == "2026-06-02T08:00:00Z")
        #expect(session?["ended_at"] == nil)
    }
}
