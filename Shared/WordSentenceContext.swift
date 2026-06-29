// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Extracts the sentence containing a given word, for vocabulary-card context.
enum WordSentenceContext {
    /// The sentence within `text` that contains `wordRange.location`. Sentence
    /// boundaries are `.`, `!`, `?` followed by whitespace/end. Falls back to the
    /// whole (trimmed) text when no boundary surrounds the word.
    static func sentence(containing wordRange: NSRange, in text: String) -> String {
        let ns = text as NSString
        guard wordRange.location != NSNotFound, wordRange.location <= ns.length else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let terminators = CharacterSet(charactersIn: ".!?")
        let whitespace = CharacterSet.whitespacesAndNewlines

        func isWhitespace(at index: Int) -> Bool {
            guard index >= 0, index < ns.length,
                let scalar = Unicode.Scalar(ns.character(at: index))
            else { return false }
            return whitespace.contains(scalar)
        }
        // A terminator only ends a sentence when it is followed by whitespace
        // or the end of the text — otherwise the "." in "3.14" or "U.S." would
        // split mid-token. (Matches this function's documented boundary rule.)
        func isBoundary(at index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(ns.character(at: index)),
                terminators.contains(scalar)
            else { return false }
            return index + 1 >= ns.length || isWhitespace(at: index + 1)
        }

        // Start: just after the previous sentence boundary before the word.
        var start = 0
        var i = wordRange.location - 1
        while i >= 0 {
            if isBoundary(at: i) {
                start = i + 1
                break
            }
            i -= 1
        }
        // End: the first sentence boundary at or after the word's last
        // character, so a word-final terminator ("passed!") is honored rather
        // than skipped by starting one past the word.
        var end = ns.length
        var j = max(wordRange.location, NSMaxRange(wordRange) - 1)
        while j < ns.length {
            if isBoundary(at: j) {
                end = j + 1
                break
            }
            j += 1
        }
        guard start < end else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sentence = ns.substring(with: NSRange(location: start, length: end - start))
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
