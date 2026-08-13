// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV27Tests {
    @Test func v27AddsLibraryColumnsToAudiobook() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "audiobook", db: db)

        #expect(columns.contains("cover_art_path"))
        #expect(columns.contains("narrator"))
        #expect(columns.contains("index_state"))
        #expect(columns.contains("is_available"))
        #expect(columns.contains("last_seen_at"))
        #expect(columns.contains("author_sort"))
        #expect(columns.contains("source_root_id"))
    }

    @Test func v27CreatesLibraryRootTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "library_root", db: db)

        #expect(columns.contains("id"))
        #expect(columns.contains("display_name"))
        #expect(columns.contains("bookmark"))
        #expect(columns.contains("added_at"))
        #expect(columns.contains("last_scanned_at"))
    }

    @Test func v27CreatesLibraryIndexes() throws {
        let db = try DatabaseService(inMemory: ())
        let indexes = try indexNames(table: "audiobook", db: db)
        #expect(indexes.contains("idx_audiobook_author_sort"))
        #expect(indexes.contains("idx_audiobook_available_added"))
        #expect(indexes.contains("idx_audiobook_source_root"))
    }

    @Test func existingAudiobookRowsDefaultSanely() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('b1', 'T', 3600)")
        }
        let row = try db.writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT index_state, is_available FROM audiobook WHERE id = 'b1'")
        }
        #expect(row?["index_state"] as? Int64 == 0)
        #expect(row?["is_available"] as? Int64 == 1)
    }

    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    private func indexNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }
}
