// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct TranscriptReaderParityTests {
    private let bookID = "file:///book/"

    private func makeDBWithTwoSegments() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'T', 60, '2026-06-29T00:00:00Z')",
                arguments: [bookID])
        }
        func insert(
            _ ci: Int, _ si: Int, _ text: String, _ start: Double, _ end: Double,
            _ words: [StandaloneTranscribedWord]
        ) throws {
            let json = String(data: try JSONEncoder().encode(words), encoding: .utf8)
            try db.writer.write { database in
                var rec = StandaloneTranscriptRecord(
                    id: "seg-\(ci)-\(si)", audiobookID: bookID, chapterIndex: ci,
                    segmentIndex: si, text: text, startTime: start, endTime: end,
                    wordsJSON: json, createdAt: "2026-06-29T00:00:00Z")
                try rec.insert(database)
            }
        }
        try insert(
            0, 0, "The quick fox.", 0.0, 2.0,
            [
                .init(word: "The", start: 0.0, end: 0.5, confidence: 0.9),
                .init(word: "quick", start: 0.5, end: 1.2, confidence: 0.9),
                .init(word: "fox.", start: 1.2, end: 2.0, confidence: 0.9),
            ])
        try insert(
            0, 1, "Lazy dog runs.", 2.0, 4.0,
            [
                .init(word: "Lazy", start: 2.0, end: 2.6, confidence: 0.9),
                .init(word: "dog", start: 2.6, end: 3.2, confidence: 0.9),
                .init(word: "runs.", start: 3.2, end: 4.0, confidence: 0.9),
            ])
        return db
    }

    @Test func materializedBookSupportsReaderContracts() throws {
        let db = try makeDBWithTwoSegments()
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        try AudiobookDAO(db: db.writer).save(
            try {
                var b = try AudiobookDAO(db: db.writer).get(bookID)!
                b.textOrigin = "transcript"
                return b
            }())

        // hasEPUB-style: visible blocks exist → reader routes here.
        let visible = try EPubBlockDAO(db: db.writer).visibleBlocks(for: bookID)
        #expect(visible.count == 2)

        // search-to-seek: a search term resolves to a block.
        let hits = try EPubBlockDAO(db: db.writer).searchBlocks(for: bookID, query: "dog")
        #expect(hits.count == 1)
        #expect(hits[0].id == "transcript-\(bookID)-c0-s1")

        // tap-to-seek: that block's timeline row is timestamped.
        let items = try TimelineDAO(db: db.writer).items(for: bookID)
        let dogItem = items.first { $0.epubBlockID == hits[0].id }
        #expect(dogItem?.isTimestamped == true)
        #expect(dogItem?.audioStartTime == 2.0)

        // word highlight: per-word timings exist and index 1:1 with the tokens.
        let words = try WordTimingDAO(db: db.writer)
            .words(forAudiobook: bookID, blockID: hits[0].id)
        #expect(words.map(\.word) == ["Lazy", "dog", "runs."])
        #expect(words[1].audioStartTime == 2.6)

        // provenance is queryable.
        #expect(try AudiobookDAO(db: db.writer).get(bookID)?.textOrigin == "transcript")
    }

    @Test func reMaterializeKeepsSingleCopyAndPreservesData() throws {
        let db = try makeDBWithTwoSegments()
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 2)
        #expect(try TimelineDAO(db: db.writer).items(for: bookID).count == 2)
        #expect(try WordTimingDAO(db: db.writer).words(forAudiobook: bookID).count == 6)
    }

    @Test func materializeDoesNotTouchAnUnrelatedEpubBook() throws {
        let db = try makeDBWithTwoSegments()
        let otherID = "file:///other/"
        try db.writer.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'Other', 60, '2026-06-29T00:00:00Z')",
                arguments: [otherID])
        }
        // A real (non-transcript) EPUB block id for the other book.
        try EPubBlockDAO(db: db.writer).insert(
            EPubBlockRecord(
                id: "epub-\(otherID)-s0-b0", audiobookID: otherID, spineHref: "c1.xhtml",
                spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                blockKind: EPubBlockRecord.Kind.paragraph.rawValue, text: "Canonical.",
                isHidden: false))
        try TranscriptMaterializer.materialize(audiobookID: bookID, writer: db.writer)
        #expect(try EPubBlockDAO(db: db.writer).count(for: otherID) == 1)
    }
}
