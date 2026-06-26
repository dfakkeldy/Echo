// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct KokoroWordTimerTests {
    // ids: [BOS, 'a','a', space, 'b','b', EOS]; frames sum = 13; 1.0 s of audio.
    private let ids: [Int32] = [0, 43, 43, 16, 44, 44, 0]
    private let frames: [Float] = [1, 2, 2, 1, 3, 3, 1]

    @Test func mapsTwoWordsNormalizedToAudioLength() throws {
        let out = try #require(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: frames, wordCount: 2,
                sampleCount: 24_000, sampleRate: 24_000))
        #expect(out.count == 2)
        #expect(out[0].wordIndex == 0 && out[1].wordIndex == 1)
        // word 0 = tokens 1..2 → frames [1..5) of 13; word 1 = tokens 4..5 → [6..12)
        #expect(abs(out[0].start - 1.0 / 13.0) < 1e-6)
        #expect(abs(out[0].end - 5.0 / 13.0) < 1e-6)
        #expect(abs(out[1].start - 6.0 / 13.0) < 1e-6)
        #expect(abs(out[1].end - 12.0 / 13.0) < 1e-6)
        // monotonic, non-overlapping, within bounds
        #expect(out[1].start >= out[0].end)
        #expect(out[1].end <= 1.0 + 1e-9)
    }

    @Test func returnsNilWhenWordCountMismatch() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: frames, wordCount: 3,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }

    @Test func returnsNilWhenFramesCountMismatch() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: [1, 2, 3], wordCount: 2,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }

    @Test func returnsNilWhenAllBoundary() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: [0, 0], perTokenFrames: [1, 1], wordCount: 1,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }

    @Test func returnsNilWhenNoFrames() {
        #expect(
            KokoroWordTimer.wordTimings(
                ids: ids, perTokenFrames: [Float](repeating: 0, count: 7), wordCount: 2,
                sampleCount: 24_000, sampleRate: 24_000) == nil)
    }
}
