// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct TTSChunkWordTimingTests {
    @Test func chunkDefaultsToNilWordTimings() {
        let chunk = TTSChunk(samples: [0, 0], sampleRate: 24_000, duration: 0.1)
        #expect(chunk.wordTimings == nil)
    }

    @Test func silenceHasNilWordTimings() {
        let chunk = TTSChunk.silence(seconds: 0.5, sampleRate: 24_000)
        #expect(chunk.wordTimings == nil)
    }

    @Test func carriesWordTimingsWhenProvided() {
        let timings = [ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.2)]
        let chunk = TTSChunk(
            samples: [0], sampleRate: 24_000, duration: 0.2, wordTimings: timings)
        #expect(chunk.wordTimings == timings)
    }
}
