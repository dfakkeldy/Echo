import Foundation
import Testing

@testable import Echo

@Suite struct NarrationTextChunkerTests {

    @Test func shortTextIsReturnedWhole() {
        let pieces = NarrationTextChunker.split("Hello there.", maxChars: 200)
        #expect(pieces == ["Hello there."])
    }

    @Test func emptyAndWhitespaceYieldNoPieces() {
        #expect(NarrationTextChunker.split("", maxChars: 200).isEmpty)
        #expect(NarrationTextChunker.split("   \n\t  ", maxChars: 200).isEmpty)
    }

    @Test func longMultiSentenceParagraphSplitsAtSentenceBoundaries() {
        // A 442-char paragraph of multiple sentences. Each piece must be <= 200
        // and must break at sentence boundaries (no piece should end mid-word
        // with a trailing partial sentence — every piece ends in terminal punct).
        let p = String(
            repeating:
                "The quick brown fox jumps over the lazy dog near the riverbank. ",
            count: 7
        ).trimmingCharacters(in: .whitespaces)
        #expect(p.count == 447)  // a >442-char multi-sentence paragraph

        let pieces = NarrationTextChunker.split(p, maxChars: 200)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 200 })
        // Sentence-boundary split: every piece ends on a sentence terminator.
        #expect(pieces.allSatisfy { $0.hasSuffix(".") })
    }

    @Test func singleOverlongSentenceWrapsAtWordBoundaries() {
        // One sentence with no internal terminators, longer than maxChars: must
        // wrap at word boundaries, every piece <= maxChars, no word cut in half.
        let words = Array(repeating: "alpha", count: 60).joined(separator: " ")  // ~ 5*60+59 = 359
        #expect(words.count > 200)
        #expect(!words.contains("."))

        let pieces = NarrationTextChunker.split(words, maxChars: 200)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 200 })
        // No word was hard-split: every space-separated token is intact.
        for piece in pieces {
            for token in piece.split(separator: " ") {
                #expect(token == "alpha")
            }
        }
    }

    @Test func singleWordLongerThanBudgetIsHardSplit() {
        let word = String(repeating: "x", count: 450)
        let pieces = NarrationTextChunker.split(word, maxChars: 200)
        #expect(pieces.count == 3)  // 200 + 200 + 50
        #expect(pieces.allSatisfy { $0.count <= 200 })
        #expect(pieces.joined() == word)  // hard-split loses nothing
    }

    @Test func coverageJoinedPiecesContainAllOriginalWordsInOrder() {
        let p = "First sentence here. Second one follows! And a third; then a fourth one."
        let pieces = NarrationTextChunker.split(p, maxChars: 30)
        #expect(pieces.allSatisfy { $0.count <= 30 })

        let originalWords = p.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let pieceWords = pieces.joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        #expect(pieceWords == originalWords)
    }
}
