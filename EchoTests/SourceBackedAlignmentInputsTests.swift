// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct SourceBackedAlignmentInputsTests {
    private func encodeWords(_ words: [StandaloneTranscribedWord]) -> String {
        String(data: try! JSONEncoder().encode(words), encoding: .utf8)!
    }

    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',100)")
            // Two visible blocks + one hidden + one empty-text → only the two
            // visible non-empty blocks become tokens.
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph','hello world', 0),
                           ('b1','bk','c.xhtml',0,1,1,'paragraph','goodbye now', 0),
                           ('bh','bk','c.xhtml',0,2,2,'paragraph','hidden text', 1),
                           ('be','bk','c.xhtml',0,3,3,'paragraph','', 0)
                    """)
        }
        let seg0 = encodeWords([
            StandaloneTranscribedWord(word: "hello", start: 1.0, end: 1.4, confidence: 0.9),
            StandaloneTranscribedWord(word: "world", start: 1.5, end: 1.9, confidence: 0.9),
        ])
        let seg1 = encodeWords([
            StandaloneTranscribedWord(word: "goodbye", start: 2.0, end: 2.4, confidence: 0.9),
            StandaloneTranscribedWord(word: "now", start: 2.5, end: 2.9, confidence: 0.9),
        ])
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO standalone_transcript
                      (id, audiobook_id, chapter_index, segment_index, text,
                       start_time, end_time, words_json, created_at)
                    VALUES ('s1','bk',0,1,'goodbye now',2.0,2.9,?,'now'),
                           ('s0','bk',0,0,'hello world',1.0,1.9,?,'now')
                    """,
                arguments: [seg1, seg0])
        }
    }

    @Test func epubTokensSkipHiddenAndEmpty() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db)
        let tokens = try SourceBackedAlignmentCoordinator.epubTokens(
            audiobookID: "bk", dbService: db)
        #expect(tokens.map(\.blockID) == ["b0", "b1"])
        #expect(tokens.map(\.text) == ["hello world", "goodbye now"])
    }

    @Test func audioTokensOrderedByChapterThenSegmentWithAbsoluteTimes() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db)
        let audio = try SourceBackedAlignmentCoordinator.audioTokens(
            audiobookID: "bk", dbService: db)
        #expect(audio.map(\.text) == ["hello", "world", "goodbye", "now"])
        #expect(abs(audio[0].time - 1.0) < 0.001)
        #expect(abs(audio[3].time - 2.5) < 0.001)
    }
}
