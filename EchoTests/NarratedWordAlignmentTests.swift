// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

/// Regression cover for the word-timing loss where `TextNormalizer` speaks one
/// authored word as several — "1,200" becomes "one thousand two hundred".
///
/// Sibling to `AuthoredWordPhonemeGroupingTests`, one layer up. That suite maps
/// spoken *phoneme groups* onto the narrated word sequence; this one maps the
/// narrated word sequence back onto the **source** words the reader tokenizes
/// and highlights. Before the fix the narration path materialized `word_timing`
/// rows against the narrated text, so a block containing a number got more rows
/// than its source had words: the surplus rows fell outside the reader's word
/// ranges and the surviving rows highlighted the wrong word, while the export
/// guard in `HeadlessNarrationRunner.captureEntries` (rightly) refused to write
/// them to the sidecar at all — `words: []`, and read-along died for the
/// paragraph.
@Suite struct NarratedWordAlignmentTests {
    /// Text that survives normalization unchanged must map one-to-one, so the
    /// overwhelmingly common case cannot pay for the expansion machinery.
    @Test(
        arguments: [
            "The quick brown fox jumps over the lazy dog.",
            "Silence, then thunder; nothing else.",
            "A well-worn path led downhill.",
        ])
    func unchangedTextMapsEveryWordToItself(_ text: String) throws {
        let counts = try #require(
            NarratedWordAlignment.expansionCounts(source: text, narrated: text),
            "expected an identity mapping for \(text)")
        #expect(counts == [Int](repeating: 1, count: WordTokenizer.words(in: text).count))
    }

    /// The bug class: the real `TextNormalizer` output, aligned back onto the
    /// authored words. Counts are pinned exactly so a normalizer change that
    /// silently shifts an expansion is caught here rather than in a render.
    @Test(
        arguments: [
            // (source, per-source-word narrated word counts)
            ("It cost 1,200 dollars.", [1, 1, 4, 1]),
            ("Completion hit 100%.", [1, 1, 3]),
            ("A 1.6% lift became 2500%.", [1, 4, 1, 1, 5]),
            ("Use a wedge, e.g. a doorstop.", [1, 1, 1, 2, 1, 1]),
            // Currency stays one-to-one here. Misaki expands it semantically
            // later, and `authoredWordGroupCounts` folds that speech back onto
            // the single authored currency word.
            ("The fee was $45.", [1, 1, 1, 1]),
            ("The train leaves at 3:15.", [1, 1, 1, 1, 2]),
            // A replacement word that also occurs earlier must not steal the anchor.
            ("The word percent appears before 40% here.", [1, 1, 1, 1, 1, 2, 1]),
            // Abbreviation expansion substitutes one spoken word for one
            // authored word, so every count stays 1 — including two expansions
            // in the same sentence, which the untouched words between them
            // anchor independently.
            ("Mt. Everest rose 40 km ahead.", [1, 1, 1, 1, 1, 1]),
            ("Snow fell in Feb. 1987.", [1, 1, 1, 1, 1]),
            ("It weighed approx. 40 pounds.", [1, 1, 1, 1, 1]),
        ])
    func normalizerExpansionsMapBackOntoTheAuthoredWords(
        _ source: String, _ expected: [Int]
    ) throws {
        let narrated = TextNormalizer.normalize(source)
        let counts = try #require(
            NarratedWordAlignment.expansionCounts(source: source, narrated: narrated),
            "expected a proven mapping for \(source)")
        #expect(counts == expected)
        #expect(counts.count == WordTokenizer.words(in: source).count)
        #expect(counts.reduce(0, +) == WordTokenizer.words(in: narrated).count)
    }

    /// Fail closed. A mapping that cannot be proven must be `nil` so the caller
    /// keeps interpolation instead of shifting every later word onto the wrong
    /// audio — the same discipline `KokoroWordTimer` applies to phoneme groups.
    @Test(
        arguments: [
            // A source word with no narrated counterpart.
            ("keep this word", "keep this"),
            // Narrated words owned by no source word.
            ("keep this", "keep this word"),
            ("", "anything"),
        ])
    func refusesToGuessWhenTheMappingIsUnproven(_ source: String, _ narrated: String) {
        #expect(NarratedWordAlignment.expansionCounts(source: source, narrated: narrated) == nil)
    }

    /// The payload: several narrated spans collapse into one source-word span
    /// running from the first narrated word's start to the last one's end. The
    /// silence between "one thousand" and "two hundred" belongs to the authored
    /// word "1,200", not to an inter-word gap.
    @Test func collapseGivesEachSourceWordOneSpanCoveringItsNarratedWords() throws {
        // "It cost 1,200 dollars." -> It | cost | one thousand two hundred | dollars.
        let narrated = [
            ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.2),  // It
            ChunkWordTiming(wordIndex: 1, start: 0.2, end: 0.5),  // cost
            ChunkWordTiming(wordIndex: 2, start: 0.6, end: 0.9),  // one
            ChunkWordTiming(wordIndex: 3, start: 0.9, end: 1.3),  // thousand
            ChunkWordTiming(wordIndex: 4, start: 1.4, end: 1.6),  // two
            ChunkWordTiming(wordIndex: 5, start: 1.6, end: 2.0),  // hundred
            ChunkWordTiming(wordIndex: 6, start: 2.1, end: 2.7),  // dollars.
        ]
        let collapsed = try #require(
            NarratedWordAlignment.collapse(narrated, counts: [1, 1, 4, 1]))

        #expect(collapsed.map(\.wordIndex) == [0, 1, 2, 3])
        #expect(collapsed[2].start == 0.6)  // "one"
        #expect(collapsed[2].end == 2.0)  // "hundred"
        #expect(collapsed[3].start == 2.1)
        #expect(collapsed[3].end == 2.7)
    }

    /// Collapse must reject a grouping that doesn't account for exactly these
    /// timings, rather than silently dropping or inventing a span.
    @Test func collapseRejectsCountsThatDoNotAccountForEveryTiming() {
        let timings = (0..<3).map {
            ChunkWordTiming(wordIndex: $0, start: Double($0), end: Double($0) + 1)
        }
        #expect(NarratedWordAlignment.collapse(timings, counts: [1, 1]) == nil)
        #expect(NarratedWordAlignment.collapse(timings, counts: [1, 1, 1, 1]) == nil)
        #expect(NarratedWordAlignment.collapse(timings, counts: [1, 0, 2]) == nil)
    }
}
