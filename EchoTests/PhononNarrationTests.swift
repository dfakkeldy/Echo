// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import Echo

@Suite struct PhononNarrationTests {
    @Test func kokoroRemainsDefaultAndPhononIDsHaveIndependentIdentity() {
        #expect(VoiceCatalog.default.id == VoiceID("af_heart"))
        #expect(VoiceCatalog.kokoro.count == 28)
        #expect(VoiceCatalog.phononName(for: VoiceID("ph31m_v040_preston")) == "Preston")
        #expect(VoiceCatalog.phononName(for: VoiceID("af_heart")) == nil)
        let kokoro = VoiceCatalog.rendererIdentity(for: [VoiceID("af_heart")])
        let phonon = VoiceCatalog.rendererIdentity(for: [VoiceID("ph31m_v040_preston")])
        #expect(kokoro == NarrationFileNaming.rendererIdentity)
        #expect(phonon != kokoro)
        #expect(phonon.contains("phonon-31m-en.coreml.0.4.0"))
        #expect(VoiceCatalog.phonon.allSatisfy(\.isPhonon))
    }

    @Test func preparingPhononNeverPreparesKokoro() async throws {
        let kokoro = RecordingEngine()
        let phonon = RecordingEngine()
        let router = NarrationEngineRouter(makeKokoro: { kokoro }, makePhonon: { phonon })
        let voice = VoiceID("ph31m_v040_preston")
        try await router.prepare(voice: voice, progress: { _ in })
        _ = try await router.synthesize("A Phonon sentence.", voice: voice)
        _ = try await router.synthesize("A Kokoro sentence.", voice: VoiceID("af_heart"))
        #expect(await kokoro.preparations == 0)
        #expect(await phonon.preparations == 1)
        #expect(await phonon.voices == [voice])
        #expect(await kokoro.voices == [VoiceID("af_heart")])
    }

    @Test func modelBundleRejectsChangedBytesAndManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("model.bin")
        let data = Data("complete model".utf8)
        try data.write(to: model)
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "files": [["path": "model.bin", "size": data.count, "sha256": Self.hash(data)]]
            ], options: [.sortedKeys])
        try manifest.write(to: directory.appendingPathComponent("bundle.json"))
        let manifestHash = Self.hash(manifest)
        try PhononModelStore.validateBundle(at: directory, expectedManifestSHA256: manifestHash)
        try Data("tampered model".utf8).write(to: model)
        #expect(throws: (any Error).self) {
            try PhononModelStore.validateBundle(at: directory, expectedManifestSHA256: manifestHash)
        }
        try data.write(to: model)
        #expect(throws: (any Error).self) {
            try PhononModelStore.validateBundle(at: directory, expectedManifestSHA256: "untrusted")
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private actor RecordingEngine: TTSEngine {
        var preparations = 0
        var voices: [VoiceID] = []
        func prepare() async throws { preparations += 1 }
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            voices.append(voice)
            return .init(samples: [0.1], sampleRate: 24_000, duration: 1.0 / 24_000)
        }
    }
}

#if canImport(PhononTTS)
    @Suite struct PhononNativeProofTests {
        @Test func realModelProducesAudioWithoutInventingWordTimings() async throws {
            let env = ProcessInfo.processInfo.environment
            guard
                let path = env["ECHO_PHONON_PROOF_OUTPUT"]
                    ?? env["TEST_RUNNER_ECHO_PHONON_PROOF_OUTPUT"]
            else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let engine = PhononTTSEngine()
            let voice = VoiceID("ph31m_v040_preston")
            try await engine.prepare()
            let text = "Phonon is reading this chapter in Echo. The next step is due on Friday."
            let chunk = try await engine.synthesize(text, voice: voice)
            #expect(chunk.sampleRate == 24_000)
            #expect(chunk.duration > 1)
            #expect(chunk.wordTimings == nil)
            #expect(chunk.pronunciationFallbackHits.isEmpty)
            #expect(chunk.samples.allSatisfy(\.isFinite))
            #expect(chunk.samples.contains { abs($0) > 0.001 })
            _ = try await AVFoundationAudioWriter().write(
                [chunk], to: directory.appendingPathComponent("phonon-public-proof.m4a"))
            try Data(text.utf8).write(to: directory.appendingPathComponent("reference.txt"))
            await engine.unload()
        }
    }
#endif
