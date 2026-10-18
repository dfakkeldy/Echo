// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@Suite struct SchemaV40NarrationQualityEvidenceTests {
    @Test func v39UpgradePreservesIssuesWithASROriginAndEvidenceColumn() throws {
        let writer = try DatabaseQueue()
        try migrateThroughV39(writer)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration) VALUES ('book', 'Book', 1);
                    INSERT INTO narration_quality_issue (
                        id, audiobook_id, audio_start_time, audio_end_time,
                        expected_text, heard_text, issue_type, confidence, status, created_at
                    ) VALUES ('issue', 'book', 0, 1, 'expected', 'heard', 'substitution', 1, 'open', 't0')
                """)
        }

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v40_narration_quality_issue_origin") { db in
            try Schema_V40.migrate(db)
        }
        try migrator.migrate(writer)

        try writer.read { db in
            let issue = try NarrationQualityIssueRecord.fetchOne(db, key: "issue")
            #expect(issue?.origin == NarrationQualityIssueOrigin.asr.rawValue)
            #expect(issue?.evidenceJSON == nil)
            #expect(try db.indexes(on: "narration_quality_issue").contains {
                $0.name == "idx_narration_quality_issue_book_origin_status"
            })
        }
    }
}

private func migrateThroughV39(_ writer: DatabaseWriter) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_create_schema") { try Schema_V1.migrate($0) }
    migrator.registerMigration("v25_study_plans") { try Schema_V25.migrate($0) }
    migrator.registerMigration("v26_timeline_segment_key") { try Schema_V26.migrate($0) }
    migrator.registerMigration("v27_library") { try Schema_V27.migrate($0) }
    migrator.registerMigration("v28_pdf_block_page") { try Schema_V28.migrate($0) }
    migrator.registerMigration("v29_audiobook_text_origin") { try Schema_V29.migrate($0) }
    migrator.registerMigration("v30_narration_quality_issue") { try Schema_V30.migrate($0) }
    migrator.registerMigration("v31_abs_server_multi") { try Schema_V31.migrate($0) }
    migrator.registerMigration("v32_narration_text") { try Schema_V32.migrate($0) }
    migrator.registerMigration("v33_study_plan_card_pacing") { try Schema_V33.migrate($0) }
    migrator.registerMigration("v34_study_auto_export") { try Schema_V34.migrate($0) }
    migrator.registerMigration("v35_library_edition_grouping") { try Schema_V35.migrate($0) }
    migrator.registerMigration("v36_code_language") { try Schema_V36.migrate($0) }
    migrator.registerMigration("v37_article_workshop") { try Schema_V37.migrate($0) }
    migrator.registerMigration("v37_repair_anthology_build_attempt_receipts") {
        try Schema_V37.repairBuildAttemptReceipts($0)
    }
    migrator.registerMigration("v38_generated_chapter_key") { try Schema_V38.migrate($0) }
    migrator.registerMigration("v39_article_sync") { try Schema_V39.migrate($0) }
    try migrator.migrate(writer)
}
