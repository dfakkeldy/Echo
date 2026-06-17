// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct WordTimingDAOTests {
    /// word_timing.audiobook_id carries an ON DELETE CASCADE FK to audiobook, so
    /// every test must seed the parent rows before inserting timings or the insert
    /// fails the foreign-key check (PRAGMA foreign_keys is ON).
    private func seedBooks(_ db: DatabaseService, ids: String...) throws {
        try db.write { db in
            for id in ids {
                try db.execute(
                    sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                    arguments: [id, "Book \(id)", 100.0])
            }
        }
    }

    @Test func insertAndFetchByBlockOrdersByWordIndex() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBooks(db, ids: "bk")
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b1", wordIndex: 1,
                word: "world", audioStartTime: 1.0, audioEndTime: 1.5,
                confidence: 0.5, source: "interpolated"),
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b1", wordIndex: 0,
                word: "hello", audioStartTime: 0.0, audioEndTime: 1.0,
                confidence: 0.5, source: "interpolated"),
        ])
        let words = try dao.words(forAudiobook: "bk", blockID: "b1")
        #expect(words.map(\.word) == ["hello", "world"])
        #expect(words.map(\.wordIndex) == [0, 1])
    }

    @Test func deleteAllRemovesOnlyThatBook() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBooks(db, ids: "bk", "other")
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b1", wordIndex: 0,
                word: "x", audioStartTime: 0, audioEndTime: 1,
                confidence: 0.5, source: "interpolated"),
            WordTimingRecord(
                audiobookID: "other", epubBlockID: "b1", wordIndex: 0,
                word: "y", audioStartTime: 0, audioEndTime: 1,
                confidence: 0.5, source: "interpolated"),
        ])
        try dao.deleteAll(forAudiobook: "bk")
        #expect(try dao.words(forAudiobook: "bk").isEmpty)
        #expect(try dao.words(forAudiobook: "other").count == 1)
    }

    /// Regression for the V19 cascade FK: AudiobookDAO.delete relies SOLELY on the
    /// database cascade to purge per-book rows, so deleting the audiobook must take
    /// its word_timing rows with it (and leave other books untouched).
    @Test func deletingAudiobookCascadesWordTimings() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBooks(db, ids: "bk", "other")
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b1", wordIndex: 0,
                word: "gone", audioStartTime: 0, audioEndTime: 1,
                confidence: 0.5, source: "interpolated"),
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b1", wordIndex: 1,
                word: "soon", audioStartTime: 1, audioEndTime: 2,
                confidence: 0.5, source: "interpolated"),
            WordTimingRecord(
                audiobookID: "other", epubBlockID: "b1", wordIndex: 0,
                word: "stay", audioStartTime: 0, audioEndTime: 1,
                confidence: 0.5, source: "interpolated"),
        ])

        // Delete the audiobook the way AudiobookDAO.delete does (cascade-only).
        try AudiobookDAO(db: db.writer).delete("bk")

        #expect(try dao.words(forAudiobook: "bk").isEmpty)
        #expect(try dao.words(forAudiobook: "other").count == 1)
    }
}
