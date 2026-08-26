// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct NarrationWordTimingAssemblerTests {
    @Test func concatenatesRebasingIndexAndOffsettingTime() throws {
        let chunkA = [
            ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.3),
            ChunkWordTiming(wordIndex: 1, start: 0.3, end: 0.6),
        ]
        let chunkB = [ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.4)]
        let out = try #require(
            NarrationWordTimingAssembler.assemble([
                (chunkA, 0.0),
                (chunkB, 0.6),  // second chunk starts 0.6 s into the file
            ]))
        #expect(out.map(\.wordIndex) == [0, 1, 2])
        #expect(abs(out[2].start - 0.6) < 1e-9 && abs(out[2].end - 1.0) < 1e-9)
    }

    @Test func returnsNilIfAnyChunkMissing() {
        let chunkA = [ChunkWordTiming(wordIndex: 0, start: 0.0, end: 0.3)]
        #expect(
            NarrationWordTimingAssembler.assemble([(chunkA, 0.0), (nil, 0.3)]) == nil)
    }

    @Test func returnsNilWhenEmpty() {
        #expect(NarrationWordTimingAssembler.assemble([]) == nil)
    }
}
