// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Pins the pure ONNX intra-op thread policy: divide performance cores across
/// parallel jobs, clamped to the measured floor (2, the A14 baseline) and a
/// saturation ceiling (4) — Kokoro-82M stops scaling past ~4 threads.
@Suite struct NarrationEngineFactoryTests {

    @Test func singleJobUsesUpToFourPerformanceCores() {
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 8, jobs: 1) == 4)
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 4, jobs: 1) == 4)
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 3, jobs: 1) == 3)
    }

    @Test func parallelJobsSplitTheCores() {
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 8, jobs: 2) == 4)
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 8, jobs: 4) == 2)
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 4, jobs: 4) == 2)
    }

    @Test func neverDropsBelowMeasuredFloor() {
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 2, jobs: 8) == 2)
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 1, jobs: 1) == 2)
        #expect(NarrationEngineFactory.resolvedIntraOpThreads(performanceCores: 0, jobs: 0) == 2)
    }

    @Test func iOSDefaultKeepsA14Tuning() {
        #if os(iOS)
            #expect(NarrationEngineFactory.defaultIntraOpThreads(jobs: 1) == 2)
            #expect(NarrationEngineFactory.defaultIntraOpThreads(jobs: 4) == 2)
        #endif
    }
}
