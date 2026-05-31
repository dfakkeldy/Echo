import Foundation
import Testing
@testable import Echo_Audiobooks

struct AutoAlignmentTextMatcherTests {

    @Test func shortTranscriptMatchesWindowInsideLongParagraph() throws {
        let audiobookID = "book-1"
        let matchingParagraph = """
        It was the best of times and it was the worst of times, with a hundred small details \
        around the sentence that actually matters. The brass clock above the station door \
        struck midnight and the platform emptied into the rain. Afterward, the narrator \
        wanders through several more sentences that are not part of the captured audio.
        """
        let candidates = [
            EPubBlockRecord(id: "wrong", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                            blockKind: "paragraph",
                            text: "The meadow was quiet and the morning train had not yet arrived.",
                            chapterIndex: 0, isHidden: false),
            EPubBlockRecord(id: "right", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                            spineIndex: 0, blockIndex: 1, sequenceIndex: 1,
                            blockKind: "paragraph", text: matchingParagraph,
                            chapterIndex: 0, isHidden: false),
        ]

        let result = try #require(AutoAlignmentTextMatcher.findBestMatch(
            transcribedText: "the brass clock above the station door struck midnight",
            candidates: candidates,
            matchThreshold: 0.55
        ))

        #expect(result.block.id == "right")
    }

    @Test func bestWindowStartReportsBlockTokenPositionOfBestMatchingWindow() throws {
        // Tokens: ["alpha","beta","gamma","delta","epsilon","zeta","eta","theta","iota","kappa"]
        // Transcript ("epsilon zeta eta theta") perfectly aligns at token index 4.
        let candidates = [
            EPubBlockRecord(id: "b", audiobookID: "book", spineHref: "ch.xhtml",
                            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                            blockKind: "paragraph",
                            text: "alpha beta gamma delta epsilon zeta eta theta iota kappa",
                            chapterIndex: 0, isHidden: false),
        ]

        let result = try #require(AutoAlignmentTextMatcher.findBestMatch(
            transcribedText: "epsilon zeta eta theta",
            candidates: candidates,
            matchThreshold: 0
        ))

        #expect(result.bestWindowStart == 4)
    }

    @Test func bestWindowStartIsZeroWhenTranscriptMatchesBlockStart() throws {
        let candidates = [
            EPubBlockRecord(id: "b", audiobookID: "book", spineHref: "ch.xhtml",
                            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                            blockKind: "paragraph",
                            text: "alpha beta gamma delta epsilon zeta eta theta",
                            chapterIndex: 0, isHidden: false),
        ]

        let result = try #require(AutoAlignmentTextMatcher.findBestMatch(
            transcribedText: "alpha beta gamma delta",
            candidates: candidates,
            matchThreshold: 0
        ))

        #expect(result.bestWindowStart == 0)
    }

    @Test func projectedBlockStartReturnsCaptureStartWhenMatchedWindowIsAtBlockStart() {
        // When the matched window begins at block token 0, the capture's first
        // word IS the block's first word — no back-projection needed.
        let projected = AutoAlignmentTextMatcher.projectedBlockStart(
            windowStart: 100,
            firstWordOffset: 0.5,
            captureDuration: 5,
            transcriptTokenCount: 10,
            matchedBlockWindowStart: 0
        )
        #expect(abs(projected - 100.5) < 0.001)
    }

    @Test func projectedBlockStartBacksUpProportionallyWhenWindowStartsMidBlock() {
        // 10 tokens spoken in 5s of capture → 0.5s per token. If the matched
        // window begins at block token 4, the block's first word was 4 × 0.5
        // = 2s before the capture's first detected word.
        let projected = AutoAlignmentTextMatcher.projectedBlockStart(
            windowStart: 100,
            firstWordOffset: 0.5,
            captureDuration: 5,
            transcriptTokenCount: 10,
            matchedBlockWindowStart: 4
        )
        // 100 + 0.5 − (4 × 0.5) = 98.5
        #expect(abs(projected - 98.5) < 0.001)
    }

    @Test func projectedBlockStartFallsBackWhenTokenCountTooSmallToEstimateRate() {
        // Two-token transcripts give an unreliable seconds-per-token estimate;
        // refuse to back-project and return the capture start instead.
        let projected = AutoAlignmentTextMatcher.projectedBlockStart(
            windowStart: 100,
            firstWordOffset: 0.5,
            captureDuration: 5,
            transcriptTokenCount: 2,
            matchedBlockWindowStart: 10
        )
        #expect(abs(projected - 100.5) < 0.001)
    }

    @Test func reportsTranscriptTokenCount() throws {
        let candidates = [
            EPubBlockRecord(id: "b", audiobookID: "book", spineHref: "ch.xhtml",
                            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                            blockKind: "paragraph",
                            text: "the quick brown fox jumps over the lazy dog",
                            chapterIndex: 0, isHidden: false),
        ]

        let result = try #require(AutoAlignmentTextMatcher.findBestMatch(
            transcribedText: "quick brown fox jumps",
            candidates: candidates,
            matchThreshold: 0
        ))

        // Tokens after lowercasing + length>=2 filter: ["quick","brown","fox","jumps"]
        #expect(result.transcriptTokenCount == 4)
    }
}
