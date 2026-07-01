// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ABSServerDAOTests {
    private func makeRecord(id: String, addedAt: String) -> ABSServerRecord {
        ABSServerRecord(
            id: id,
            baseURL: "http://\(id).local:13378",
            username: "reader",
            defaultLibraryId: nil,
            addedAt: addedAt)
    }

    @Test func upsertInsertsNewServerWithoutActivatingIt() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-one", addedAt: "2026-06-28T00:00:00Z"))

        #expect(try dao.current() == nil)
        #expect(try dao.all().map(\.id) == ["server-one"])
    }

    @Test func setActiveExclusivelyActivatesOneServer() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-one", addedAt: "2026-06-28T00:00:00Z"))
        try dao.upsert(makeRecord(id: "server-two", addedAt: "2026-06-28T01:00:00Z"))
        try dao.setActive("server-one")

        try dao.setActive("server-two")

        let current = try #require(try dao.current())
        #expect(current.id == "server-two")
        let activeCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM abs_server WHERE is_active = 1") ?? 0
        }
        #expect(activeCount == 1)
    }

    @Test func allReturnsEverySavedServerNewestFirst() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-old", addedAt: "2026-06-28T00:00:00Z"))
        try dao.upsert(makeRecord(id: "server-new", addedAt: "2026-06-28T01:00:00Z"))

        #expect(try dao.all().map(\.id) == ["server-new", "server-old"])
    }

    @Test func deleteRemovesOnlyTheTargetedServer() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-one", addedAt: "2026-06-28T00:00:00Z"))
        try dao.upsert(makeRecord(id: "server-two", addedAt: "2026-06-28T01:00:00Z"))

        try dao.delete("server-one")

        #expect(try dao.all().map(\.id) == ["server-two"])
    }
}
