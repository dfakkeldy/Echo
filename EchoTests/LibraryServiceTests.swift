// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryServiceTests {
    private func fixedNow() -> String { "2026-06-27T00:00:00Z" }

    @Test func rescanInsertsShallowRowsForNewBooks() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        // Register a REAL temp dir so the bookmark resolves and rescan's
        // stale-bookmark guard passes. The injected discover ignores the resolved
        // URL and returns a fixed synthetic book, so id assertions stay deterministic.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)

        let discovered = [
            DiscoveredBook(
                folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
                audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)
        ]
        let result = try service.rescan(root: root, discover: { _ in discovered }, now: fixedNow)

        #expect(result.added == 1)
        let book = try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")
        #expect(book?.indexState == 0)
        #expect(book?.isAvailable == true)
        #expect(book?.sourceRootID == root.id)
    }

    @Test func rescanHidesBooksThatVanished() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        // Real temp dir so both rescans clear the stale-bookmark guard.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)

        _ = try service.rescan(root: root, discover: { _ in [dune] }, now: fixedNow)
        let result = try service.rescan(root: root, discover: { _ in [] }, now: fixedNow)

        #expect(result.hidden == 1)
        #expect(try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")?.isAvailable == false)
    }

    @Test func rescanAppliesInjectedMetadata() async throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        // Correction B: register a REAL temp dir so the bookmark resolves and the
        // stale-bookmark guard passes. The injected discover ignores the resolved
        // URL and returns a fixed synthetic book, so id assertions stay deterministic.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)

        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)
        let covers = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: covers) }

        _ = try await service.rescan(
            root: root,
            discover: { _ in [dune] },
            readMetadata: { _ in
                LibraryScanner.ScannedMetadata(
                    title: "Dune", author: "Tolkien, J.R.R.", narrator: "Scott Brick",
                    duration: 4242, coverImageData: Data([0xFF, 0xD8]))
            },
            coversDir: covers,
            now: fixedNow)

        let book = try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")
        #expect(book?.title == "Dune")
        #expect(book?.author == "Tolkien, J.R.R.")
        #expect(book?.narrator == "Scott Brick")
        #expect(book?.duration == 4242)
        #expect(book?.authorSort == "j.r.r. tolkien")
        #expect(book?.coverArtPath != nil)
    }

    @Test func registerRootPersistsBookmarkAndRow() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try service.registerRoot(url: tmp, now: fixedNow)
        #expect(try LibraryRootDAO(db: db.writer).get(root.id) != nil)
        #expect(root.bookmark.isEmpty == false)
    }

    @Test func booksHidesUnavailableByDefault() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "a", title: "A", author: nil, duration: 0, fileCount: nil,
                addedAt: "2026-06-27T00:00:00Z", isAvailable: true))
        try dao.save(
            AudiobookRecord(
                id: "b", title: "B", author: nil, duration: 0, fileCount: nil,
                addedAt: "2026-06-26T00:00:00Z", isAvailable: false))

        let service = LibraryService(db: db)
        #expect(try service.books(includeUnavailable: false).map(\.id) == ["a"])
        #expect(try service.books(includeUnavailable: true).map(\.id).sorted() == ["a", "b"])
    }

    @Test func sectionsByAuthorGroupOnNormalizedKey() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "1", title: "X", author: "Tolkien, J.R.R.", duration: 0, fileCount: nil,
                addedAt: "2026-06-27T00:00:00Z", isAvailable: true, authorSort: "j.r.r. tolkien"))
        try dao.save(
            AudiobookRecord(
                id: "2", title: "Y", author: "J.R.R. Tolkien", duration: 0, fileCount: nil,
                addedAt: "2026-06-26T00:00:00Z", isAvailable: true, authorSort: "j.r.r. tolkien"))

        let service = LibraryService(db: db)
        let sections = try service.sections(by: .author, includeUnavailable: false)
        #expect(sections.count == 1)
        #expect(sections.first?.books.count == 2)
    }

    @Test func urlForOpeningResolvesViaRoot() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)

        // Create a REAL temp directory so the bookmark resolves.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try service.registerRoot(url: tmp, now: fixedNow)

        // A child folder under the temp root.
        let childURL = tmp.appendingPathComponent("MyBook", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        let book = AudiobookRecord(
            id: childURL.absoluteString,
            title: "MyBook",
            author: nil,
            duration: 0,
            fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z",
            isAvailable: true,
            sourceRootID: root.id)
        try AudiobookDAO(db: db.writer).save(book)

        let target = try service.urlForOpening(book)
        #expect(target.url.standardizedFileURL == childURL.standardizedFileURL)
        // The root scope is handed back to the caller (NOT entered here).
        #expect(target.scopedRoot != nil)
        #expect(target.scopedRoot?.standardizedFileURL == tmp.standardizedFileURL)

        // Fallback: book with no sourceRootID and a valid file:// id returns that
        // URL with a nil scopedRoot (no security scope to manage).
        let standaloneBook = AudiobookRecord(
            id: childURL.absoluteString,
            title: "StandaloneBook",
            author: nil,
            duration: 0,
            fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z",
            isAvailable: true,
            sourceRootID: nil)
        let fallback = try service.urlForOpening(standaloneBook)
        #expect(fallback.url.standardizedFileURL == childURL.standardizedFileURL)
        #expect(fallback.scopedRoot == nil)
    }
}
