// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct SchemaV36CodeLanguageTests {
    @Test func codeLanguageColumnRoundTrips() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write {
            try $0.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('test-book', 'Test Book', 0)"
            )
        }
        var block = EPubBlockRecord(
            id: "epub-test-s0-b0",
            audiobookID: "test-book",
            spineHref: "ch01.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.code.rawValue,
            text: "print(\"hello\")",
            htmlContent: nil,
            cardColor: nil,
            imagePath: nil,
            chapterIndex: nil,
            isHidden: false,
            hiddenReason: nil,
            wordCount: 1,
            markers: nil,
            textFormats: nil,
            narrationText: "Code listing.",
            codeLanguage: "python",
            createdAt: nil,
            modifiedAt: nil)
        try db.writer.write { try block.insert($0) }
        let fetched = try db.writer.read {
            try EPubBlockRecord.fetchOne($0, key: "epub-test-s0-b0")
        }
        #expect(fetched?.codeLanguage == "python")
        #expect(fetched.flatMap { EPubBlockRecord.Kind(rawValue: $0.blockKind) } == .code)
    }

    @Test func v36PreservesExistingV35Block() throws {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE epub_block (
                    id TEXT PRIMARY KEY,
                    audiobook_id TEXT NOT NULL,
                    spine_href TEXT NOT NULL,
                    spine_index INTEGER NOT NULL,
                    block_index INTEGER NOT NULL,
                    sequence_index INTEGER NOT NULL,
                    block_kind TEXT NOT NULL,
                    text TEXT,
                    html_content TEXT,
                    card_color TEXT,
                    image_path TEXT,
                    chapter_index INTEGER,
                    is_hidden INTEGER NOT NULL,
                    hidden_reason TEXT,
                    word_count INTEGER,
                    markers TEXT,
                    text_formats TEXT,
                    chapter_theme_color TEXT,
                    is_front_matter INTEGER NOT NULL DEFAULT 0,
                    narration_text TEXT,
                    created_at TEXT,
                    modified_at TEXT
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO epub_block (
                        id, audiobook_id, spine_href, spine_index, block_index,
                        sequence_index, block_kind, text, is_hidden,
                        is_front_matter, narration_text
                    ) VALUES (
                        'existing-block', 'book', 'chapter.xhtml', 0, 0,
                        0, 'paragraph', 'Preserved', 0, 0, 'Narrated'
                    )
                    """)
        }

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v36_code_language") { db in
            try Schema_V36.migrate(db)
        }
        try migrator.migrate(db)

        let values = try db.read { db in
            (
                try String.fetchOne(db, sql: "SELECT text FROM epub_block WHERE id = 'existing-block'"),
                try String.fetchOne(db, sql: "SELECT narration_text FROM epub_block WHERE id = 'existing-block'"),
                try String.fetchOne(db, sql: "SELECT code_language FROM epub_block WHERE id = 'existing-block'")
            )
        }
        #expect(values.0 == "Preserved")
        #expect(values.1 == "Narrated")
        #expect(values.2 == nil)
    }
}
