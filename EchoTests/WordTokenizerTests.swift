// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo  // WordTokenizer lives in Shared, visible via the Echo target

/// The canonical word definition shared by the timing interpolator and both
/// readers. These tests pin the boundaries (attached punctuation stays with the
/// word; em-dash/apostrophe never split) and prove `words` and `wordRanges`
/// stay index-aligned so the karaoke highlight can't drift.
struct WordTokenizerTests {
    @Test func keepsTrailingPunctuationWithWord() {
        // "hello, world" → two words; the comma rides with word 0 (the case the
        // linguistic .byWords tokenizer got wrong by dropping punctuation).
        let words = WordTokenizer.words(in: "hello, world").map(String.init)
        #expect(words == ["hello,", "world"])
    }

    @Test func emDashDoesNotSplitAWord() {
        // "foo—bar" is a single whitespace-delimited token. `.byWords` split this
        // into 3 ("foo", "—" excluded, "bar"), which is exactly what drifted.
        let words = WordTokenizer.words(in: "foo—bar").map(String.init)
        #expect(words == ["foo—bar"])
        #expect(WordTokenizer.wordRanges(in: "foo—bar").count == 1)
    }

    @Test func apostropheStaysInsideWord() {
        let words = WordTokenizer.words(in: "don't stop").map(String.init)
        #expect(words == ["don't", "stop"])
    }

    @Test func collapsesRunsOfMixedSeparators() {
        // Multiple/mixed separators (space, tab, newline) collapse; no empties.
        let words = WordTokenizer.words(in: "a  b\tc\nd").map(String.init)
        #expect(words == ["a", "b", "c", "d"])
    }

    @Test func trimsLeadingAndTrailingWhitespace() {
        let words = WordTokenizer.words(in: "  \t leading and trailing \n ").map(String.init)
        #expect(words == ["leading", "and", "trailing"])
    }

    @Test func emptyStringYieldsNoWords() {
        #expect(WordTokenizer.words(in: "").isEmpty)
        #expect(WordTokenizer.wordRanges(in: "").isEmpty)
    }

    @Test func whitespaceOnlyYieldsNoWords() {
        #expect(WordTokenizer.words(in: "   \t\n ").isEmpty)
        #expect(WordTokenizer.wordRanges(in: "   \t\n ").isEmpty)
    }

    /// The load-bearing invariant: `words` and `wordRanges` must agree exactly,
    /// element-for-element, so word index N highlights the same token N that was
    /// timed. Uses a punctuation-heavy string to stress the boundaries.
    @Test func wordsAndRangesStayIndexAligned() {
        let s = "  He said, \"Wait—don't!\"  Then\tthey\nleft.  "
        let words = WordTokenizer.words(in: s)
        let ranges = WordTokenizer.wordRanges(in: s)
        #expect(words.count == ranges.count)
        for i in words.indices {
            #expect(String(words[i]) == String(s[ranges[i]]))
        }
    }
}
