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
        let router = NarrationEngineRouter(kokoro: kokoro, phonon: phonon)
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

    @Test func phononKeepsParagraphContextAndBoundsUnusuallyLongSentences() async throws {
        let paragraph = Array(repeating: "Echo keeps this whole sentence together.", count: 20)
            .joined(separator: " ")
        let plan = try await PhononRenderPlanner.make(blocks: [block("p", text: paragraph)])
        let rendered = try #require(plan.blocks.first)
        #expect(rendered.synthesisChunks.count == 1)
        #expect(rendered.synthesisChunks.first?.displayText == paragraph)
        #expect(rendered.pronunciationDecisions.isEmpty)
        #expect(rendered.synthesisChunks.allSatisfy { $0.phonemeIDs.isEmpty })

        let longSentence = (0..<1001).map { "word\($0)" }.joined(separator: " ")
        let chunks = PhononRenderPlanner.chunkTexts(longSentence, maxWords: 80)
        #expect(chunks.allSatisfy { WordTokenizer.words(in: $0).count <= 80 })
        #expect(chunks.joined(separator: " ") == longSentence)
    }

    @MainActor @Test func mixedPlanningPreservesOrderAndSeparatorPauses() async throws {
        let database = try DatabaseService(inMemory: true)
        let engine = RecordingEngine()
        let service = NarrationService(
            db: database.writer, audiobookID: "book", tts: engine,
            audioWriter: AVFoundationAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory, state: NarrationState())
        let native = block("native", text: "This is a complete sentence for Phonon.")
        let separator = block("break", text: "---")
        let legacy = block("legacy", text: "This stays with Kokoro.")
        let plan = try await service.renderPlan(
            for: [native, separator, legacy], overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty, fmEnabled: false,
            textOnlyBlockIDs: [native.id, separator.id])
        #expect(plan.blocks.map(\.blockID) == ["native", "break", "legacy"])
        #expect(plan.blocks[0].synthesisChunks.allSatisfy { $0.phonemeIDs.isEmpty })
        #expect(plan.blocks[0].trailingSilence == nil)
        #expect(plan.blocks[1].trailingSilence == .sectionBreak)
        #expect(plan.blocks[2].synthesisChunks.contains { !$0.phonemeIDs.isEmpty })
        #expect(plan.blocks[2].trailingSilence == nil)
    }

    private func block(_ id: String, text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: "paragraph", text: text, htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
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
