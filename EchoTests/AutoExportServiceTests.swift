// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct AutoExportServiceTests {
    private let bookID = "file:///books/tides/"

    private func makeTempDestination() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "auto-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func saveDestination(_ database: DatabaseService, at url: URL) throws {
        let bookmark = try #require(LibraryAccess.makeBookmark(for: url))
        try StudyAutoExportDAO(db: database.writer)
            .saveDestination(bookmark: bookmark, displayPath: url.path)
    }

    private func seedBookWithNote(_ database: DatabaseService) throws {
        try AudiobookDAO(db: database.writer).insert(
            AudiobookRecord(
                id: bookID,
                title: "The Field Guide to Tides",
                author: "M. Ostrander",
                duration: 3_600,
                fileCount: 1,
                addedAt: "2026-07-01T00:00:00Z"
            )
        )
        try NoteDAO(db: database.writer).insert(
            NoteRecord(
                id: "note-1",
                audiobookID: bookID,
                text: "Neap = nipped range",
                mediaTimestamp: 760,
                realTimestamp: nil,
                isEnabled: true,
                playlistPosition: nil,
                createdAt: "2026-07-01T20:58:31Z",
                modifiedAt: "2026-07-01T20:58:31Z"
            )
        )
    }

    private func mirrorURL(in destination: URL, title: String = "The Field Guide to Tides") -> URL {
        destination
            .appending(path: AutoExportService.subfolderName, directoryHint: .isDirectory)
            .appending(
                path: AutoExportMarkdown.fileName(bookID: bookID, title: title),
                directoryHint: .notDirectory
            )
    }

    @Test func passExportsDirtyBooksAndClearsDirty() async throws {
        let database = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(database, at: destination)
        try seedBookWithNote(database)

        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        let outcome = await AutoExportService.runPass(writer: database.writer)

        #expect(outcome.exported == 1)
        #expect(outcome.failed == 0)
        let content = try String(contentsOf: mirrorURL(in: destination), encoding: .utf8)
        #expect(content.contains("<!-- echo:note note-1 -->"))
        #expect(try StudyAutoExportDAO(db: database.writer).dirtyStates().isEmpty)
    }

    @Test func unchangedContentSkipsTheRewrite() async throws {
        let database = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(database, at: destination)
        try seedBookWithNote(database)

        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        _ = await AutoExportService.runPass(writer: database.writer)
        let firstStamp = try FileManager.default
            .attributesOfItem(atPath: mirrorURL(in: destination).path)[.modificationDate]

        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        let outcome = await AutoExportService.runPass(writer: database.writer)

        #expect(outcome.skipped == 1)
        #expect(outcome.exported == 0)
        let secondStamp = try FileManager.default
            .attributesOfItem(atPath: mirrorURL(in: destination).path)[.modificationDate]
        #expect(firstStamp as? Date == secondStamp as? Date)
    }

    @Test func unresolvableDestinationSetsNeedsRepickAndKeepsDirty() async throws {
        let database = try DatabaseService(inMemory: ())
        try StudyAutoExportDAO(db: database.writer)
            .saveDestination(bookmark: Data([0x00, 0x01]), displayPath: "/gone")
        try seedBookWithNote(database)

        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        let outcome = await AutoExportService.runPass(writer: database.writer)

        #expect(outcome.needsRepick == true)
        #expect(outcome.exported == 0)
        #expect(try #require(try StudyAutoExportDAO(db: database.writer).destination()).needsRepick)
        #expect(try StudyAutoExportDAO(db: database.writer).dirtyStates().count == 1)
    }

    @Test func titleRenameReplacesTheOldMirrorFile() async throws {
        let database = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(database, at: destination)
        try seedBookWithNote(database)

        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        _ = await AutoExportService.runPass(writer: database.writer)
        let oldURL = mirrorURL(in: destination)
        #expect(FileManager.default.fileExists(atPath: oldURL.path))

        var record = try #require(try AudiobookDAO(db: database.writer).get(bookID))
        record.title = "Tides, Revised"
        try AudiobookDAO(db: database.writer).save(record)

        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        _ = await AutoExportService.runPass(writer: database.writer)

        let newURL = mirrorURL(in: destination, title: "Tides, Revised")
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    }

    @Test func booksWithNoRemainingCapturesLoseTheirMirror() async throws {
        let database = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(database, at: destination)
        try seedBookWithNote(database)

        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        _ = await AutoExportService.runPass(writer: database.writer)
        #expect(FileManager.default.fileExists(atPath: mirrorURL(in: destination).path))

        try NoteDAO(db: database.writer).deleteAll(for: bookID)
        try AutoExportService.markCapturedBooksDirty(writer: database.writer)
        _ = await AutoExportService.runPass(writer: database.writer)

        #expect(!FileManager.default.fileExists(atPath: mirrorURL(in: destination).path))
        #expect(try StudyAutoExportDAO(db: database.writer).state(for: bookID) == nil)
    }
}
