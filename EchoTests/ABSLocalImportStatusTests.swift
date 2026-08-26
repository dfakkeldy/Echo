// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct ABSLocalImportStatusTests {
    @Test func returnsOnlyUsableRecordsForActiveServer() throws {
        let db = try DatabaseService(inMemory: ())
        let fixture = try ABSLocalImportFixture(db: db)
        defer { fixture.cleanUp() }

        try fixture.insertRecords()

        let records = try AudiobookDAO(db: db.writer)
            .audiobookshelfRecords(serverID: "server-a")
        let books = ABSLocalImportStatus.usableBooks(records: records)

        #expect(Set(books.map(\.remoteItemID)) == ["usable"])
    }
}

@MainActor
private final class ABSLocalImportFixture {
    private let db: DatabaseService
    private let rootURL: URL
    private let usableURL: URL
    private let missingURL: URL
    private let coverOnlyURL: URL
    private let nestedOnlyURL: URL
    private let otherServerURL: URL
    private let localURL: URL

    init(db: DatabaseService) throws {
        self.db = db
        rootURL = FileManager.default.temporaryDirectory
            .appending(
                path: "ABSLocalImportStatusTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        usableURL = rootURL.appending(path: "usable", directoryHint: .isDirectory)
        missingURL = rootURL.appending(path: "missing", directoryHint: .isDirectory)
        coverOnlyURL = rootURL.appending(path: "cover-only", directoryHint: .isDirectory)
        nestedOnlyURL = rootURL.appending(path: "nested-only", directoryHint: .isDirectory)
        otherServerURL = rootURL.appending(path: "other-server", directoryHint: .isDirectory)
        localURL = rootURL.appending(path: "local", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: usableURL, withIntermediateDirectories: true)
        try Data().write(to: usableURL.appending(path: "book.m4b"))

        try FileManager.default.createDirectory(at: coverOnlyURL, withIntermediateDirectories: true)
        try Data().write(to: coverOnlyURL.appending(path: "cover.jpg"))

        let nestedURL = nestedOnlyURL.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data().write(to: nestedURL.appending(path: "book.m4b"))

        try FileManager.default.createDirectory(
            at: otherServerURL, withIntermediateDirectories: true)
        try Data().write(to: otherServerURL.appending(path: "book.m4b"))

        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        try Data().write(to: localURL.appending(path: "book.m4b"))
    }

    func insertRecords() throws {
        let dao = AudiobookDAO(db: db.writer)
        try dao.insert(
            record(
                id: usableURL, title: "Usable", sourceType: "audiobookshelf", serverID: "server-a",
                remoteItemID: "usable"))
        try dao.insert(
            record(
                id: missingURL, title: "Missing", sourceType: "audiobookshelf",
                serverID: "server-a", remoteItemID: "missing"))
        try dao.insert(
            record(
                id: coverOnlyURL, title: "Cover only", sourceType: "audiobookshelf",
                serverID: "server-a", remoteItemID: "cover-only"))
        try dao.insert(
            record(
                id: nestedOnlyURL, title: "Nested only", sourceType: "audiobookshelf",
                serverID: "server-a", remoteItemID: "nested-only"))
        try dao.insert(
            record(
                id: otherServerURL, title: "Other server", sourceType: "audiobookshelf",
                serverID: "server-b", remoteItemID: "other-server"))
        try dao.insert(
            record(id: localURL, title: "Local", sourceType: nil, serverID: nil, remoteItemID: nil))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func record(
        id folderURL: URL,
        title: String,
        sourceType: String?,
        serverID: String?,
        remoteItemID: String?
    ) -> AudiobookRecord {
        AudiobookRecord(
            id: folderURL.absoluteString,
            title: title,
            author: nil,
            duration: 0,
            fileCount: nil,
            addedAt: "2026-08-12T00:00:00Z",
            sourceType: sourceType,
            serverID: serverID,
            remoteItemID: remoteItemID
        )
    }
}
