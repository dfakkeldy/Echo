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
}
