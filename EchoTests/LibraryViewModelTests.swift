// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryViewModelTests {
    @Test func smartLandingPrefersCurrentBookElseLibrary() {
        #expect(LibraryViewModel.smartLandingTab(hasCurrentBook: true) == .nowPlaying)
        #expect(LibraryViewModel.smartLandingTab(hasCurrentBook: false) == .library)
    }

    @Test func reloadLoadsAvailableBooksForAxis() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(AudiobookRecord(
            id: "a", title: "Atomic Habits", author: "James Clear", duration: 0,
            fileCount: nil, addedAt: "2026-06-27T00:00:00Z", isAvailable: true))
        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        #expect(vm.sections.flatMap(\.books).map(\.id) == ["a"])
        #expect(vm.isEmpty == false)
    }

    @Test func selectingAxisReloadsSections() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(AudiobookRecord(
            id: "a", title: "A", author: "Jane Author", duration: 0,
            fileCount: nil, addedAt: "2026-06-27T00:00:00Z",
            isAvailable: true, authorSort: "jane author"))
        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.selectAxis(.author)
        #expect(vm.selectedAxis == .author)
        #expect(vm.sections.map(\.title) == ["Jane Author"])
    }

    @Test func openResolvesAndCallsOpenBookForStandaloneBook() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        let book = AudiobookRecord(
            id: "file:///Books/Dune/", title: "Dune", author: nil, duration: 0,
            fileCount: nil, addedAt: "2026-06-27T00:00:00Z", isAvailable: true)
        try dao.save(book)
        var opened: LibraryOpenTarget?
        let vm = LibraryViewModel(db: db, openBook: { opened = $0 })
        vm.open(book)
        #expect(opened?.url.absoluteString == "file:///Books/Dune/")
        #expect(opened?.scopedRoot == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test func openSetsErrorWhenBookUnresolvable() throws {
        let db = try DatabaseService(inMemory: ())
        let vm = LibraryViewModel(db: db, openBook: { _ in })
        let bad = AudiobookRecord(
            id: "not a url", title: "X", author: nil, duration: 0, fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z", isAvailable: true)
        vm.open(bad)
        #expect(vm.errorMessage != nil)
    }

    @Test func reloadPopulatesStatusMapForShelfDots() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('a', 'A', 100)")
            try db.execute(sql: """
                INSERT INTO track (id, audiobook_id, title, duration, file_path, sort_order, narration_voice)
                VALUES ('t1', 'a', 'c1', 50, '/a/c1.wav', 0, 'af_heart')
                """)
        }
        let vm = LibraryViewModel(db: db, openBook: { _ in })

        vm.reload()

        #expect(vm.statusMap["a"]?.processing.contains(.narrated) == true)
    }

    @Test func openUnavailableBookStartsRecoveryInsteadOfOpening() throws {
        let db = try DatabaseService(inMemory: ())
        let book = AudiobookRecord(
            id: "file:///Books/Moved/", title: "Moved", author: nil, duration: 0,
            fileCount: nil, addedAt: "2026-06-27T00:00:00Z", isAvailable: false)
        var didOpen = false
        let vm = LibraryViewModel(db: db, openBook: { _ in didOpen = true })

        vm.open(book)

        #expect(didOpen == false)
        #expect(vm.pendingRecoveryBook?.id == book.id)
    }
}
