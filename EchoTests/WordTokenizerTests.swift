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

    // MARK: - Unicode whitespace (collapse-invariance across readers)

    @Test func nonBreakingSpaceSplitsWords() {
        // NBSP (U+00A0) is a separator under Character.isWhitespace; the materializer
        // and cells normalize it away, so the tokenizer must split on it too or the
        // karaoke highlight goes off-by-one from this scalar onward.
        let words = WordTokenizer.words(in: "foo\u{00A0}bar").map(String.init)
        #expect(words == ["foo", "bar"])
    }

    @Test func lineSeparatorSplitsWords() {
        // U+2028 LINE SEPARATOR is Unicode whitespace; it must split like a newline.
        let words = WordTokenizer.words(in: "foo\u{2028}bar").map(String.init)
        #expect(words == ["foo", "bar"])
    }

    @Test func tokenizationIsInvariantUnderNewlineCollapse() {
        // The whole point: feeding raw text (macOS MacReaderFeedView) and the
        // newline-collapsed form (materializer / cells) must yield the SAME word
        // count and order, so word index N means the same token on every reader.
        let raw = "a\u{00A0}b  c"
        let collapsed = raw.collapsedWhitespace()  // "a b c"
        let rawWords = WordTokenizer.words(in: raw).map(String.init)
        let collapsedWords = WordTokenizer.words(in: collapsed).map(String.init)
        #expect(rawWords == collapsedWords)
        #expect(rawWords == ["a", "b", "c"])
    }

    @Test func trailingExoticWhitespaceExcludedFromFinalRange() {
        // A trailing NBSP must not be folded into the last word's range, or the
        // highlight box would extend past the visible glyphs.
        let s = "word\u{00A0}"
        let ranges = WordTokenizer.wordRanges(in: s)
        #expect(ranges.count == 1)
        #expect(String(s[ranges[0]]) == "word")
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
