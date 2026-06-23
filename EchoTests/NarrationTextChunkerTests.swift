// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationTextChunkerTests {

    @Test func shortTextIsReturnedWhole() {
        let pieces = NarrationTextChunker.split("Hello there.", maxChars: 200)
        #expect(pieces == ["Hello there."])
    }

    @Test func defaultBudgetIsLargerThanTheOldFluidAudioCap() {
        // The 200-char cap was a FluidAudio/CoreML-era guard against a BNNS vocoder
        // trap; that engine is gone (ONNX CPU EP, no trap). The live ceiling is
        // Kokoro's ~510-phoneme context, which 200 chars under-uses ~2x. A larger
        // default means a multi-sentence paragraph that *used* to split into
        // separate synth calls (each ending with sentence-final prosody → an
        // audible "period") is now one utterance — fewer seams, less choppiness.
        let p = String(
            repeating: "The quick brown fox jumps over the lazy dog. ", count: 6
        ).trimmingCharacters(in: .whitespaces)
        #expect(p.count == 269)  // 6 sentences; would split at the old 200 cap

        let atOldCap = NarrationTextChunker.split(p, maxChars: 200)
        let atDefault = NarrationTextChunker.split(p)  // new, larger default
        #expect(atOldCap.count > atDefault.count)  // fewer synth calls now
        #expect(atDefault == [p])  // the whole paragraph is one utterance
        // Still safely under the ~510-phoneme model ceiling (~1.1-1.3 phonemes/char).
        #expect(atDefault.allSatisfy { $0.count <= 380 })
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

    @Test func decorativeSeparatorsYieldNoChunks() {
        // EPUB section breaks like "* * *" or "---" have no speakable
        // content — they should produce zero chunks instead of being
        // sent to the TTS engine as 5-char "sentences."
        #expect(NarrationTextChunker.split("* * *", maxChars: 200).isEmpty)
        #expect(NarrationTextChunker.split("---", maxChars: 200).isEmpty)
        #expect(NarrationTextChunker.split("~~~", maxChars: 200).isEmpty)
        #expect(NarrationTextChunker.split("  *   *   *  ", maxChars: 200).isEmpty)
    }

    @Test func decorativeSeparatorDroppedButTextOnEitherSideSurvives() {
        // "Down the rabbit hole. *  *  *  The rabbit hurried on."
        // The "* * *" section break becomes a 5-char chunk with no letters
        // after whitespace normalisation → it's dropped. The surrounding
        // real sentences survive (possibly merged since maxChars is large).
        let text = "Down the rabbit hole.  *  *  *  The rabbit hurried on."
        let pieces = NarrationTextChunker.split(text, maxChars: 200)
        #expect(!pieces.isEmpty)
        // The real content survives: "rabbit hole" and "rabbit hurried".
        let joined = pieces.joined(separator: " ")
        #expect(joined.contains("rabbit hole"))
        #expect(joined.contains("rabbit hurried"))
        // No piece should be purely decorative.
        for piece in pieces {
            let hasContent = piece.contains { $0.isLetter || $0.isNumber }
            #expect(hasContent)
        }
    }

    @Test func pronunciationOverrideLinkIsNotSplitOnIPADots() {
        // A pronunciation override rewrites a word as `[word](/ipa/)`, and an IPA
        // syllable separator "." must NOT trigger a sentence split — otherwise the
        // link is broken (spaces inserted inside it) and the override is lost.
        let text = "He met [Computer](/kəm.pjuː.tər/) today. Then he left."
        let pieces = NarrationTextChunker.split(text, maxChars: 200)
        let joined = pieces.joined(separator: "")
        // The link survives verbatim — no space injected between IPA syllables.
        #expect(joined.contains("[Computer](/kəm.pjuː.tər/)"))
        // Exactly one piece carries the whole link (it wasn't torn across chunks).
        #expect(pieces.filter { $0.contains("kəm.pjuː.tər") }.count == 1)
    }
}
