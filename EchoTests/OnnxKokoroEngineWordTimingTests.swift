// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Real dual-session synthesis is heavy (downloads the 163 MB waveform model).
    /// Gated behind ECHO_RUN_KOKORO_TIMING_IT so the default suite stays fast; run
    /// on device/sim with the env var set, or rely on manual smoke verification.
    struct OnnxKokoroEngineWordTimingTests {
        @Test(
            .enabled(
                if: ProcessInfo.processInfo.environment["ECHO_RUN_KOKORO_TIMING_IT"] == "1",
                "set ECHO_RUN_KOKORO_TIMING_IT=1 to run the heavy Kokoro timing IT"))
        func synthesizeEmitsMonotonicWordTimings() async throws {
            let engine = OnnxKokoroEngine()
            try await engine.prepare()
            let chunk = try await engine.synthesize(
                "Hello there world.", voice: VoiceID("af_heart"))
            let timings = try #require(chunk.wordTimings, "expected synthesis word timings")
            #expect(timings.count == 3)
            for i in 1..<timings.count {
                #expect(timings[i].start >= timings[i - 1].end - 1e-3)
            }
            #expect(timings.last!.end <= chunk.duration + 1e-3)
        }
    }
#endif
