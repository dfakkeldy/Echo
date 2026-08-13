// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct FeedScopeResolverTests {

    private let iso = ISO8601DateFormatter()

    /// Inserts the audiobook row + one playback_event 'play' segment.
    private func insertPlay(
        _ db: Database,
        audiobookID: String,
        startedAt: Date,
        endedAt: Date,
        startPosition: Double,
        endPosition: Double,
        speed: Double = 1.0
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO playback_event
                  (audiobook_id, track_id, started_at, ended_at,
                   start_position, end_position, speed, event_type, source)
                VALUES (?, NULL, ?, ?, ?, ?, ?, 'play', 'test')
                """,
            arguments: [
                audiobookID, iso.string(from: startedAt),
                iso.string(from: endedAt), startPosition, endPosition, speed,
            ])
    }

    private func insertSessionMarker(
        _ db: Database,
        id: String,
        folderURL: String,
        startedAt: Date,
        endedAt: Date?
    ) throws {
        // real_time_event.audiobook_id has a FK to audiobook (onDelete: .setNull).
        // At runtime the app stores the folder URL here (a different namespace from
        // the GRDB UUID), so we store NULL in the FK column and keep the folder URL
        // in the title field for documentation only. The resolver never joins on this
        // column — it finds sessions by recency / id.
        try db.execute(
            sql: """
                INSERT INTO real_time_event
                  (id, event_type, audiobook_id, media_timestamp, started_at, ended_at,
                   title, subtitle, metadata_json, source_item_id, source_item_type)
                VALUES (?, 'playback_session', NULL, NULL, ?, ?, ?,
                        'My Book', NULL, NULL, NULL)
                """,
            arguments: [
                id, iso.string(from: startedAt),
                endedAt.map { iso.string(from: $0) },
                folderURL,
            ])
    }

    private func makeBook(_ db: Database, id: String) throws {
        try db.execute(
            sql: """
                INSERT INTO audiobook (id, title, author, duration, added_at)
                VALUES (?, 'My Book', 'Author', 3600, ?)
                """, arguments: [id, iso.string(from: Date())])
    }

    @Test func lastSessionDerivesWindowAndCoveredRange() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "BOOK-UUID"
        let folder = "file:///Books/My%20Book/"
        let base = iso.date(from: "2026-06-22T10:00:00Z")!

        try db.writer.write { db in
            try makeBook(db, id: bookID)
            // Coarse session marker: 10:00 -> 10:30.
            try insertSessionMarker(
                db, id: "S1", folderURL: folder,
                startedAt: base, endedAt: base.addingTimeInterval(1800))
            // Two play segments inside the window.
            try insertPlay(
                db, audiobookID: bookID,
                startedAt: base.addingTimeInterval(60),
                endedAt: base.addingTimeInterval(660),
                startPosition: 120, endPosition: 720, speed: 1.0)
            try insertPlay(
                db, audiobookID: bookID,
                startedAt: base.addingTimeInterval(900),
                endedAt: base.addingTimeInterval(1500),
                startPosition: 700, endPosition: 1300, speed: 2.0)
            // A segment from a DIFFERENT, earlier session — must be excluded.
            try insertPlay(
                db, audiobookID: bookID,
                startedAt: base.addingTimeInterval(-7200),
                endedAt: base.addingTimeInterval(-6600),
                startPosition: 0, endPosition: 50, speed: 1.0)
        }

        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.lastSessionWindow(audiobookID: bookID))

        #expect(window.startedAt == base)
        #expect(window.endedAt == base.addingTimeInterval(1800))
        // covered range = min(start)…max(end) over the two in-window segments.
        #expect(window.coveredStartPosition == 120)
        #expect(window.coveredEndPosition == 1300)
        // listened seconds = sum((end-start)/speed) = 600/1 + 600/2 = 900.
        #expect(window.listenedSeconds == 900)
    }

    @Test func lastSessionReturnsNilWhenNoSessionMarker() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in try makeBook(db, id: "B") }
        let resolver = FeedScopeResolver(db: db.writer)
        #expect(try resolver.lastSessionWindow(audiobookID: "B") == nil)
    }

    @Test func openSessionUsesNowAsUpperBound() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = Date().addingTimeInterval(-600)
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            // ended_at NULL = still open.
            try insertSessionMarker(
                db, id: "S", folderURL: "file:///x/",
                startedAt: base, endedAt: nil)
            try insertPlay(
                db, audiobookID: bookID,
                startedAt: base.addingTimeInterval(10),
                endedAt: base.addingTimeInterval(310),
                startPosition: 30, endPosition: 330)
        }
        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.lastSessionWindow(audiobookID: bookID))
        #expect(window.coveredStartPosition == 30)
        #expect(window.coveredEndPosition == 330)
        // endedAt defaulted to ~now (>= the play segment's end).
        #expect(window.endedAt >= base.addingTimeInterval(310))
    }

    @Test func lastSessionWithMarkerButNoPlaysHasZeroRange() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = iso.date(from: "2026-06-22T08:00:00Z")!
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            try insertSessionMarker(
                db, id: "S", folderURL: "file:///x/",
                startedAt: base, endedAt: base.addingTimeInterval(60))
        }
        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.lastSessionWindow(audiobookID: bookID))
        #expect(window.coveredStartPosition == 0)
        #expect(window.coveredEndPosition == 0)
        #expect(window.listenedSeconds == 0)
    }

    @Test func sessionWindowByIDResolvesNamedSession() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = iso.date(from: "2026-06-22T09:00:00Z")!
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            try insertSessionMarker(
                db, id: "TARGET", folderURL: "file:///x/",
                startedAt: base, endedAt: base.addingTimeInterval(600))
            try insertPlay(
                db, audiobookID: bookID,
                startedAt: base.addingTimeInterval(30),
                endedAt: base.addingTimeInterval(330),
                startPosition: 200, endPosition: 500)
        }
        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.sessionWindow(id: "TARGET", audiobookID: bookID))
        #expect(window.startedAt == base)
        #expect(window.coveredStartPosition == 200)
        #expect(window.coveredEndPosition == 500)
    }
}
