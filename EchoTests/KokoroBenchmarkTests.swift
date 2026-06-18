// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

struct KokoroBenchmarkTests {

    // Disabled: this is a real-synthesis integration benchmark that downloads
    // + compiles the CoreML model set and runs Kokoro end-to-end. It belongs in
    // the Phase 5 owner-driven hardware verification (real device + listening),
    // not the sim unit suite — it can't load the MIL network on the simulator
    // and would need network + a multi-second compile per run. Re-enable on
    // device as part of Phase 5.1 (macOS full-book) / 5.2 (A14 iPhone).
    @Test(.disabled("Real-synthesis benchmark — run on device in Phase 5 verification"))
    func testKokoroRTFBenchmark() async throws {
        let engine = KokoroTTSEngine()

        let sampleText = """
        The Kokoro-82M model is highly optimized for Apple Neural Engine.
        It provides high-quality speech synthesis while using a small amount of memory,
        making it perfect for offline, on-device audiobooks.
        """

        // This will download the model to cache on first run (takes network time)
        // and compile for ANE (takes ~15s on first run).
        try await engine.prepare()

        // Run synthesis
        let chunk = try await engine.synthesize(sampleText, voice: VoiceCatalog.default.id)

        // Check that duration makes sense and samples actually generated
        #expect(chunk.duration > 0)
        #expect(chunk.samples.count > 0)

        // This test simulates the benchmark. In a real physical device run,
        // we would see the RTF output in the console.
    }
}
