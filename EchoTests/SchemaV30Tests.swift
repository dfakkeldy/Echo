// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV30Tests {
    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    private func indexNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    @Test func v30CreatesNarrationQualityIssueTable() throws {
        let db = try DatabaseService(inMemory: ())
        let cols = try columnNames(table: "narration_quality_issue", db: db)
        for expected in [
            "id", "audiobook_id", "source_block_id", "source_word_start", "source_word_end",
            "audio_start_time", "audio_end_time", "expected_text", "heard_text", "issue_type",
            "confidence", "suggested_fix_json", "status", "created_at", "resolved_at",
        ] {
            #expect(cols.contains(expected))
        }
    }

    @Test func v30CreatesStatusIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let idx = try indexNames(table: "narration_quality_issue", db: db)
        #expect(idx.contains("idx_narration_quality_issue_book_status"))
    }
}
