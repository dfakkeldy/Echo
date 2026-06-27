// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryRootDAOTests {
    @Test func savesFetchesAndDeletesRoots() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = LibraryRootDAO(db: db.writer)

        let root = LibraryRootRecord(
            id: "root-1", displayName: "Audiobooks",
            bookmark: Data([0x01, 0x02]), addedAt: "2026-06-27T00:00:00Z",
            lastScannedAt: nil)
        try dao.save(root)

        #expect(try dao.get("root-1")?.displayName == "Audiobooks")
        #expect(try dao.all().count == 1)

        try dao.delete(id: "root-1")
        #expect(try dao.get("root-1") == nil)
    }

    @Test func allReturnsRootsNewestFirst() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = LibraryRootDAO(db: db.writer)
        try dao.save(
            LibraryRootRecord(
                id: "a", displayName: "A", bookmark: Data(), addedAt: "2026-06-01T00:00:00Z",
                lastScannedAt: nil))
        try dao.save(
            LibraryRootRecord(
                id: "b", displayName: "B", bookmark: Data(), addedAt: "2026-06-27T00:00:00Z",
                lastScannedAt: nil))
        #expect(try dao.all().map(\.id) == ["b", "a"])
    }
}
