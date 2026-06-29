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
        func isSentenceBoundary(at index: Int) -> Bool {
            guard index >= 0, index < ns.length else { return false }
            let c = ns.character(at: index)
            guard let scalar = Unicode.Scalar(c), terminators.contains(scalar) else {
                return false
            }
            let nextIndex = index + 1
            guard nextIndex < ns.length else { return true }
            let next = ns.character(at: nextIndex)
            return Unicode.Scalar(next)?.properties.isWhitespace == true
        }
        // Start: just after the previous terminator before the word.
        var start = 0
        var i = wordRange.location - 1
        while i >= 0 {
            if isSentenceBoundary(at: i) {
                start = i + 1
                break
            }
            i -= 1
        }
        // End: the first terminator at or after the word's end (inclusive).
        var end = ns.length
        var j = min(max(wordRange.location, 0), ns.length)
        while j < ns.length {
            if isSentenceBoundary(at: j) {
                end = j + 1
                break
            }
            j += 1
        }
        let sentence = ns.substring(with: NSRange(location: start, length: end - start))
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
