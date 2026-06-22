// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct HeadlessNarrationRunnerTests {
    /// Stub TTS: returns 0.2s of quiet-but-nonzero PCM per call (no 163 MB model).
    private final class StubEngine: TTSEngine {
        func prepare() async throws {}
        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws
        { progress(.ready) }
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            TTSChunk(
                samples: [Float](repeating: 0.1, count: 4800), sampleRate: 24_000, duration: 0.2)
        }
    }

    @Test func producesM4BAndSidecarAndResumes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)  // see Step 3 helper
        let out = tmp.appendingPathComponent("book.m4b")
        let sidecar = tmp.appendingPathComponent("book.alignment.json")
        let cfg = NarrationRunConfig(
            epubURL: epub, outM4BURL: out, sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("work"), voice: VoiceID("af_heart"),
            title: "Fixture", author: "Tester", maxNewChaptersPerRun: nil)

        let result = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(result.complete)
        #expect(result.chapters == 2)
        #expect(FileManager.default.fileExists(atPath: out.path))

        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecar))
        #expect(!anchors.isEmpty)
        #expect(anchors.allSatisfy { $0.blockId.contains("-b") })  // portable s<i>-b<j>

        // Resume: a second run captures nothing new and is still complete.
        let again = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(again.capturedThisRun == 0)
        #expect(again.complete)
    }
}
