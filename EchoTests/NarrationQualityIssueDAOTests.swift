// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQualityIssueDAOTests {
    private func seedBook(_ id: String, db: DatabaseService) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [id, "Test", 3600.0])
        }
    }

    private func make(_ id: String, book: String, status: String) -> NarrationQualityIssueRecord {
        NarrationQualityIssueRecord(
            id: id, audiobookID: book, sourceBlockID: "blk1",
            sourceWordStart: 2, sourceWordEnd: 3, audioStartTime: 1.0, audioEndTime: 2.0,
            expectedText: "colonel", heardText: "kernel",
            issueType: NarrationQAIssueType.substitution.rawValue, confidence: 0.8,
            suggestedFixJSON: nil, status: status,
            createdAt: "2026-06-29T00:00:00Z", resolvedAt: nil)
    }

    @Test func insertsAndFetchesByBook() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([
            make("i1", book: "b1", status: "open"), make("i2", book: "b1", status: "open"),
        ])
        #expect(try dao.issues(for: "b1").count == 2)
    }

    @Test func filtersByStatusAndUpdatesStatus() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([make("i1", book: "b1", status: "open")])
        try dao.updateStatus(id: "i1", status: "resolved", resolvedAt: "2026-06-29T01:00:00Z")
        #expect(try dao.issues(for: "b1", status: "open").isEmpty)
        #expect(try dao.issues(for: "b1", status: "resolved").count == 1)
    }

    @Test func deletesByBookAndByBlockIDs() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([make("i1", book: "b1", status: "open")])
        try dao.deleteAll(for: "b1", blockIDs: ["blk1"])
        #expect(try dao.issues(for: "b1").isEmpty)
        try dao.insert([make("i2", book: "b1", status: "open")])
        try dao.deleteAll(for: "b1")
        #expect(try dao.issues(for: "b1").isEmpty)
    }
}
