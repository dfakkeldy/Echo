// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct AlignmentChunkPlannerTests {

    private func gap(_ start: TimeInterval, _ end: TimeInterval)
        -> SilenceDetectionService.SilenceGaps
    {
        SilenceDetectionService.SilenceGaps(start: start, end: end)
    }

    @Test func hardCapsChunksWhenNoSilenceExists() {
        let chunks = AlignmentChunkPlanner.plan(chapterStart: 0, chapterEnd: 100, silences: [])
        #expect(
            chunks == [
                AlignmentChunkPlanner.Chunk(start: 0, end: 45),
                AlignmentChunkPlanner.Chunk(start: 45, end: 90),
                AlignmentChunkPlanner.Chunk(start: 90, end: 100),
            ])
    }

    @Test func cutsAtSilenceMidpointsWhenReachable() {
        let chunks = AlignmentChunkPlanner.plan(
            chapterStart: 0, chapterEnd: 90,
            silences: [gap(20, 24), gap(57, 61)]
        )
        #expect(
            chunks == [
                AlignmentChunkPlanner.Chunk(start: 0, end: 22),
                AlignmentChunkPlanner.Chunk(start: 22, end: 59),
                AlignmentChunkPlanner.Chunk(start: 59, end: 90),
            ])
    }

    @Test func prefersTheLatestReachableSilence() {
        let chunks = AlignmentChunkPlanner.plan(
            chapterStart: 0, chapterEnd: 60,
            silences: [gap(18, 22), gap(30, 34)]
        )
        #expect(
            chunks == [
                AlignmentChunkPlanner.Chunk(start: 0, end: 32),
                AlignmentChunkPlanner.Chunk(start: 32, end: 60),
            ])
    }

    @Test func mergesTinyTrailingRemainderIntoPreviousChunk() {
        let chunks = AlignmentChunkPlanner.plan(chapterStart: 0, chapterEnd: 47, silences: [])
        #expect(chunks == [AlignmentChunkPlanner.Chunk(start: 0, end: 47)])
    }

    @Test func shortChapterIsASingleChunk() {
        let chunks = AlignmentChunkPlanner.plan(chapterStart: 0, chapterEnd: 12, silences: [])
        #expect(chunks == [AlignmentChunkPlanner.Chunk(start: 0, end: 12)])
    }

    @Test func chunksAreContiguousAndCoverTheChapter() {
        let chunks = AlignmentChunkPlanner.plan(
            chapterStart: 2111, chapterEnd: 2400,
            silences: [gap(2140, 2143), gap(2200, 2204), gap(2300, 2303)]
        )
        #expect(chunks.first?.start == 2111)
        #expect(chunks.last?.end == 2400)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.end == b.start)
        }
        for chunk in chunks {
            #expect(chunk.duration <= 50.0)  // maxChunk plus merged-tail slack
            #expect(chunk.duration > 0)
        }
    }

    // MARK: - Inverted-config guard (§5.12)

    @Test func invertedChunkConfigFallsBackToSingleChunk() {
        let chunks = AlignmentChunkPlanner.plan(
            chapterStart: 0, chapterEnd: 100, silences: [],
            minChunk: 45, maxChunk: 15  // inverted: would emit negative-length chunks
        )
        #expect(chunks == [AlignmentChunkPlanner.Chunk(start: 0, end: 100)])
        for chunk in chunks { #expect(chunk.duration > 0) }
    }

    @Test func zeroMinChunkFallsBackToSingleChunk() {
        let chunks = AlignmentChunkPlanner.plan(
            chapterStart: 10, chapterEnd: 200, silences: [],
            minChunk: 0, maxChunk: 45
        )
        #expect(chunks == [AlignmentChunkPlanner.Chunk(start: 10, end: 200)])
        for chunk in chunks { #expect(chunk.duration > 0) }
    }
}
