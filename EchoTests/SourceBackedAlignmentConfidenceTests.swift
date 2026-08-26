// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct SourceBackedAlignmentConfidenceTests {
    /// Seeds 7 single-word blocks with only 6 matching audio tokens (b6 "golf"
    /// has no match). The 6 matched blocks get DTW-refined word timing (high
    /// confidence 0.85); b6 is unmatched so it produces no anchor and no word
    /// timing row.
    @Test func reportsLowConfidenceWordsForUnmatchedSourceTail() async throws {
        let db = try DatabaseService(inMemory: ())
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"]
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',100)")
            for (i, name) in names.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index,
                           sequence_index, block_kind, text, is_hidden)
                        VALUES (?, 'bk', 'c.xhtml', 0, ?, ?, 'paragraph', ?, 0)
                        """,
                    arguments: ["b\(i)", i, i, name])
            }
        }
        let audioWords = Array(names.prefix(6))  // no "golf" in the transcript
        let words = audioWords.enumerated().map { i, w in
            StandaloneTranscribedWord(
                word: w, start: Double(i) + 1.0, end: Double(i) + 1.4, confidence: 0.9)
        }
        let json = String(data: try! JSONEncoder().encode(words), encoding: .utf8)!
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO standalone_transcript
                      (id, audiobook_id, chapter_index, segment_index, text,
                       start_time, end_time, words_json, created_at)
                    VALUES ('s0','bk',0,0,'alpha bravo charlie delta echo foxtrot',
                            1.0, 6.4, ?, 'now')
                    """,
                arguments: [json])
        }

        try await SourceBackedAlignmentCoordinator.align(audiobookID: "bk", dbService: db)

        let lowConf = try SourceBackedAlignmentCoordinator.lowConfidenceWordCount(
            audiobookID: "bk", dbService: db)
        // The unmatched block "golf" stays interpolated at 0.5; the 6 matched blocks
        // get DTW-refined timing at 0.85, so exactly 1 word is low-confidence.
        #expect(lowConf == 1)

        let total = try WordTimingDAO(db: db.writer).words(forAudiobook: "bk").count
        // All 7 blocks have word timing rows via interpolation (refined for matches).
        #expect(total == 7)
        #expect(lowConf < total)
    }
}
