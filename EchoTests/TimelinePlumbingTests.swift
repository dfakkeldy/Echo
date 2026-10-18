// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct TimelinePlumbingTests {

    // MARK: - SafeFileName

    @Test func safeFileNameRemovesFileScheme() {
        let result = SafeFileName.fromAudiobookID("file:///path/to/book.m4b")
        #expect(!result.contains("file://"))
        #expect(result.contains("book.m4b"))
    }

    @Test func safeFileNameReplacesInvalidCharacters() {
        let result = SafeFileName.fromAudiobookID("file:///path/to/book:with*invalid?chars")
        #expect(!result.contains(":"))
        #expect(!result.contains("*"))
        #expect(!result.contains("?"))
    }

    @Test func safeFileNameHandlesEmptyInput() {
        let result = SafeFileName.fromAudiobookID("")
        #expect(!result.isEmpty)
    }

    @Test func safeFileNameHandlesPlainString() {
        let result = SafeFileName.fromAudiobookID("simple-audiobook-id")
        #expect(result == "simple-audiobook-id")
    }

    // MARK: - Baseline timeline schema

    @Test func baselineSchemaHasRequiredTimelineColumns() throws {
        let db = try DatabaseService(inMemory: ())

        let columnNames = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(timeline_item)").map {
                $0["name"] as? String ?? ""
            }
        }
        let nameSet = Set(columnNames)

        #expect(nameSet.contains("id"))
        #expect(nameSet.contains("audiobook_id"))
        #expect(nameSet.contains("item_type"))
        #expect(nameSet.contains("audio_start_time"))
        #expect(nameSet.contains("epub_sequence_index"))
        #expect(nameSet.contains("is_enabled"))
        #expect(nameSet.contains("source_table"))
    }

    // MARK: - Baseline EPUB block schema

    @Test func baselineSchemaHasEPUBBlockTable() throws {
        let db = try DatabaseService(inMemory: ())

        let tables = try db.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master WHERE type='table' AND name='epub_block'
                    """)
        }
        #expect(!tables.isEmpty)
    }
}
