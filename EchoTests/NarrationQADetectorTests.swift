// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationQADetectorTests {
    // Source sentence; the narrator "heard" version drops "brown" and swaps "lazy"->"crazy".
    private let blocks: [(blockID: String, text: String)] = [
        ("blk1", "the quick brown fox jumps over the lazy dog")
    ]

    private func heard(_ words: [(String, TimeInterval, Double)]) -> [TranscribedWord] {
        words.map { TranscribedWord(text: $0.0, start: $0.1, confidence: $0.2) }
    }

    private func heard(_ words: [(String, TimeInterval)]) -> [TranscribedWord] {
        heard(words.map { ($0.0, $0.1, 1.0) })
    }

    @Test func cleanReadingProducesNoWindows() {
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("brown", 0.8), ("fox", 1.2), ("jumps", 1.6),
            ("over", 2.0), ("the", 2.4), ("lazy", 2.8), ("dog", 3.2),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words)
        #expect(windows.isEmpty)
    }

    @Test func omittedAndSubstitutedWordsBecomeWindows() {
        // "brown" omitted; "lazy" -> "crazy".
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("fox", 0.8), ("jumps", 1.2), ("over", 1.6),
            ("the", 2.0), ("crazy", 2.4), ("dog", 2.8),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words)
        #expect(!windows.isEmpty)
        // Every window names blk1 and references real source-word indices.
        #expect(windows.allSatisfy { $0.blockID == "blk1" })
        #expect(windows.allSatisfy { $0.expectedWordStart <= $0.expectedWordEnd })
        // The substituted/omitted source words ("brown" idx 2, "lazy" idx 7) are covered.
        let covered =
            windows.contains { $0.expectedWordStart <= 2 && 2 <= $0.expectedWordEnd }
            || windows.contains { $0.expectedWordStart <= 7 && 7 <= $0.expectedWordEnd }
        #expect(covered)
    }

    @Test func substitutedWordCarriesHeardText() {
        // Only "lazy" (idx 7) diverges — read as "crazy". The window for that gap
        // must carry what the transcriber actually heard, not an empty string.
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("brown", 0.8), ("fox", 1.2), ("jumps", 1.6),
            ("over", 2.0), ("the", 2.4), ("crazy", 2.8), ("dog", 3.2),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words)
        let lazyWindow = windows.first { $0.expectedWordStart <= 7 && 7 <= $0.expectedWordEnd }
        #expect(lazyWindow?.heardText.contains("crazy") == true)
    }

    @Test func leadingSubstitutionCarriesHeardText() {
        let words = heard([
            ("crazy", 0.0), ("dog", 0.4),
        ])

        let windows = NarrationQADetector.detect(
            expectedBlocks: [("blk1", "lazy dog")],
            heardWords: words)

        #expect(windows.count == 1)
        #expect(windows.first?.expectedText == "lazy")
        #expect(windows.first?.heardText == "crazy")
    }

    @Test func trailingSubstitutionCarriesHeardText() {
        let words = heard([
            ("the", 0.0), ("crazy", 0.4),
        ])

        let windows = NarrationQADetector.detect(
            expectedBlocks: [("blk1", "the lazy")],
            heardWords: words)

        #expect(windows.count == 1)
        #expect(windows.first?.expectedText == "lazy")
        #expect(windows.first?.heardText == "crazy")
    }

    @Test func insertedWordsBecomeInsertionWindow() {
        let words = heard([
            ("quick", 0.0), ("very", 0.4), ("brown", 0.8), ("fox", 1.2),
        ])

        let windows = NarrationQADetector.detect(
            expectedBlocks: [("blk1", "quick brown fox")],
            heardWords: words)

        #expect(windows.count == 1)
        #expect(windows.first?.expectedText == "")
        #expect(windows.first?.heardText == "very")
    }

    @Test func blockEndOmissionDoesNotConsumeLaterInsertion() {
        let words = heard([
            ("quick", 0.0), ("fox", 0.4), ("very", 0.8), ("jumps", 1.2),
        ])

        let windows = NarrationQADetector.detect(
            expectedBlocks: [("blk1", "quick brown"), ("blk2", "fox jumps")],
            heardWords: words)

        let omission = windows.first { $0.blockID == "blk1" && $0.expectedText == "brown" }
        #expect(omission?.heardText == "")

        let insertion = windows.first { $0.blockID == "blk2" && $0.expectedText == "" }
        #expect(insertion?.heardText == "very")
    }

    @Test func singleLetterInsertedWordsAreIgnored() {
        let words = heard([
            ("quick", 0.0), ("a", 0.4), ("brown", 0.8), ("fox", 1.2),
        ])

        let windows = NarrationQADetector.detect(
            expectedBlocks: [("blk1", "quick brown fox")],
            heardWords: words)

        #expect(windows.isEmpty)
    }

    @Test func lowConfidenceMatchedWordBecomesWindow() {
        let words = heard([
            ("quick", 0.0, 1.0), ("brown", 0.4, 0.3), ("fox", 0.8, 1.0),
        ])

        let windows = NarrationQADetector.detect(
            expectedBlocks: [("blk1", "quick brown fox")],
            heardWords: words)

        #expect(windows.count == 1)
        #expect(windows.first?.expectedText == "brown")
        #expect(windows.first?.heardText == "brown")
        #expect(windows.first?.confidence == 0.3)
    }

    @Test func omittedWordKeepsEmptyHeardText() {
        // "brown" (idx 2) dropped entirely — nothing was spoken in its place, so the
        // window stays an omission (empty heard text), not a phantom substitution.
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("fox", 1.2), ("jumps", 1.6),
            ("over", 2.0), ("the", 2.4), ("lazy", 2.8), ("dog", 3.2),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words)
        let brownWindow = windows.first { $0.expectedWordStart <= 2 && 2 <= $0.expectedWordEnd }
        #expect(brownWindow?.heardText.isEmpty == true)
    }

    @Test func cleanReadingWithNumberAndShortWordProducesNoWindows() {
        // "I" normalizes to zero tokens and "7" expands to one token ("seven"),
        // so the source-word index and the normalized-token ordinal diverge after
        // word 0. A correct narration must still yield no divergence windows — a
        // regression guard for the token-ordinal vs source-word-index mismatch.
        let block: [(blockID: String, text: String)] = [("blkN", "I have 7 brown cats")]
        let words = heard([
            ("have", 0.0), ("seven", 0.4), ("brown", 0.8), ("cats", 1.2),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: block, heardWords: words)
        #expect(windows.isEmpty)
    }
}
