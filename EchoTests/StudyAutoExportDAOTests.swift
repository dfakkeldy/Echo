// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct StudyAutoExportDAOTests {
    @Test func destinationRoundTripsAndClears() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = StudyAutoExportDAO(db: db.writer)

        #expect(try dao.destination() == nil)

        try dao.saveDestination(bookmark: Data([0x01, 0x02]), displayPath: "/Users/sample/MacroMark")
        let saved = try #require(try dao.destination())
        #expect(saved.bookmark == Data([0x01, 0x02]))
        #expect(saved.displayPath == "/Users/sample/MacroMark")
        #expect(saved.needsRepick == false)

        try dao.setNeedsRepick(true)
        #expect(try #require(try dao.destination()).needsRepick == true)

        try dao.saveDestination(bookmark: Data([0x03]), displayPath: "/Users/sample/Inbox")
        let replaced = try #require(try dao.destination())
        #expect(replaced.bookmark == Data([0x03]))
        #expect(replaced.needsRepick == false)

        try dao.clearDestination()
        #expect(try dao.destination() == nil)
    }

    @Test func dirtyLifecycleSurvivesSuccessAndFailure() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = StudyAutoExportDAO(db: db.writer)

        try dao.markDirty(bookIDs: ["book-a", "book-b"])
        #expect(try dao.dirtyStates().map(\.bookId) == ["book-a", "book-b"])

        try dao.recordSuccess(
            bookID: "book-a",
            fileName: "A-12345678.md",
            contentSha256: "abc",
            at: "2026-07-02T12:00:00Z"
        )
        #expect(try dao.dirtyStates().map(\.bookId) == ["book-b"])
        let stateA = try #require(try dao.state(for: "book-a"))
        #expect(stateA.dirty == false)
        #expect(stateA.fileName == "A-12345678.md")
        #expect(stateA.contentSha256 == "abc")
        #expect(stateA.lastError == nil)

        try dao.recordFailure(bookID: "book-b", error: "disk full")
        let stateB = try #require(try dao.state(for: "book-b"))
        #expect(stateB.dirty == true)
        #expect(stateB.lastError == "disk full")

        try dao.markDirty(bookIDs: ["book-a"])
        let redirty = try #require(try dao.state(for: "book-a"))
        #expect(redirty.dirty == true)
        #expect(redirty.fileName == "A-12345678.md")

        try dao.removeState(bookID: "book-a")
        #expect(try dao.state(for: "book-a") == nil)
    }
}
