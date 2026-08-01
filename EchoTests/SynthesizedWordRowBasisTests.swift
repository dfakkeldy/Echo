// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// The narration path materializes `word_timing` rows from the text it *spoke*.
/// When `TextNormalizer` expanded a number ("1,200" -> "one thousand two
/// hundred") that produced more rows than the block's source text has words,
/// which is the basis every reader indexes (`WordTokenizer`, and
/// `ParagraphCardCell.wordRanges` over the displayed text). The surplus rows
/// fell outside the reader's word ranges and the surviving ones highlighted the
/// wrong word; the sidecar export guard in `HeadlessNarrationRunner` refused
/// them outright, so read-along died for the paragraph.
///
/// These tests pin the rows to the **source** word basis and prove the true
/// duration-head times survive the fold.
@Suite struct SynthesizedWordRowBasisTests {
    private static let sourceText = "It cost 1,200 dollars."
    private static let narratedText = "It cost one thousand two hundred dollars."

    private func seed(sourceText: String = sourceText) throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',10.0)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                        (id, audiobook_id, spine_href, spine_index, block_index,
                         sequence_index, block_kind, text)
                    VALUES ('b0','bk','c1.xhtml',0,0,0,'paragraph',?)
                    """,
                arguments: [sourceText])
        }
        return db
    }

    private func rows(_ db: DatabaseService) throws -> [WordTimingRecord] {
        try WordTimingDAO(db: db.writer).words(forAudiobook: "bk", blockID: "b0")
    }

    /// A block whose narration expanded a number still gets exactly one row per
    /// *source* word, carrying the source word's own text.
    @Test func expandedBlockMaterializesOneRowPerSourceWord() throws {
        let db = try seed()
        try WordTimingMaterializer.materializeSynthesizedChapter(
            audiobookID: "bk",
            speechRangesByBlock: [
                "b0": [
                    NarrationSpeechRange(
                        blockID: "b0", text: Self.narratedText, start: 0, end: 4)
                ]
            ],
            writer: db.writer)

        let rows = try rows(db)
        #expect(rows.map(\.word) == ["It", "cost", "1,200", "dollars."])
        #expect(rows.map(\.wordIndex) == [0, 1, 2, 3])
    }

    /// The returned per-block counts are what lets `refineWithSynthesis` fold
    /// the narrated-basis synthesis timings onto these rows.
    @Test func materializeReportsTheExpansionItApplied() throws {
        let db = try seed()
        let counts = try WordTimingMaterializer.materializeSynthesizedChapter(
            audiobookID: "bk",
            speechRangesByBlock: [
                "b0": [
                    NarrationSpeechRange(
                        blockID: "b0", text: Self.narratedText, start: 0, end: 4)
                ]
            ],
            writer: db.writer)
        #expect(counts["b0"] == [1, 1, 4, 1])
    }

    /// The payload: the seven narrated synthesis spans fold onto four source
    /// rows, and the expanded word inherits the real start of "one" and the
    /// real end of "hundred" rather than an interpolated guess.
    @Test func synthesisTimesFoldOntoTheSourceWordRows() throws {
        let db = try seed()
        let counts = try WordTimingMaterializer.materializeSynthesizedChapter(
            audiobookID: "bk",
            speechRangesByBlock: [
                "b0": [
                    NarrationSpeechRange(
                        blockID: "b0", text: Self.narratedText, start: 0, end: 4)
                ]
            ],
            writer: db.writer)

        let narratedTimings = [
            ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.2),  // It
            ChunkWordTiming(wordIndex: 1, start: 0.2, end: 0.5),  // cost
            ChunkWordTiming(wordIndex: 2, start: 0.6, end: 0.9),  // one
            ChunkWordTiming(wordIndex: 3, start: 0.9, end: 1.3),  // thousand
            ChunkWordTiming(wordIndex: 4, start: 1.4, end: 1.6),  // two
            ChunkWordTiming(wordIndex: 5, start: 1.6, end: 2.0),  // hundred
            ChunkWordTiming(wordIndex: 6, start: 2.1, end: 2.7),  // dollars.
        ]
        let overridden = try WordTimingMaterializer.refineWithSynthesis(
            audiobookID: "bk",
            synthesisByBlock: ["b0": narratedTimings],
            expansionCountsByBlock: counts,
            writer: db.writer)

        #expect(overridden == 1)
        let rows = try rows(db)
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.source == "synthesis" })
        #expect(abs(rows[2].audioStartTime - 0.6) < 1e-6)
        #expect(abs(rows[2].audioEndTime - 2.0) < 1e-6)
        #expect(abs(rows[3].audioStartTime - 2.1) < 1e-6)
        #expect(abs(rows[3].audioEndTime - 2.7) < 1e-6)
    }

    /// Text that normalization left alone must keep the existing one-to-one
    /// behavior, so the common case pays nothing for the expansion path.
    @Test func unexpandedBlockKeepsOneRowPerWord() throws {
        let plain = "The lamp threw a narrow band of light."
        let db = try seed(sourceText: plain)
        let counts = try WordTimingMaterializer.materializeSynthesizedChapter(
            audiobookID: "bk",
            speechRangesByBlock: [
                "b0": [NarrationSpeechRange(blockID: "b0", text: plain, start: 0, end: 4)]
            ],
            writer: db.writer)

        let rows = try rows(db)
        #expect(rows.map(\.word) == WordTokenizer.words(in: plain).map(String.init))
        #expect(counts["b0"] == [Int](repeating: 1, count: rows.count))
    }

    /// Fail closed: when the spoken text cannot be aligned back onto the source
    /// words, the rows stay on the text that was actually spoken (today's
    /// behavior) rather than inventing a mapping.
    @Test func unalignableNarrationFallsBackToTheSpokenBasis() throws {
        let db = try seed(sourceText: "alpha beta gamma")
        let counts = try WordTimingMaterializer.materializeSynthesizedChapter(
            audiobookID: "bk",
            speechRangesByBlock: [
                "b0": [
                    NarrationSpeechRange(
                        blockID: "b0", text: "totally different spoken words here",
                        start: 0, end: 4)
                ]
            ],
            writer: db.writer)

        #expect(counts["b0"] == nil)
        #expect(try rows(db).count == 5)  // the spoken words, as before
    }
}
