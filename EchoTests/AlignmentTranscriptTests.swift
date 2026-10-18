// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import WhisperKit
@testable import Echo

/// Tests the WhisperKit → `TranscribedWord` bridge.
///
/// With `chunkingStrategy: .vad`, one capture yields *multiple*
/// `TranscriptionResult`s (one per internal window) whose segment and word
/// timings are seek-adjusted to the capture clock. Every result must be
/// harvested — the legacy code kept only the first, silently dropping all
/// transcribed text after the first window.
struct AlignmentTranscriptTests {

    // MARK: - Fixtures

    private func word(_ text: String, _ start: Float, probability: Float = 1.0) -> WordTiming {
        WordTiming(word: text, tokens: [], start: start, end: start + 0.3, probability: probability)
    }

    private func segment(start: Float, end: Float, text: String, words: [WordTiming]?) -> WKTranscriptionSegment {
        WKTranscriptionSegment(
            id: 0, seek: 0, start: start, end: end, text: text,
            tokens: [], tokenLogProbs: [], temperature: 0, avgLogprob: 0,
            compressionRatio: 1, noSpeechProb: 0, words: words
        )
    }

    private func result(_ segments: [WKTranscriptionSegment]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.text).joined(),
            segments: segments,
            language: "en",
            timings: TranscriptionTimings()
        )
    }

    // MARK: - Tests

    @Test func collectsWordsAcrossAllVADWindowResults() {
        let first = result([segment(start: 1.0, end: 4.0, text: " Chapter Two", words: [
            word(" Chapter", 1.2), word(" Two", 1.9),
        ])])
        let second = result([segment(start: 30.0, end: 33.0, text: " Accepting Yourself", words: [
            word(" Accepting", 30.5), word(" Yourself", 31.0),
        ])])

        let words = AlignmentTranscript.words(from: [[first, second]], captureStart: 2110.0)

        #expect(words.map(\.text) == ["Chapter", "Two", "Accepting", "Yourself"])
        let expectedStarts: [TimeInterval] = [2111.2, 2111.9, 2140.5, 2141.0]
        #expect(words.count == expectedStarts.count)
        for (word, expected) in zip(words, expectedStarts) {
            #expect(abs(word.start - expected) < 0.01)
        }
    }

    @Test func ordersWordsByStartTimeAcrossResults() {
        let later = result([segment(start: 30.0, end: 33.0, text: " beta", words: [word(" beta", 30.5)])])
        let earlier = result([segment(start: 1.0, end: 4.0, text: " alpha", words: [word(" alpha", 1.2)])])

        let words = AlignmentTranscript.words(from: [[later, earlier]], captureStart: 0)

        #expect(words.map(\.text) == ["alpha", "beta"])
    }

    @Test func carriesWordTimingConfidence() {
        let r = result([segment(start: 0.0, end: 1.0, text: " alpha", words: [
            word(" alpha", 0.1, probability: 0.42),
        ])])

        let words = AlignmentTranscript.words(from: [[r]], captureStart: 0)

        #expect(abs((words.first?.confidence ?? 0) - 0.42) < 0.001)
    }

    @Test func spreadsSegmentTextWhenWordTimingsAreMissing() {
        let r = result([segment(start: 10.0, end: 20.0, text: " alpha beta gamma delta", words: nil)])

        let words = AlignmentTranscript.words(from: [[r]], captureStart: 0)

        #expect(words.map(\.text) == ["alpha", "beta", "gamma", "delta"])
        let expectedStarts: [TimeInterval] = [10.0, 12.5, 15.0, 17.5]
        #expect(words.count == expectedStarts.count)
        for (word, expected) in zip(words, expectedStarts) {
            #expect(abs(word.start - expected) < 0.01)
        }
    }

    @Test func skipsWhisperSpecialTokens() {
        let r = result([segment(start: 0.0, end: 4.0, text: " alpha <|endoftext|>", words: [
            word(" alpha", 0.5), word(" <|endoftext|>", 3.9),
        ])])

        let words = AlignmentTranscript.words(from: [[r]], captureStart: 0)

        #expect(words.map(\.text) == ["alpha"])
    }

    @Test func skipsSpecialTokensInSegmentTextFallback() {
        let r = result([segment(start: 0.0, end: 6.0, text: " alpha <|nospeech|> beta", words: nil)])

        let words = AlignmentTranscript.words(from: [[r]], captureStart: 0)

        #expect(words.map(\.text) == ["alpha", "beta"])
    }

    @Test func ignoresNilResultArrays() {
        let r = result([segment(start: 1.0, end: 2.0, text: " alpha", words: [word(" alpha", 1.0)])])

        let words = AlignmentTranscript.words(from: [nil, [r]], captureStart: 5.0)

        #expect(words.map(\.text) == ["alpha"])
        #expect(abs((words.first?.start ?? 0) - 6.0) < 0.01)
    }

    // MARK: - projectBlockStart

    @Test func projectsBlockStartBackwardsUsingObservedWordRate() {
        // 11 words at 0.4 s/word starting at 100.0; the matched window
        // begins 5 tokens into the block → block start ≈ 100 − 5×0.4 = 98.
        let words = (0..<11).map { TranscribedWord(text: "w\($0)", start: 100.0 + Double($0) * 0.4) }

        let projected = AlignmentTranscript.projectBlockStart(words: words, matchedBlockWindowStart: 5)

        #expect(abs((projected ?? -1) - 98.0) < 0.01)
    }

    @Test func projectionAtBlockStartReturnsFirstWordTime() {
        let words = [TranscribedWord(text: "a", start: 7.0), TranscribedWord(text: "b", start: 7.4)]
        #expect(AlignmentTranscript.projectBlockStart(words: words, matchedBlockWindowStart: 0) == 7.0)
    }

    @Test func projectionWithNoWordsReturnsNil() {
        #expect(AlignmentTranscript.projectBlockStart(words: [], matchedBlockWindowStart: 3) == nil)
    }
}
