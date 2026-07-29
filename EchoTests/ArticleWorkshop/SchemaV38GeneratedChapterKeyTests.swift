// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite("Schema V38 generated chapter key")
struct SchemaV38GeneratedChapterKeyTests {
    @Test("V37 upgrade preserves existing generic rows and user fields")
    @MainActor
    func upgradePreservesExistingRows() throws {
        let queue = try DatabaseQueue()
        var migrator = Self.v37Migrator()
        try migrator.migrate(queue)

        try queue.write { database in
            var audiobook = AudiobookRecord(
                id: "book-v37",
                title: "Existing book",
                author: "Reader",
                duration: 42,
                fileCount: 1,
                addedAt: "2026-07-28T00:00:00Z")
            try audiobook.insert(database)
            try database.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index,
                        sequence_index, block_kind, text, html_content, card_color,
                        chapter_theme_color, chapter_index, is_hidden, hidden_reason,
                        is_front_matter, word_count, narration_text, created_at, modified_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "epub-book-v37-s0-b0", audiobook.id, "chapter.xhtml", 0, 0,
                    0, EPubBlockRecord.Kind.paragraph.rawValue, "Existing text",
                    "<p>Existing text</p>", "#123456", "#654321", 3, true, "reader",
                    false, 2, "Existing narration", "2026-07-28T00:00:00Z",
                    "2026-07-28T01:00:00Z",
                ])
        }

        var v38 = DatabaseMigrator()
        v38.registerMigration("v38_generated_chapter_key") { database in
            try Schema_V38.migrate(database)
        }
        try v38.migrate(queue)

        try queue.read { database in
            let columns = try database.columns(in: EPubBlockRecord.databaseTableName)
            #expect(columns.contains { $0.name == "source_chapter_key" && !$0.isNotNull })
            let fetched = try EPubBlockRecord.fetchOne(database, key: "epub-book-v37-s0-b0")
            let block = try #require(fetched)
            #expect(block.sourceChapterKey == nil)
            #expect(block.text == "Existing text")
            #expect(block.cardColor == "#123456")
            #expect(block.chapterThemeColor == "#654321")
            #expect(block.isHidden)
            #expect(block.hiddenReason == "reader")
            #expect(block.narrationText == "Existing narration")
        }
    }

    @Test("Fresh database has the same nullable generated chapter key column")
    @MainActor
    func freshSchemaParity() throws {
        let service = try DatabaseService(inMemory: ())
        try service.read { database in
            let columns = try database.columns(in: EPubBlockRecord.databaseTableName)
            #expect(columns.contains { $0.name == "source_chapter_key" && !$0.isNotNull })
        }
    }

    private static func v37Migrator() -> DatabaseMigrator {
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
        return migrator
    }
}
