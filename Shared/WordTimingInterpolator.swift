// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Distributes a block's rendered words across `[blockStart, blockEnd)` by
/// character weight (word length plus the following space, except the final
/// word which has no trailing space). Pure and dependency-free so it lives in
/// `Shared/` and is unit-testable in isolation.
///
/// This is the robust read-along foundation: it needs only the block's real
/// start/end times (which the alignment pipeline already produces), not any
/// per-word audio data. `WordTimingRefiner` (Task A4) optionally overrides
/// individual word times with DTW-derived audio timestamps.
enum WordTimingInterpolator {
    struct Word: Equatable {
        let index: Int
        let word: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// - Parameters:
    ///   - text: the block's plain text (already newline-collapsed by the caller).
    ///   - blockStart: audio time the block begins.
    ///   - blockEnd: audio time the block ends (next block's start, or an estimate).
    static func interpolate(text: String, blockStart: TimeInterval, blockEnd: TimeInterval)
        -> [Word]
    {
        let words = WordTokenizer.words(in: text).map(String.init)
        guard !words.isEmpty else { return [] }

        let span = max(0, blockEnd - blockStart)
        // Weight each word by its length plus the single space that follows it,
        // so longer words get proportionally more time. The final word has no
        // trailing space, so it is weighted by its length alone.
        let lastIndex = words.count - 1
        let weights = words.enumerated().map { i, word in
            Double(word.count + (i == lastIndex ? 0 : 1))
        }
        let total = max(1, weights.reduce(0, +))

        var result: [Word] = []
        var cursor: Double = 0
        for (i, word) in words.enumerated() {
            let start = blockStart + (cursor / total) * span
            cursor += weights[i]
            let end = blockStart + (cursor / total) * span
            result.append(Word(index: i, word: word, start: start, end: end))
        }
        return result
    }
}
