// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryRootsViewModelTests {
    @Test func reloadListsRootsAndRemoveDropsOne() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = LibraryRootDAO(db: db.writer)
        try dao.save(LibraryRootRecord(
            id: "r1", displayName: "A", bookmark: Data(),
            addedAt: "2026-06-01T00:00:00Z", lastScannedAt: nil))
        try dao.save(LibraryRootRecord(
            id: "r2", displayName: "B", bookmark: Data(),
            addedAt: "2026-06-27T00:00:00Z", lastScannedAt: nil))

        let vm = LibraryRootsViewModel(db: db)
        vm.reload()
        #expect(vm.roots.map(\.id) == ["r2", "r1"])

        await vm.remove(rootID: "r1", forgetBooks: true)

        #expect(vm.roots.map(\.id) == ["r2"])
    }
}
