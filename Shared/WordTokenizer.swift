// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The single canonical definition of a read-along word. Word timing
/// (WordTimingInterpolator -> word_timing rows assigning each word a wordIndex)
/// and the readers (which highlight word[index]) MUST agree on word boundaries or
/// the karaoke highlight drifts. Both sides go through this type so the definition
/// cannot fork. Words are whitespace-delimited tokens where a separator is any
/// Unicode whitespace (`Character.isWhitespace` — space, newline, tab, NBSP,
/// vertical tab, form feed, U+2028/U+2029, etc.); runs of separators collapse;
/// attached punctuation stays with the token. Using the full Unicode whitespace
/// definition makes the non-whitespace token sequence invariant under any
/// whitespace normalization, so collapsed (`collapsedWhitespace()`,
/// `CharacterSet.newlines`) and raw callers produce identical word indices.
nonisolated enum WordTokenizer {
    /// Character ranges of each whitespace-delimited word, in reading order.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var wordStart: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let isSeparator = c.isWhitespace
            if isSeparator {
                if let start = wordStart {
                    ranges.append(start..<i)
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = i
            }
            i = text.index(after: i)
        }
        if let start = wordStart { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// The whitespace-delimited words, in reading order.
    static func words(in text: String) -> [Substring] {
        let t = text
        return wordRanges(in: t).map { t[$0] }
    }
}
