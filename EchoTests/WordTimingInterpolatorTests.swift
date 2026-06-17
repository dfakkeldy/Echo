// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo  // WordTimingInterpolator lives in Shared, visible via the Echo target

struct WordTimingInterpolatorTests {
    @Test func splitsWordsProportionallyByCharacterLength() {
        // "ab cde" → "ab"(2) + space + "cde"(3); 5 weighted chars over [0,10).
        let words = WordTimingInterpolator.interpolate(
            text: "ab cde", blockStart: 0, blockEnd: 10)
        #expect(words.count == 2)
        #expect(words[0].index == 0 && words[0].word == "ab")
        #expect(abs(words[0].start - 0.0) < 0.001)
        // "ab" + trailing space = 3 weight of 6 total → ends at 5.0
        #expect(abs(words[0].end - 5.0) < 0.001)
        #expect(words[1].word == "cde")
        #expect(abs(words[1].start - 5.0) < 0.001)
        #expect(abs(words[1].end - 10.0) < 0.001)
    }

    @Test func emptyTextProducesNoWords() {
        #expect(WordTimingInterpolator.interpolate(text: "   ", blockStart: 0, blockEnd: 5).isEmpty)
    }

    @Test func monotonicNonOverlappingTimes() {
        let words = WordTimingInterpolator.interpolate(
            text: "the quick brown fox", blockStart: 2, blockEnd: 6)
        for i in 1..<words.count {
            #expect(words[i].start >= words[i - 1].end - 0.0001)
        }
        #expect(words.first!.start >= 2)
        #expect(words.last!.end <= 6.0001)
    }
}
