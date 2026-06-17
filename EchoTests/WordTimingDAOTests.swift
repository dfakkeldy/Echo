// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct WordTimingDAOTests {
    @Test func insertAndFetchByBlockOrdersByWordIndex() throws {
        let db = try DatabaseService(inMemory: ())
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
}
