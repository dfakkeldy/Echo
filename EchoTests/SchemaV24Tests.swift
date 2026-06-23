// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV24Tests {
    @Test func v24AddsEpubBlockIDColumnToNote() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(note)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(columns.contains("epub_block_id"))
    }

    @Test func v24CreatesVoiceMemoTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(voice_memo)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(columns.contains("id"))
        #expect(columns.contains("audiobook_id"))
        #expect(columns.contains("epub_block_id"))
        #expect(columns.contains("media_timestamp"))
        #expect(columns.contains("file_path"))
        #expect(columns.contains("duration"))
        #expect(columns.contains("is_enabled"))
        #expect(columns.contains("created_at"))
        #expect(columns.contains("modified_at"))
    }

    @Test func v24CreatesVoiceMemoIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let indexNames = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(voice_memo)").map {
                $0["name"] as? String ?? ""
            }
        }
        #expect(indexNames.contains("idx_voice_memo_audiobook_time"))
    }
}
