// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Overrides interpolated word start times with DTW-derived audio times where a
/// normalized DTW token maps onto a rendered word. Pure and order-preserving.
///
/// DTW tokens are normalized (lowercased, numbers expanded, sub-2-char dropped),
/// so the mapping is greedy: walk the block's rendered words and the strong DTW
/// matches in parallel, and when `TokenDTW.normalize(renderedWord)` shares its
/// first token with the match's token, adopt the match's audio time.
enum WordTimingRefiner {
    struct RefinedWord: Equatable {
        let index: Int
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let source: String  // "interpolated" or "dtw"
    }

    static func refine(
        words: [WordTimingInterpolator.Word],
        dtwMatches: [TokenDTW.WordMatch],
        minRunLength: Int = 3
    ) -> [RefinedWord] {
        // Confident matches only, in block-word order.
        let strong =
            dtwMatches
            .filter { $0.runLength >= minRunLength }
            .sorted { $0.wordIndexInBlock < $1.wordIndexInBlock }

        var refined: [RefinedWord] = words.map {
            RefinedWord(
                index: $0.index, word: $0.word,
                start: $0.start, end: $0.end, source: "interpolated")
        }

        var matchCursor = 0
        for i in refined.indices {
            guard matchCursor < strong.count else { break }
            guard let firstToken = TokenDTW.normalize(refined[i].word).first else { continue }
            if strong[matchCursor].token == firstToken {
                let start = strong[matchCursor].audioTime
                let end = max(start, refined[i].end)
                refined[i] = RefinedWord(
                    index: refined[i].index, word: refined[i].word,
                    start: start, end: end, source: "dtw")
                matchCursor += 1
            }
        }

        // Re-monotonize: a pulled-forward word must not precede its predecessor.
        for i in 1..<max(1, refined.count) {
            if refined[i].start < refined[i - 1].start {
                refined[i] = RefinedWord(
                    index: refined[i].index, word: refined[i].word,
                    start: refined[i - 1].start, end: max(refined[i - 1].start, refined[i].end),
                    source: refined[i].source)
            }
        }
        return refined
    }
}
