// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct CaptureSchemaBaselineTests {

    @Test func baselineCreatesSessionLocationTable() throws {
        let db = try DatabaseService(inMemory: ())
        let count = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_location'
                """) ?? 0
        }
        #expect(count == 1)
    }

    @Test func baselineIncludesBookmarkLocationColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(bookmark)").map { $0["name"] as? String ?? "" }
        })
        #expect(names.contains("latitude"))
        #expect(names.contains("longitude"))
        #expect(names.contains("place_name"))
    }

    @Test func baselineIncludesNoteGlobalAndVoiceMemoColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(note)").map { $0["name"] as? String ?? "" }
        })
        #expect(names.contains("is_global"))
        #expect(names.contains("voice_memo_path"))
    }

    @Test func baselineIncludesPlaybackEventStartedAtIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let count = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_playback_event_started_at'
                """) ?? 0
        }
        #expect(count == 1)
    }

}
