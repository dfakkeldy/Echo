// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationSynthesisTimingTests {
    @Test func recordsSpeechSegmentsAndSkipsSilence() {
        var timing = NarrationSynthesisTiming(blockID: "b0", blockStart: 10)
        timing.appendSpeech(text: "hello world", duration: 1.2)
        timing.appendSilence(duration: 0.5)
        timing.appendSpeech(text: "again", duration: 0.8)

        #expect(timing.blockEnd == 12.5)
        #expect(timing.speechRanges.map(\.start) == [10.0, 11.7])
        #expect(timing.speechRanges.map(\.end) == [11.2, 12.5])
    }
}
