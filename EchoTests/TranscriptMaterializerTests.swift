// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct TranscriptMaterializerTests {
    private let bookID = "file:///book/"

    private func makeDB() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'Test', 100, '2026-06-29T00:00:00Z')",
                arguments: [bookID])
        }
        return db
    }

    private func seedSegment(
        _ writer: DatabaseWriter, chapterIndex: Int, segmentIndex: Int,
        text: String, start: TimeInterval, end: TimeInterval,
        words: [StandaloneTranscribedWord]
    ) throws {
        let json = String(data: try JSONEncoder().encode(words), encoding: .utf8)
        try writer.write { db in
            var rec = StandaloneTranscriptRecord(
                id: "seg-\(chapterIndex)-\(segmentIndex)", audiobookID: bookID,
                chapterIndex: chapterIndex, segmentIndex: segmentIndex, text: text,
                startTime: start, endTime: end, wordsJSON: json,
                createdAt: "2026-06-29T00:00:00Z")
            try rec.insert(db)
        }
    }

    @Test func materializesBlocksTimelineAndWordTimings() throws {
        let db = try makeDB()
        try seedSegment(
            db.writer, chapterIndex: 0, segmentIndex: 0,
            text: "Hello world.", start: 1.0, end: 2.0,
            words: [
                .init(word: "Hello", start: 1.0, end: 1.4, confidence: 0.9),
                .init(word: "world.", start: 1.4, end: 2.0, confidence: 0.8),
            ])

        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)

        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)
        #expect(blocks.count == 1)
        #expect(blocks[0].id == "transcript-\(bookID)-c0-s0")
        #expect(blocks[0].blockKind == EPubBlockRecord.Kind.paragraph.rawValue)
        #expect(blocks[0].text == "Hello world.")

        let items = try TimelineDAO(db: db.writer).items(for: bookID)
        #expect(items.count == 1)
        #expect(items[0].audioStartTime == 1.0)
        #expect(items[0].audioEndTime == 2.0)
        #expect(items[0].epubBlockID == "transcript-\(bookID)-c0-s0")
        #expect(items[0].timestampSource == TimestampSource.transcript.rawValue)
        #expect(items[0].isTimestamped)

        let words = try WordTimingDAO(db: db.writer)
            .words(forAudiobook: bookID, blockID: "transcript-\(bookID)-c0-s0")
        #expect(words.count == 2)
        #expect(words[0].wordIndex == 0)
        #expect(words[0].word == "Hello")
        #expect(words[0].audioStartTime == 1.0)
        #expect(words[0].source == "transcript")
        #expect(words[1].wordIndex == 1)
        #expect(words[1].audioEndTime == 2.0)
        #expect(abs(words[1].confidence - 0.8) < 0.001)
    }

    @Test func wordIndicesMatchWordTokenizer() throws {
        let db = try makeDB()
        try seedSegment(
            db.writer, chapterIndex: 0, segmentIndex: 0,
            text: "one two three", start: 0.0, end: 3.0,
            words: [
                .init(word: "one", start: 0.0, end: 1.0, confidence: 0.9),
                .init(word: "two", start: 1.0, end: 2.0, confidence: 0.9),
                .init(word: "three", start: 2.0, end: 3.0, confidence: 0.9),
            ])
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        let block = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)[0]
        let tokenized = WordTokenizer.words(in: block.text ?? "").map(String.init)
        let words = try WordTimingDAO(db: db.writer)
            .words(forAudiobook: bookID, blockID: block.id)
        #expect(words.map(\.word) == tokenized)
        #expect(words.map(\.wordIndex) == Array(tokenized.indices))
    }

    @Test func isIdempotentNoDuplicateRows() throws {
        let db = try makeDB()
        try seedSegment(
            db.writer, chapterIndex: 0, segmentIndex: 0,
            text: "Hello world.", start: 1.0, end: 2.0,
            words: [
                .init(word: "Hello", start: 1.0, end: 1.4, confidence: 0.9),
                .init(word: "world.", start: 1.4, end: 2.0, confidence: 0.8),
            ])
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 1)
        #expect(try TimelineDAO(db: db.writer).items(for: bookID).count == 1)
        #expect(
            try WordTimingDAO(db: db.writer).words(forAudiobook: bookID).count == 2)
    }

    @Test func sequenceIndexMonotonicAcrossSegments() throws {
        let db = try makeDB()
        try seedSegment(
            db.writer, chapterIndex: 0, segmentIndex: 0, text: "a", start: 0, end: 1,
            words: [.init(word: "a", start: 0, end: 1, confidence: 0.9)])
        try seedSegment(
            db.writer, chapterIndex: 0, segmentIndex: 1, text: "b", start: 1, end: 2,
            words: [.init(word: "b", start: 1, end: 2, confidence: 0.9)])
        try seedSegment(
            db.writer, chapterIndex: 1, segmentIndex: 0, text: "c", start: 2, end: 3,
            words: [.init(word: "c", start: 2, end: 3, confidence: 0.9)])
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)
        #expect(blocks.map(\.sequenceIndex) == [0, 1, 2])
        #expect(blocks.map(\.text) == ["a", "b", "c"])
    }
}
