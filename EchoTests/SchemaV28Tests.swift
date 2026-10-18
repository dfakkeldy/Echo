// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV28Tests {
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

    @Test func v28CreatesPdfBlockPageTable() throws {
        let db = try DatabaseService(inMemory: ())
        let cols = try columnNames(table: "pdf_block_page", db: db)
        #expect(cols.contains("id"))
        #expect(cols.contains("audiobook_id"))
        #expect(cols.contains("epub_block_id"))
        #expect(cols.contains("page_index"))
    }

    @Test func v28CreatesIndexes() throws {
        let db = try DatabaseService(inMemory: ())
        let idx = try indexNames(table: "pdf_block_page", db: db)
        #expect(idx.contains("idx_pdf_block_page_book"))
        #expect(idx.contains("idx_pdf_block_page_page"))
    }

    @Test func daoRoundTrips() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = PDFBlockPageDAO(db: db.writer)
        try dao.insert(
            PDFBlockPageRecord(id: nil, audiobookID: "b1", epubBlockID: "blk1", pageIndex: 3))
        #expect(try dao.pageIndex(for: "b1", epubBlockID: "blk1") == 3)
        #expect(try dao.pageIndex(for: "b1", epubBlockID: "nope") == nil)
        try dao.deleteAll(for: "b1")
        #expect(try dao.pageIndex(for: "b1", epubBlockID: "blk1") == nil)
    }
}
