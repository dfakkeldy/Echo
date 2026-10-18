// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationChunkQualityTests {
    @Test func acceptsNonSilentSpeechWithPlausibleDuration() {
        let chunk = TTSChunk(samples: [0.05, -0.04, 0.03], sampleRate: 24_000, duration: 0.6)
        let report = NarrationChunkQuality.evaluate(chunk, text: "Hello there.")
        #expect(report == .acceptable)
    }

    @Test func rejectsEmptySamplesForSpeakableText() {
        let chunk = TTSChunk(samples: [], sampleRate: 24_000, duration: 0)
        let report = NarrationChunkQuality.evaluate(chunk, text: "Hello.")
        #expect(report == .rejected(.emptyAudio))
    }

    @Test func rejectsNearSilentSpeech() {
        let chunk = TTSChunk(samples: [0, 0, 0, 0], sampleRate: 24_000, duration: 1)
        let report = NarrationChunkQuality.evaluate(chunk, text: "Hello.")
        #expect(report == .rejected(.nearSilentAudio))
    }

    @Test func rejectsImplausiblyShortDuration() {
        let chunk = TTSChunk(samples: [0.05, 0.04], sampleRate: 24_000, duration: 0.02)
        let report = NarrationChunkQuality.evaluate(chunk, text: "This is a complete sentence.")
        #expect(report == .rejected(.implausibleDuration))
    }

    @Test func rejectsVeryShortParagraphEvenWhenNonSilent() {
        let chunk = TTSChunk(samples: [0.05, -0.05, 0.04], sampleRate: 24_000, duration: 0.3)
        let report = NarrationChunkQuality.evaluate(
            chunk,
            text: "Alpha beta gamma delta epsilon zeta eta theta iota kappa.")

        #expect(report == .rejected(.implausibleDuration))
    }
}
