// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct WordTimingSynthesisRefineTests {
    private func seedInterpolated(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk', 'Book', 10.0)")
        }
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b0", wordIndex: 0, word: "one",
                audioStartTime: 0.0, audioEndTime: 0.5, confidence: 0.5, source: "interpolated"),
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b0", wordIndex: 1, word: "two",
                audioStartTime: 0.5, audioEndTime: 1.0, confidence: 0.5, source: "interpolated"),
        ])
    }

    @Test func overridesWhenCountMatches() throws {
        let db = try DatabaseService(inMemory: ())
        try seedInterpolated(db)
        let overridden = try WordTimingMaterializer.refineWithSynthesis(
            audiobookID: "bk",
            synthesisByBlock: [
                "b0": [
                    ChunkWordTiming(wordIndex: 0, start: 0.1, end: 0.4),
                    ChunkWordTiming(wordIndex: 1, start: 0.4, end: 0.9),
                ]
            ],
            writer: db.writer)
        #expect(overridden == 1)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
        #expect(rows.allSatisfy { $0.source == "synthesis" && $0.confidence == 0.9 })
        #expect(abs(rows[0].audioStartTime - 0.1) < 1e-6)
        #expect(abs(rows[1].audioEndTime - 0.9) < 1e-6)
    }

    @Test func keepsInterpolatedWhenCountMismatch() throws {
        let db = try DatabaseService(inMemory: ())
        try seedInterpolated(db)
        let overridden = try WordTimingMaterializer.refineWithSynthesis(
            audiobookID: "bk",
            synthesisByBlock: [
                "b0": [ChunkWordTiming(wordIndex: 0, start: 0.1, end: 0.4)]  // 1 vs 2 rows
            ],
            writer: db.writer)
        #expect(overridden == 0)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
        #expect(rows.allSatisfy { $0.source == "interpolated" })
    }
}
