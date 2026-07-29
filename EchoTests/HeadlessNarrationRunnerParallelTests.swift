// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Covers `NarrationRunConfig.jobs > 1`: parallel chapter workers must produce
/// exactly the artifacts the serial runner produces — every chapter captured,
/// one m4b, and a sidecar whose anchors are ordered and complete — while
/// claiming each chapter exactly once across workers.
@MainActor
@Suite struct HeadlessNarrationRunnerParallelTests {
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

    private actor VoiceRecorder {
        private(set) var voices: Set<VoiceID> = []

        func record(_ voice: VoiceID) {
            voices.insert(voice)
        }
    }

    private actor PackLoadCounter {
        private(set) var count = 0

        func load() -> EnglishPronunciationPack {
            count += 1
            return .emptyForTesting(
                packVersion:
                    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                kokoroVocabularyVersion:
                    "sha256:1111111111111111111111111111111111111111111111111111111111111111")
        }
    }

    private final class VoiceRecordingEngine: TTSEngine {
        let recorder: VoiceRecorder

        init(recorder: VoiceRecorder) {
            self.recorder = recorder
        }

        func prepare() async throws {}

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            await recorder.record(voice)
            return TTSChunk(
                samples: [Float](repeating: 0.1, count: 4_800),
                sampleRate: 24_000,
                duration: 0.2)
        }
    }

    private func makeConfig(
        epub: URL, tmp: URL, stem: String, jobs: Int, maxChapters: Int? = nil
    ) -> NarrationRunConfig {
        NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("\(stem).m4b"),
            sidecarURL: tmp.appendingPathComponent("\(stem).alignment.json"),
            workDir: tmp.appendingPathComponent("\(stem)-work"),
            voice: VoiceID("af_heart"),
            title: "Fixture", author: "Tester",
            maxNewChaptersPerRun: maxChapters,
            jobs: jobs)
    }

    @Test func parallelJobsCaptureAllChaptersAndExport() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.chapters(5, in: tmp)
        let cfg = makeConfig(epub: epub, tmp: tmp, stem: "parallel", jobs: 3)

        var enginesBuilt = 0
        let result = try await HeadlessNarrationRunner().run(
            cfg,
            ttsFactory: {
                enginesBuilt += 1
                return StubEngine()
            })

        #expect(result.complete)
        #expect(result.chapters == 5)
        #expect(result.capturedThisRun == 5)
        // One engine per worker: three workers for five chapters.
        #expect(enginesBuilt == 3)
        #expect(FileManager.default.fileExists(atPath: cfg.outM4BURL.path))

        // Every chapter has a capture marker (claimed exactly once — a double
        // render would still leave one marker, so also assert the sidecar).
        let markers =
            ((try? FileManager.default.contentsOfDirectory(
                at: cfg.workDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".anchors-ch") }
        #expect(markers.count == 5)

        let anchors = try AlignmentSidecar.decode(Data(contentsOf: cfg.sidecarURL!))
        #expect(!anchors.isEmpty)
        #expect(anchors.allSatisfy { $0.blockId.contains("-b") })
        // Sidecar assembly walks chapters in order, so timestamps must be
        // non-decreasing regardless of parallel completion order.
        let times = anchors.map(\.timestamp)
        #expect(times == times.sorted())
    }

    @Test func parallelMatchesSerialSidecar() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.chapters(4, in: tmp)
        let serialCfg = makeConfig(epub: epub, tmp: tmp, stem: "serial", jobs: 1)
        let parallelCfg = makeConfig(epub: epub, tmp: tmp, stem: "fanout", jobs: 4)

        _ = try await HeadlessNarrationRunner().run(serialCfg, ttsFactory: { StubEngine() })
        _ = try await HeadlessNarrationRunner().run(parallelCfg, ttsFactory: { StubEngine() })

        let serial = try AlignmentSidecar.decode(Data(contentsOf: serialCfg.sidecarURL!))
        let parallel = try AlignmentSidecar.decode(Data(contentsOf: parallelCfg.sidecarURL!))
        // The stub's fixed chunk duration makes render output deterministic, so
        // parallel and serial runs must agree anchor-for-anchor.
        #expect(serial.map(\.blockId) == parallel.map(\.blockId))
        #expect(serial.map(\.timestamp) == parallel.map(\.timestamp))
    }

    @Test func parallelRespectsMaxChaptersAndResumes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.chapters(5, in: tmp)
        let cfg = makeConfig(epub: epub, tmp: tmp, stem: "batched", jobs: 3, maxChapters: 2)

        let first = try await HeadlessNarrationRunner().run(cfg, ttsFactory: { StubEngine() })
        #expect(first.complete == false)
        #expect(first.capturedThisRun == 2)

        let second = try await HeadlessNarrationRunner().run(cfg, ttsFactory: { StubEngine() })
        #expect(second.complete == false)
        #expect(second.capturedThisRun == 2)

        let third = try await HeadlessNarrationRunner().run(cfg, ttsFactory: { StubEngine() })
        #expect(third.complete)
        #expect(third.capturedThisRun == 1)
        #expect(FileManager.default.fileExists(atPath: cfg.outM4BURL.path))
    }

    @Test func singleSharedEngineStillWorksWithJobs() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.chapters(3, in: tmp)
        let cfg = makeConfig(epub: epub, tmp: tmp, stem: "shared", jobs: 2)

        // Passing a single `tts:` engine with jobs > 1 shares it across workers.
        let result = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(result.complete)
        #expect(result.chapters == 3)
    }

    @Test func prepareFractionCollapsesStepsMonotonically() {
        #expect(
            HeadlessNarrationRunner.prepareFraction(.downloadingModels(fraction: 0)) == 0)
        #expect(
            HeadlessNarrationRunner.prepareFraction(.downloadingModels(fraction: 0.5)) == 0.45)
        #expect(
            HeadlessNarrationRunner.prepareFraction(.downloadingModels(fraction: 1)) == 0.9)
        #expect(
            HeadlessNarrationRunner.prepareFraction(.compilingModels(done: 0, total: 1)) == 0.9)
        #expect(
            HeadlessNarrationRunner.prepareFraction(.compilingModels(done: 1, total: 1)) == 1.0)
        #expect(HeadlessNarrationRunner.prepareFraction(.ready) == 1.0)
    }

    @Test func parallelWorkersPreserveMixedChapterVoices() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.chapters(4, in: tmp)
        var config = makeConfig(epub: epub, tmp: tmp, stem: "mixed", jobs: 3)
        config.chapterVoicesByDisplayNumber = [
            1: VoiceID("af_heart"),
            2: VoiceID("am_michael"),
            3: VoiceID("bf_emma"),
            4: VoiceID("bm_fable"),
        ]
        config.generatePronunciationReview = false
        let recorder = VoiceRecorder()

        let result = try await HeadlessNarrationRunner().run(
            config,
            ttsFactory: { VoiceRecordingEngine(recorder: recorder) })

        #expect(result.complete)
        #expect(
            await recorder.voices
                == Set([
                    VoiceID("af_heart"),
                    VoiceID("am_michael"),
                    VoiceID("bf_emma"),
                    VoiceID("bm_fable"),
                ]))
    }

    @Test func parallelRunSnapshotsPronunciationPackExactlyOnce() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.chapters(4, in: tmp)
        let config = makeConfig(epub: epub, tmp: tmp, stem: "pack-snapshot", jobs: 3)
        let counter = PackLoadCounter()

        let result = try await HeadlessNarrationRunner().run(
            config,
            ttsFactory: { StubEngine() },
            pronunciationPackLoader: { await counter.load() })

        #expect(result.complete)
        #expect(await counter.count == 1)
    }
}
