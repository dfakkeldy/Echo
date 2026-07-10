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
        try dao.save(
            AudiobookRecord(
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
        try dao.save(
            AudiobookRecord(
                id: "a", title: "A", author: "Jane Author", duration: 0,
                fileCount: nil, addedAt: "2026-06-27T00:00:00Z",
                isAvailable: true, authorSort: "jane author"))
        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.selectAxis(.author)
        #expect(vm.selectedAxis == .author)
        #expect(vm.sections.map(\.title) == ["Jane Author"])
    }

    @Test func reloadRegroupsAndCollapsesDuplicateEditions() async throws {
        // The duplicate-card bug end-to-end at the VM layer: an m4b row and a
        // separately imported epub row (author nil) must collapse into one card
        // once the background regroup pass lands, with the epub reachable as a
        // sibling edition.
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/VMDuneAudio/", title: "Dune", author: "Frank Herbert",
                duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true))
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/VMDuneText/", title: "Dune", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:01Z", isAvailable: true))

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        // The sync fetch publishes immediately (still two cards) …
        #expect(vm.sections.flatMap(\.books).count == 2)
        // … and the single-flight regroup pass re-publishes the collapsed shelf.
        await vm.awaitShelfRegroup()
        let books = vm.sections.flatMap(\.books)
        #expect(books.map(\.id) == ["file:///Lib/VMDuneAudio/"])
        #expect(
            vm.siblingEditions(of: books[0]).map(\.id) == ["file:///Lib/VMDuneText/"])

        // Reloading again is a stable no-op: still one card, no stacked passes.
        vm.reload()
        await vm.awaitShelfRegroup()
        #expect(vm.sections.flatMap(\.books).count == 1)
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
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('a', 'A', 100)")
            try db.execute(
                sql: """
                    INSERT INTO track (id, audiobook_id, title, duration, file_path, sort_order, narration_voice)
                    VALUES ('t1', 'a', 'c1', 50, '/a/c1.wav', 0, 'af_heart')
                    """)
        }
        let vm = LibraryViewModel(db: db, openBook: { _ in })

        vm.reload()

        #expect(vm.statusMap["a"]?.processing.contains(.narrated) == true)
    }

    @Test func siblingEditionsReturnOtherMembersInGroup() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "audio", title: "Dune", author: "Frank Herbert", duration: 100,
                fileCount: 1, addedAt: "2026-07-05T00:00:00Z", isAvailable: true,
                editionGroupID: "edition-dune"))
        try dao.save(
            AudiobookRecord(
                id: "text", title: "Dune", author: "Frank Herbert", duration: 0,
                fileCount: 0, addedAt: "2026-07-05T00:00:01Z", isAvailable: true,
                editionGroupID: "edition-dune"))
        let vm = LibraryViewModel(db: db, openBook: { _ in })

        vm.reload()
        let visible = try #require(vm.sections.first?.books.first)

        #expect(vm.siblingEditions(of: visible).map(\.id) == ["text"])
    }

    @Test func separateEditionOptsOutAndReloadsShelf() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "audio", title: "Dune", author: "Frank Herbert", duration: 100,
                fileCount: 1, addedAt: "2026-07-05T00:00:00Z", isAvailable: true,
                editionGroupID: "edition-dune"))
        try dao.save(
            AudiobookRecord(
                id: "text", title: "Dune", author: "Frank Herbert", duration: 0,
                fileCount: 0, addedAt: "2026-07-05T00:00:01Z", isAvailable: true,
                editionGroupID: "edition-dune"))
        let vm = LibraryViewModel(db: db, openBook: { _ in })

        vm.reload()
        let visible = try #require(vm.sections.first?.books.first)
        vm.separateEdition(visible)

        let separated = try #require(try dao.get("audio"))
        let sibling = try #require(try dao.get("text"))
        #expect(separated.editionGroupID == nil)
        #expect(separated.editionGroupOptOut == true)
        #expect(sibling.editionGroupID == nil)
        #expect(vm.sections.flatMap(\.books).map(\.id).sorted() == ["audio", "text"])
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
