// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

/// Regression cover for the word-timing loss where one authored word is spoken
/// as more than one space-delimited phoneme group.
///
/// Kokoro's duration head is grouped into words by splitting on the space token,
/// but three constructions put a space *inside* a single whitespace-delimited
/// word: an intra-word hyphen (Misaki gives "-" the phoneme " "), a CamelCase
/// compound (Misaki inserts a word break between the parts), and any future
/// construction that does the same. Before the fix the group count exceeded the
/// authored word count and `KokoroWordTimer` discarded the timings for the whole
/// block, silently dropping word-level read-along for that paragraph.
@Suite struct AuthoredWordPhonemeGroupingTests {
    /// Space-delimited phoneme runs — the groups `KokoroWordTimer` builds from
    /// the token ids, derived independently here from the phoneme string.
    private func spokenGroupCount(in phonemes: String) -> Int {
        phonemes.split(separator: " ", omittingEmptySubsequences: true).count
    }

    @Test(
        arguments: [
            // (text, authored words, spoken groups)
            ("The seam has to be heard, even when it cannot be seen.", 12, 12),
            ("A well-tempered answer and a half-lit room.", 7, 9),
            ("EchoCore calls NarrationService which asks PronunciationPlanner.", 6, 9),
            // v15's dotted identifiers already held; they must keep holding.
            ("Shared CLAUDE.md files coordinate work.", 5, 5),
            ("Visit docs.anthropic.com next.", 3, 3),
        ])
    func groupCountsCoverEveryAuthoredWordAndEverySpokenGroup(
        _ text: String, _ words: Int, _ groups: Int
    ) throws {
        let plan = try PronunciationPlanner().planResolved(text)
        #expect(plan.wordCount == words)
        #expect(spokenGroupCount(in: plan.phonemes) == groups)

        let counts = try #require(
            plan.authoredWordGroupCounts,
            "expected a proven authored-word grouping for \(text)")
        #expect(counts.count == words)
        #expect(counts.reduce(0, +) == groups)
        #expect(counts.allSatisfy { $0 > 0 })
    }

    /// The end-to-end contract the bug broke: every authored word gets exactly
    /// one timing span. Frames are synthetic (the duration head is not needed to
    /// prove the token-to-word mapping), but the ids are the real planned ids.
    @Test(
        arguments: [
            "The seam has to be heard, even when it cannot be seen.",
            "A well-tempered answer and a half-lit room.",
            "EchoCore calls NarrationService which asks PronunciationPlanner.",
            "Shared CLAUDE.md files coordinate work.",
        ])
    func everyAuthoredWordKeepsATimingSpan(_ text: String) throws {
        let plan = try PronunciationPlanner().planResolved(text)
        let timings = try #require(
            KokoroWordTimer.wordTimings(
                ids: plan.phonemeIDs,
                perTokenFrames: [Float](repeating: 1, count: plan.phonemeIDs.count),
                wordCount: plan.wordCount,
                wordGroupCounts: plan.authoredWordGroupCounts,
                sampleCount: 24_000,
                sampleRate: 24_000),
            "expected word timings for \(text)")

        #expect(timings.count == plan.wordCount)
        #expect(timings.map(\.wordIndex) == Array(0..<plan.wordCount))
        for i in 1..<timings.count {
            #expect(timings[i].start >= timings[i - 1].end - 1e-9)
        }
        #expect(timings.allSatisfy { $0.end > $0.start })
    }

    /// A hyphenated compound spans the same audio as the spaced spelling, so its
    /// single word must span both groups — start of the first, end of the last.
    @Test func hyphenatedCompoundSpansBothOfItsSpokenGroups() throws {
        let plan = try PronunciationPlanner().planResolved("A well-tempered answer.")
        let counts = try #require(plan.authoredWordGroupCounts)
        // "A" = 1 group, "well-tempered" = 2, "answer." = 1
        #expect(counts == [1, 2, 1])
    }

    @Test func camelCaseCompoundSpansBothOfItsSpokenGroups() throws {
        let plan = try PronunciationPlanner().planResolved("EchoCore ships.")
        let counts = try #require(plan.authoredWordGroupCounts)
        #expect(counts == [2, 1])
    }
}
