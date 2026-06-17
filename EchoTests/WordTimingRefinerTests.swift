// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct WordTimingRefinerTests {
    @Test func overridesMatchedWordsWithAudioTimesKeepsRestInterpolated() {
        let interpolated = [
            WordTimingInterpolator.Word(index: 0, word: "Hello", start: 0.0, end: 0.5),
            WordTimingInterpolator.Word(index: 1, word: "world", start: 0.5, end: 1.0),
        ]
        let matches = [
            TokenDTW.WordMatch(
                blockID: "b0", wordIndexInBlock: 1, token: "world",
                audioTime: 0.9, runLength: 3)
        ]
        let refined = WordTimingRefiner.refine(
            words: interpolated, dtwMatches: matches, minRunLength: 3)
        // word 0 unchanged (interpolated), word 1 start pulled to the audio time
        #expect(abs(refined[0].start - 0.0) < 0.001 && refined[0].source == "interpolated")
        #expect(abs(refined[1].start - 0.9) < 0.001 && refined[1].source == "dtw")
        // still monotonic
        #expect(refined[1].start >= refined[0].start)
    }
}
