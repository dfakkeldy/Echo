// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryListeningHistoryTests {
    @Test func onePlayedBookDoesNotShowItsUnplayedImportArtifacts() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("audio", title: "A Book", in: db)
        try saveBook("text", title: "A Book EPUB", in: db)
        try saveBook("review", title: "Pronunciation Review", in: db)
        try logPlayback("audio", in: db)

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(vm.sections.flatMap(\.books).map(\.id) == ["audio"])
        #expect(try AudiobookDAO(db: db.writer).all().count == 3)
    }

    @Test func openingAndSeekingWithoutPlayingDoesNotAddABook() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("file:///Books/Opened/", in: db)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_state (audiobook_id, last_position, speed)
                    VALUES ('file:///Books/Opened/', 90, 1)
                    """)
        }
        let book = try #require(try AudiobookDAO(db: db.writer).get("file:///Books/Opened/"))
        var opened = false
        let vm = LibraryViewModel(db: db, openBook: { _ in opened = true })

        vm.open(book)
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(opened)
        #expect(vm.isEmpty)
    }

    @Test func playbackAtTheBeginningCountsBeforeTheFirstHeartbeat() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("playing", in: db)
        _ = try PlaybackEventDAO(db: db.writer).insertOpen(
            audiobookID: "playing", trackID: nil,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            startPosition: 0, speed: 1, source: "user")

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(vm.sections.flatMap(\.books).map(\.id) == ["playing"])
    }

    @Test func returningToTheBeginningDoesNotEraseListeningHistory() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("restarted", in: db)
        try saveBook("unplayed", in: db)
        try logPlayback("restarted", in: db)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_state (audiobook_id, last_position, speed)
                    VALUES ('restarted', 0, 1)
                    """)
        }

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(vm.sections.flatMap(\.books).map(\.id) == ["restarted"])
    }

    @Test func olderPlaybackSessionsCountButOtherEventsDoNot() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("legacy", in: db)
        try saveBook("bookmark", in: db)
        try saveBook("seek", in: db)
        let events = RealTimeEventDAO(db: db.writer)
        for (id, type) in [("legacy", "playback_session"), ("bookmark", "bookmark_created")] {
            try events.log(
                eventType: type, audiobookID: id, mediaTimestamp: 0,
                startedAt: Date(timeIntervalSince1970: 1_780_000_000),
                endedAt: nil, title: nil, subtitle: nil,
                metadataJSON: nil, sourceItemID: nil, sourceItemType: nil)
        }
        try logPlayback("seek", eventType: "seek", in: db)

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(vm.sections.flatMap(\.books).map(\.id) == ["legacy"])
    }

    @Test func playedSiblingKeepsOneCardWithTheGroupsBestMetadata() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "rooted", title: "A Book", author: "An Author", duration: 100,
                fileCount: 1, addedAt: "2026-10-19T00:00:00Z", coverArtPath: "cover.jpg",
                sourceRootID: "root", editionGroupID: "one-book"))
        try saveBook("direct", title: "A Book", group: "one-book", in: db)
        try saveBook("companion", title: "A Book", group: "one-book", in: db)
        try saveBook("other", in: db)
        try logPlayback("direct", in: db)
        try logPlayback("companion", in: db)

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        let books = vm.sections.flatMap(\.books)
        #expect(books.map(\.id) == ["rooted"])
        let displayed = try #require(books.first)
        #expect(displayed.coverArtPath == "cover.jpg")
        #expect(Set(vm.siblingEditions(of: displayed).map(\.id)) == ["direct", "companion"])
    }

    @Test func unplayedSeparatedEditionDoesNotInheritGroupListening() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("played", group: "shared", in: db)
        var separated = AudiobookRecord(
            id: "separated", title: "Separate Edition", author: nil, duration: 100,
            fileCount: 1, addedAt: "2026-10-19T00:00:00Z", editionGroupID: "shared")
        separated.editionGroupOptOut = true
        try AudiobookDAO(db: db.writer).save(separated)
        try logPlayback("played", in: db)

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(vm.sections.flatMap(\.books).map(\.id) == ["played"])
    }

    @Test func missingPlayedSiblingStillQualifiesAnAvailableEdition() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("available", group: "same-book", in: db)
        try saveBook("missing", group: "same-book", available: false, in: db)
        try logPlayback("missing", in: db)

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(vm.sections.flatMap(\.books).map(\.id) == ["available"])
    }

    @Test func shelfRegroupCombinesPlayedFolderAndFileIdentities() async throws {
        let db = try DatabaseService(inMemory: ())
        try AudiobookDAO(db: db.writer).save(
            AudiobookRecord(
                id: "file:///Lib/HistoryBook/", title: "A Book", author: "An Author",
                duration: 100, fileCount: 1, addedAt: "2026-10-19T00:00:00Z",
                sourceRootID: "root"))
        try saveBook("file:///Lib/HistoryBook/book.m4b", title: "chapter-audio", in: db)
        try saveBook("file:///Lib/HistoryText/", title: "A Book", in: db)
        try logPlayback("file:///Lib/HistoryBook/", in: db)
        try logPlayback("file:///Lib/HistoryBook/book.m4b", in: db)

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()

        let books = vm.sections.flatMap(\.books)
        #expect(books.map(\.id) == ["file:///Lib/HistoryBook/"])
        let displayed = try #require(books.first)
        #expect(
            Set(vm.siblingEditions(of: displayed).map(\.id))
                == ["file:///Lib/HistoryBook/book.m4b", "file:///Lib/HistoryText/"])
    }

    @Test func groupingAndMissingBookRecoveryDoNotBringBackUnplayedBooks() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("available", in: db)
        try saveBook("missing", available: false, in: db)
        try saveBook("unplayed", available: false, in: db)
        try logPlayback("available", in: db)
        try logPlayback("missing", in: db)

        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.selectAxis(.author)
        await vm.awaitShelfRegroup()
        #expect(vm.sections.flatMap(\.books).map(\.id) == ["available"])

        vm.setShowUnavailable(true)
        await vm.awaitShelfRegroup()
        #expect(Set(vm.sections.flatMap(\.books).map(\.id)) == ["available", "missing"])
    }

    @Test func aNewPlaybackSessionAppearsOnTheNextReload() async throws {
        let db = try DatabaseService(inMemory: ())
        try saveBook("new", in: db)
        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        await vm.awaitShelfRegroup()
        #expect(vm.isEmpty)

        try logPlayback("new", in: db)
        vm.reload()
        await vm.awaitShelfRegroup()

        #expect(vm.sections.flatMap(\.books).map(\.id) == ["new"])
    }

    private func saveBook(
        _ id: String, title: String? = nil, group: String? = nil,
        available: Bool = true, in db: DatabaseService
    ) throws {
        try AudiobookDAO(db: db.writer).save(
            AudiobookRecord(
                id: id, title: title ?? id, author: "An Author", duration: 100,
                fileCount: 1, addedAt: "2026-10-19T00:00:00Z",
                isAvailable: available, editionGroupID: group))
    }

    private func logPlayback(
        _ id: String, eventType: String = "play", in db: DatabaseService
    ) throws {
        try PlaybackEventDAO(db: db.writer).log(
            audiobookID: id, trackID: nil,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_030),
            startPosition: 0, endPosition: 30, speed: 1,
            eventType: eventType, source: "user")
    }
}
