// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Title ownership in `TimelineIngestionService.persistAudiobook`: local audio
/// books take the folder name on every open, but audio-less text books must
/// keep their persisted (OPF-enriched) title after the first insert — resetting
/// it on every reopen would undo Library edition grouping.
@MainActor
@Suite struct TimelineIngestionTitleOwnershipTests {

    @Test func firstInsertOfAudiolessBookUsesFolderNamePlaceholder() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/title-first-\(UUID().uuidString)")

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)

        let book = try #require(try AudiobookDAO(db: db.writer).get(folder.absoluteString))
        #expect(book.title == folder.deletingPathExtension().lastPathComponent)
        #expect(book.author == nil)
    }

    @Test func audiolessReopenPreservesEnrichedTitle() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/title-keep-\(UUID().uuidString)")
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)

        // Library OPF enrichment replaced the placeholder...
        let dao = AudiobookDAO(db: db.writer)
        var book = try #require(try dao.get(folder.absoluteString))
        book.title = "Fixture Book"
        book.author = "Tester"
        try dao.save(book)

        // ...and the next open must not reset it to the folder name.
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)

        let reopened = try #require(try dao.get(folder.absoluteString))
        #expect(reopened.title == "Fixture Book")
        #expect(reopened.author == "Tester")
    }

    @Test func audioBookReopenStillResetsTitleToFolderName() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = URL(fileURLWithPath: "/tmp/title-audio-\(UUID().uuidString)")
        let track = Track(url: folder.appendingPathComponent("01.m4b"), title: "One")
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [track], duration: 60)

        let dao = AudiobookDAO(db: db.writer)
        var book = try #require(try dao.get(folder.absoluteString))
        book.title = "Renamed Elsewhere"
        try dao.save(book)

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [track], duration: 60)

        let reopened = try #require(try dao.get(folder.absoluteString))
        #expect(reopened.title == folder.deletingPathExtension().lastPathComponent)
    }
}
