// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The single canonical definition of a read-along word. Word timing
/// (WordTimingInterpolator -> word_timing rows assigning each word a wordIndex)
/// and the readers (which highlight word[index]) MUST agree on word boundaries or
/// the karaoke highlight drifts. Both sides go through this type so the definition
/// cannot fork. Words are whitespace-delimited tokens (separators: space, newline,
/// tab); runs of separators collapse; attached punctuation stays with the token.
enum WordTokenizer {
    /// Character ranges of each whitespace-delimited word, in reading order.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var wordStart: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let isSeparator = c == " " || c == "\n" || c == "\t"
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
