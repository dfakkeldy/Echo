// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationQADetectorTests {
    // Source sentence; the narrator "heard" version drops "brown" and swaps "lazy"->"crazy".
    private let blocks: [(blockID: String, text: String)] = [
        ("blk1", "the quick brown fox jumps over the lazy dog")
    ]

    private func heard(_ words: [(String, TimeInterval)]) -> [TranscribedWord] {
        words.map { TranscribedWord(text: $0.0, start: $0.1) }
    }

    @Test func cleanReadingProducesNoWindows() {
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("brown", 0.8), ("fox", 1.2), ("jumps", 1.6),
            ("over", 2.0), ("the", 2.4), ("lazy", 2.8), ("dog", 3.2),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words, audiobookID: "b1")
        #expect(windows.isEmpty)
    }

    @Test func omittedAndSubstitutedWordsBecomeWindows() {
        // "brown" omitted; "lazy" -> "crazy".
        let words = heard([
            ("the", 0.0), ("quick", 0.4), ("fox", 0.8), ("jumps", 1.2), ("over", 1.6),
            ("the", 2.0), ("crazy", 2.4), ("dog", 2.8),
        ])
        let windows = NarrationQADetector.detect(
            expectedBlocks: blocks, heardWords: words, audiobookID: "b1")
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
}
