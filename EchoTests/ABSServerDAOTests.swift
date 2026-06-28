// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ABSServerDAOTests {
    @Test func saveReplacesPreviousCurrentServerRecord() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        let first = ABSServerRecord(
            id: "server-one",
            baseURL: "http://one.local:13378",
            username: "reader",
            defaultLibraryId: "lib-one",
            addedAt: "2026-06-28T00:00:00Z")
        let second = ABSServerRecord(
            id: "server-two",
            baseURL: "http://two.local:13378",
            username: "reader",
            defaultLibraryId: "lib-two",
            addedAt: "2026-06-28T01:00:00Z")

        try dao.save(first)
        try dao.save(second)

        let current = try #require(try dao.current())
        let count = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM abs_server") ?? 0
        }
        let ids = try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM abs_server ORDER BY id")
        }

        #expect(current.id == second.id)
        #expect(count == 1)
        #expect(ids == [second.id])
    }
}
