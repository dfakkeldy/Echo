// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryAvailabilityTests {
    private func fixedNow() -> String { "2026-06-27T00:00:00Z" }

    @Test func removeRootForgetBooksDeletesRows() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "avail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        try AudiobookDAO(db: db.writer).save(AudiobookRecord(
            id: "bk", title: "T", author: nil, duration: 0, fileCount: nil,
            addedAt: fixedNow(), isAvailable: true, sourceRootID: root.id))

        try service.removeRoot(rootID: root.id, forgetBooks: true)

        #expect(try AudiobookDAO(db: db.writer).get("bk") == nil)
        #expect(try LibraryRootDAO(db: db.writer).get(root.id) == nil)
    }

    @Test func removeRootKeepBooksClearsSourceRootAndMarksUnavailable() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "avail2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        try AudiobookDAO(db: db.writer).save(AudiobookRecord(
            id: "bk", title: "T", author: nil, duration: 0, fileCount: nil,
            addedAt: fixedNow(), isAvailable: true, sourceRootID: root.id))

        try service.removeRoot(rootID: root.id, forgetBooks: false)

        let book = try AudiobookDAO(db: db.writer).get("bk")
        #expect(book?.sourceRootID == nil)
        #expect(book?.isAvailable == false)
        #expect(try LibraryRootDAO(db: db.writer).get(root.id) == nil)
    }

    @Test func markUnavailableUnderMissingRootHidesBooks() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        try LibraryRootDAO(db: db.writer).save(LibraryRootRecord(
            id: "root", displayName: "Root", bookmark: Data(),
            addedAt: fixedNow(), lastScannedAt: nil))
        try AudiobookDAO(db: db.writer).save(AudiobookRecord(
            id: "bk", title: "T", author: nil, duration: 0, fileCount: nil,
            addedAt: fixedNow(), isAvailable: true, sourceRootID: "root"))

        try service.markUnavailableUnderMissingRoot(rootID: "root")

        #expect(try AudiobookDAO(db: db.writer).get("bk")?.isAvailable == false)
    }
}
