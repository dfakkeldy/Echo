// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct SessionRecapViewModelTests {

    private let iso = ISO8601DateFormatter()

    private func makeBook(_ db: Database, id: String) throws {
        try db.execute(
            sql: """
                INSERT INTO audiobook (id, title, author, duration, added_at)
                VALUES (?, 'B', 'A', 3600, ?)
                """, arguments: [id, iso.string(from: Date())])
    }

    /// epub_block + a timeline_item pointing at it with the given audio_start_time.
    private func insertBlockWithTimeline(
        _ db: Database,
        audiobookID: String,
        blockID: String,
        chapterIndex: Int,
        audioStart: Double
    ) throws {
        // D4: epub_block requires NOT NULL spine_href, spine_index, block_index (+ is_hidden).
        try db.execute(
            sql: """
                INSERT INTO epub_block
                  (id, audiobook_id, spine_href, spine_index, block_index,
                   sequence_index, block_kind, text, chapter_index, is_hidden)
                VALUES (?, ?, 'spine.xhtml', 0, 0, 0, 'paragraph', 'x', ?, 0)
                """, arguments: [blockID, audiobookID, chapterIndex])
        // D5: timeline_item requires NOT NULL title.
        try db.execute(
            sql: """
                INSERT INTO timeline_item
                  (id, audiobook_id, item_type, epub_block_id, audio_start_time,
                   title, is_enabled, created_at)
                VALUES (?, ?, 'textSegment', ?, ?, 'Block', 1, ?)
                """,
            arguments: [
                "ti-\(blockID)", audiobookID, blockID, audioStart,
                iso.string(from: Date()),
            ])
    }

    private func insertBookmark(
        _ db: Database,
        audiobookID: String,
        mediaTimestamp: Double,
        createdAt: Date
    ) throws {
        // D3: bookmark has media_timestamp (NOT NULL), title (NOT NULL); no 'position' column.
        try db.execute(
            sql: """
                INSERT INTO bookmark (id, audiobook_id, title, media_timestamp, created_at)
                VALUES (?, ?, 'Mark', ?, ?)
                """,
            arguments: [
                UUID().uuidString, audiobookID, mediaTimestamp,
                iso.string(from: createdAt),
            ])
    }

    @Test func recapDerivesChapterRangeFromCoveredPositions() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            // Chapter 0 starts at audio 0, chapter 1 at 600, chapter 2 at 1200.
            try insertBlockWithTimeline(
                db, audiobookID: bookID, blockID: "c0", chapterIndex: 0, audioStart: 0)
            try insertBlockWithTimeline(
                db, audiobookID: bookID, blockID: "c1", chapterIndex: 1, audioStart: 600)
            try insertBlockWithTimeline(
                db, audiobookID: bookID, blockID: "c2", chapterIndex: 2, audioStart: 1200)
        }
        // Covered range 120…720 spans chapter 0 (0) and chapter 1 (600), not chapter 2.
        let window = FeedScopeWindow(
            startedAt: iso.date(from: "2026-06-22T10:00:00Z")!,
            endedAt: iso.date(from: "2026-06-22T10:30:00Z")!,
            coveredStartPosition: 120, coveredEndPosition: 720, listenedSeconds: 900)

        let vm = SessionRecapViewModel(db: db.writer)
        let recap = try vm.recap(audiobookID: bookID, window: window)

        #expect(recap.coveredChapterIndices == [0, 1])
        #expect(recap.listenedSeconds == 900)
        #expect(recap.startedAt == window.startedAt)
    }

    @Test func recapCountsBookmarksCreatedInWindowOnly() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = iso.date(from: "2026-06-22T10:00:00Z")!
        let window = FeedScopeWindow(
            startedAt: base, endedAt: base.addingTimeInterval(1800),
            coveredStartPosition: 0, coveredEndPosition: 10, listenedSeconds: 60)
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            try insertBookmark(
                db, audiobookID: bookID, mediaTimestamp: 5,
                createdAt: base.addingTimeInterval(60))  // inside
            try insertBookmark(
                db, audiobookID: bookID, mediaTimestamp: 7,
                createdAt: base.addingTimeInterval(120))  // inside
            try insertBookmark(
                db, audiobookID: bookID, mediaTimestamp: 1,
                createdAt: base.addingTimeInterval(-3600))  // before → excluded
        }
        let vm = SessionRecapViewModel(db: db.writer)
        let recap = try vm.recap(audiobookID: bookID, window: window)
        #expect(recap.bookmarkCount == 2)
    }

    @Test func recapWithNoCoverageHasEmptyChapterRange() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        try db.writer.write { db in try makeBook(db, id: bookID) }
        let window = FeedScopeWindow(
            startedAt: Date(), endedAt: Date(),
            coveredStartPosition: 0, coveredEndPosition: 0, listenedSeconds: 0)
        let vm = SessionRecapViewModel(db: db.writer)
        let recap = try vm.recap(audiobookID: bookID, window: window)
        #expect(recap.coveredChapterIndices.isEmpty)
        #expect(recap.bookmarkCount == 0)
    }
}
