// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    struct OnnxKokoroEngineLifecycleTests {
        /// unload() releases the sessions; a later prepare() re-creates them.
        /// Uses the small bundled duration-head onnx as the "model" via the
        /// modelProvider seam so no 163 MB download is involved.
        @Test func unloadReleasesAndPrepareRestores() async throws {
            let headURL = try #require(
                NarrationResources.url(forResource: "kokoro_dur_head", withExtension: "onnx"))
            let engine = OnnxKokoroEngine(
                modelProvider: { _ in headURL }, intraOpThreads: 1)

            try await engine.prepare()
            #expect(await engine.isPreparedForTesting)

            await engine.unload()
            #expect(await engine.isPreparedForTesting == false)

            try await engine.prepare()
            #expect(await engine.isPreparedForTesting)
        }
    }
#endif
