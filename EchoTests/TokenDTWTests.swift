// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

/// Tests for `TokenDTW` tokenization and candidate-producing alignment.
///
/// The audio token streams below carry *real* per-word timestamps (what
/// WhisperKit's `wordTimestamps` provides), including natural narration
/// pauses. Anchors must land on those true times — the legacy pipeline
/// spread token times linearly across a capture, which stretched chapter
/// headings across multi-second pauses ("18 seconds to say 'Chapter 2'").
struct TokenDTWTests {

    // MARK: - Helpers

    private func epubTokens(_ blocks: [(id: String, text: String)]) -> [TokenDTW.EPubToken] {
        blocks.flatMap { block in
            TokenDTW.normalize(block.text).map { TokenDTW.EPubToken(text: $0, blockID: block.id) }
        }
    }

    private func audioTokens(_ words: [(String, TimeInterval)]) -> [TokenDTW.AudioToken] {
        words.map { TokenDTW.AudioToken(text: $0.0, time: $0.1) }
    }

    private func candidate(_ id: String, in candidates: [TokenDTW.AnchorCandidate]) -> TokenDTW.AnchorCandidate? {
        candidates.first { $0.blockID == id }
    }

    /// Chapter-start corpus modeled on the screenshot bug: number heading,
    /// pause, title heading, pause, first paragraph.
    private let chapterStartBlocks: [(id: String, text: String)] = [
        ("b-head", "Chapter 2"),
        ("b-sub", "Accepting Yourself and Your Partner"),
        ("b-para", "Couple interaction has often been compared to a dance: when the music flows, the timing is right."),
    ]

    private let chapterStartAudio: [(String, TimeInterval)] = [
        ("chapter", 2111.5), ("two", 2112.1),
        ("accepting", 2116.0), ("yourself", 2116.5), ("and", 2116.9),
        ("your", 2117.1), ("partner", 2117.4),
        ("couple", 2121.0), ("interaction", 2121.6), ("has", 2122.0),
        ("often", 2122.3), ("been", 2122.7), ("compared", 2123.1),
        ("to", 2123.4), ("dance", 2123.8), ("when", 2124.1),
        ("the", 2124.3), ("music", 2124.6), ("flows", 2124.9),
        ("the", 2125.2), ("timing", 2125.5), ("is", 2125.7), ("right", 2126.0),
    ]

    // MARK: - normalize

    @Test func normalizeExpandsSingleDigitNumbersToSpokenWords() {
        #expect(TokenDTW.normalize("Chapter 2") == ["chapter", "two"])
    }

    @Test func normalizeExpandsTwoDigitNumbersToSpokenWords() {
        #expect(TokenDTW.normalize("Chapter 12") == ["chapter", "twelve"])
        #expect(TokenDTW.normalize("Chapter 21:") == ["chapter", "twenty", "one"])
        #expect(TokenDTW.normalize("Chapter 40") == ["chapter", "forty"])
    }

    @Test func normalizeExpandsLongNumbersPerDigit() {
        #expect(TokenDTW.normalize("Copyright 1995") == ["copyright", "one", "nine", "nine", "five"])
    }

    @Test func normalizeKeepsLetterTokenRulesUnchanged() {
        #expect(TokenDTW.normalize("It's a well-known fact, I think") == ["it", "well", "known", "fact", "think"])
    }

    // MARK: - alignCandidates

    @Test func anchorsChapterStartBlocksAtRealWordTimes() throws {
        let candidates = TokenDTW.alignCandidates(
            epub: epubTokens(chapterStartBlocks),
            audio: audioTokens(chapterStartAudio)
        )

        let head = try #require(candidate("b-head", in: candidates))
        let sub = try #require(candidate("b-sub", in: candidates))
        let para = try #require(candidate("b-para", in: candidates))

        #expect(abs(head.time - 2111.5) < 0.3)
        #expect(abs(sub.time - 2116.0) < 0.3)
        #expect(abs(para.time - 2121.0) < 0.3)

        // The regression that motivated this rewrite: the gap between the
        // heading anchor and the subtitle anchor must be the real narration
        // gap (~4.5 s), not a stretched fabrication (~18 s).
        #expect(sub.time - head.time < 6.0)
    }

    @Test func producesNoCandidateForTextAbsentFromAudio() throws {
        let blocks = [("b-copy", "Copyright 1995 Penguin Random House")] + chapterStartBlocks
        let candidates = TokenDTW.alignCandidates(
            epub: epubTokens(blocks),
            audio: audioTokens(chapterStartAudio)
        )

        #expect(candidate("b-copy", in: candidates) == nil)
        #expect(candidate("b-head", in: candidates) != nil)
    }

    @Test func toleratesAMistranscribedWordMidParagraph() throws {
        var noisyAudio = chapterStartAudio
        let oftenIndex = noisyAudio.firstIndex { $0.0 == "often" }!
        noisyAudio[oftenIndex] = ("orphan", noisyAudio[oftenIndex].1)

        let candidates = TokenDTW.alignCandidates(
            epub: epubTokens(chapterStartBlocks),
            audio: audioTokens(noisyAudio)
        )

        let para = try #require(candidate("b-para", in: candidates))
        #expect(abs(para.time - 2121.0) < 0.3)
    }

    @Test func backProjectsBlockStartWhenOpeningWordsWereMissed() throws {
        let blocks = [("b-x", "The quick brown fox jumps over the lazy dog")]
        // First two words never transcribed; speech rate 0.4 s/token.
        let audio: [(String, TimeInterval)] = [
            ("brown", 10.0), ("fox", 10.4), ("jumps", 10.8), ("over", 11.2),
            ("the", 11.6), ("lazy", 12.0), ("dog", 12.4),
        ]

        let candidates = TokenDTW.alignCandidates(
            epub: epubTokens(blocks),
            audio: audioTokens(audio)
        )

        let x = try #require(candidate("b-x", in: candidates))
        #expect(x.firstMatchTokenIndex == 2)
        // 10.0 − 2 tokens × 0.4 s/token = 9.2
        #expect(abs(x.time - 9.2) < 0.3)
    }

    @Test func runsSpanBlockBoundariesSoShortHeadingsGainConfidence() throws {
        let candidates = TokenDTW.alignCandidates(
            epub: epubTokens(chapterStartBlocks),
            audio: audioTokens(chapterStartAudio)
        )

        let head = try #require(candidate("b-head", in: candidates))
        // Two-token heading sits inside the contiguous run covering the
        // subtitle and paragraph too.
        #expect(head.exactRunLength >= 3)
    }

    // MARK: - alignWithBisection

    @Test func bisectionMatchesDirectAlignment() throws {
        let blocks: [(id: String, text: String)] = [
            ("b-a", "alpha bravo charlie delta echo foxtrot"),
            ("b-b", "golf hotel india juliet kilo lima"),
            ("b-c", "mike november oscar papa quebec romeo"),
            ("b-d", "sierra tango uniform victor whiskey xray"),
        ]
        var words: [(String, TimeInterval)] = []
        let lists = [
            ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"],
            ["golf", "hotel", "india", "juliet", "kilo", "lima"],
            ["mike", "november", "oscar", "papa", "quebec", "romeo"],
            ["sierra", "tango", "uniform", "victor", "whiskey", "xray"],
        ]
        // Blocks A+B speak at 0.0–4.4 s, then an 8 s pause, then C+D.
        var time: TimeInterval = 0
        for (listIndex, list) in lists.enumerated() {
            if listIndex == 2 { time += 8.0 }
            for word in list {
                words.append((word, time))
                time += 0.4
            }
        }

        let epub = epubTokens(blocks)
        let audio = audioTokens(words)

        let direct = TokenDTW.alignCandidates(epub: epub, audio: audio)
        let bisected = TokenDTW.alignWithBisection(
            epub: epub, audio: audio, maxCells: 200, slackBlocks: 1
        )

        #expect(direct.count == 4)
        #expect(Set(bisected.map(\.blockID)) == Set(direct.map(\.blockID)))
        for cand in direct {
            let twin = try #require(candidate(cand.blockID, in: bisected))
            #expect(abs(twin.time - cand.time) < 0.05)
        }
    }
}
