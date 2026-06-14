import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV17Tests {
    @Test func v17AddsNarrationVoiceColumnToTrack() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(track)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(names.contains("narration_voice"))
    }

    @Test func v17NarrationVoiceIsNullable() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('b1', 'Book', 0, '2026-06-13T00:00:00Z')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO track (id, audiobook_id, title, duration, file_path, is_enabled, sort_order)
                    VALUES ('t1', 'b1', 'Ch 1', 0, '/tmp/x.m4a', 1, 0)
                    """)
        }
        let v = try db.read { db in
            try String.fetchOne(db, sql: "SELECT narration_voice FROM track WHERE id = 't1'")
        }
        #expect(v == nil)
    }
}
