// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationSynthesisCacheTests {
    // MARK: Fixtures

    private actor CallRecorder {
        private(set) var texts: [String] = []
        func append(_ text: String) { texts.append(text) }
        func reset() { texts = [] }
    }

    /// Deterministic engine whose PCM depends on the text, so reused and fresh
    /// audio are distinguishable, and which records every synthesized text.
    private final class ContentSeededEngine: TTSEngine {
        let recorder: CallRecorder
        init(recorder: CallRecorder) { self.recorder = recorder }

        func prepare() async throws {}

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            await recorder.append(text)
            let words = text.split(whereSeparator: \.isWhitespace).count
            let perWord = 0.2
            let frameCount = Int(Double(max(words, 1)) * perWord * 24_000)
            var seed: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 {
                seed = (seed ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            let phase = Float(seed % 1_000) / 1_000
            let samples = (0..<frameCount).map { index in
                0.05 + 0.01 * sin(Float(index) * 0.01 + phase * 6.28)
            }
            return TTSChunk(
                samples: samples,
                sampleRate: 24_000,
                duration: Double(frameCount) / 24_000,
                wordTimings: (0..<words).map {
                    ChunkWordTiming(
                        wordIndex: $0, start: Double($0) * perWord, end: Double($0 + 1) * perWord)
                })
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthesis-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plan(
        display: String = "Hello there.",
        phonemeIDs: [Int32] = [0, 50, 51, 52, 0],
        fallbackHits: [PronunciationFallbackHit] = []
    ) -> PlannedSynthesisChunk {
        PlannedSynthesisChunk(
            displayText: display,
            g2pInputText: display,
            phonemes: "abc",
            phonemeIDs: phonemeIDs,
            wordCount: 2,
            pronunciationFallbackHits: fallbackHits,
            pronunciationEvidenceValidation: .matched)
    }

    private func config(
        epub: URL, root: URL, run: String, cache: URL?, digest: String = "build-a"
    ) -> NarrationRunConfig {
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: root.appendingPathComponent("\(run)/book.m4b"),
            sidecarURL: root.appendingPathComponent("\(run)/book.alignment.json"),
            workDir: root.appendingPathComponent("\(run)/work", isDirectory: true),
            voice: VoiceID("af_heart"),
            title: "Fixture",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        config.synthesisCacheURL = cache
        config.rendererBuildDigest = digest
        config.generatePronunciationReview = false
        return config
    }

    /// Chapter audio of a completed run, in chapter order, as the SHA-256 of
    /// its decoded PCM. AVFoundation's writer stamps container metadata, so
    /// the encoded files are compared by what a player decodes from them.
    private func chapterAudioDigests(in workDir: URL) throws -> [String] {
        let markers = try FileManager.default.contentsOfDirectory(
            at: workDir, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".anchors-ch") }
        let captures = try markers.map {
            try JSONDecoder().decode(
                HeadlessNarrationRunner.ChapterCapture.self, from: Data(contentsOf: $0))
        }.sorted { ($0.identity?.chapterIndex ?? 0) < ($1.identity?.chapterIndex ?? 0) }
        return try captures.map { capture in
            let name = try #require(capture.identity?.audioFileName)
            let file = try AVAudioFile(forReading: workDir.appendingPathComponent(name))
            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channel = try #require(buffer.floatChannelData)[0]
            let pcm = Data(
                bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
            return SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func editSecondParagraphOfChapterOne(in epub: URL) throws {
        let chapter = epub.appending(path: "OEBPS/chap01.xhtml")
        let original = try String(contentsOf: chapter, encoding: .utf8)
        let edited = original.replacingOccurrences(
            of: "The stub engine will synthesize silence",
            with: "The edited engine will synthesize new audio")
        #expect(edited != original)
        try edited.write(to: chapter, atomically: true, encoding: .utf8)
    }

    // MARK: Store and key

    @Test func storeRoundTripsExactSamplesTimingsAndFallbackHits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NarrationSynthesisCacheStore(rootURL: root)
        let chunk = TTSChunk(
            samples: [0, -0.5, 0.25, .leastNonzeroMagnitude, 1],
            sampleRate: 24_000,
            duration: 5.0 / 24_000,
            wordTimings: [ChunkWordTiming(wordIndex: 0, start: 0, end: 0.0001)],
            pronunciationFallbackHits: [
                PronunciationFallbackHit(word: "Zyx", ipa: "zɪks")
            ])

        try store.write(chunk, key: "abcdef")
        #expect(store.read(key: "abcdef") == chunk)
        #expect(store.read(key: "missing") == nil)
    }

    @Test func storeTreatsCorruptOrMisfiledEntriesAsMisses() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NarrationSynthesisCacheStore(rootURL: root)
        let chunk = TTSChunk(samples: [0.1, 0.2, 0.3], sampleRate: 24_000, duration: 3.0 / 24_000)
        try store.write(chunk, key: "aa11")

        // An entry copied under another key must not be replayed for it.
        let misfiled = store.url(forKey: "bb22")
        try FileManager.default.createDirectory(
            at: misfiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.url(forKey: "aa11"), to: misfiled)
        #expect(store.read(key: "bb22") == nil)

        // One flipped PCM byte fails the stored SHA-256.
        var bytes = try Data(contentsOf: store.url(forKey: "aa11"))
        bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: store.url(forKey: "aa11"))
        #expect(store.read(key: "aa11") == nil)
    }

    @Test func keyChangesWithEveryEngineInputAndRendererIdentity() {
        let context = NarrationSynthesisCacheContext(
            rendererBuildDigest: "build-a", includesWordTimings: true)
        let base = NarrationSynthesisCache.key(
            for: plan(), voice: VoiceID("am_michael"), context: context)

        #expect(
            base
                == NarrationSynthesisCache.key(
                    for: plan(), voice: VoiceID("am_michael"), context: context))
        let variants = [
            NarrationSynthesisCache.key(
                for: plan(phonemeIDs: [0, 50, 51, 53, 0]), voice: VoiceID("am_michael"),
                context: context),
            NarrationSynthesisCache.key(
                for: plan(display: "Hello, there."), voice: VoiceID("am_michael"),
                context: context),
            NarrationSynthesisCache.key(
                for: plan(fallbackHits: [
                    PronunciationFallbackHit(word: "there", ipa: "ðɛɹ")
                ]), voice: VoiceID("am_michael"), context: context),
            NarrationSynthesisCache.key(
                for: plan(), voice: VoiceID("bf_emma"), context: context),
            NarrationSynthesisCache.key(
                for: plan(), voice: VoiceID("am_michael"),
                context: NarrationSynthesisCacheContext(
                    rendererBuildDigest: "build-b", includesWordTimings: true)),
            NarrationSynthesisCache.key(
                for: plan(), voice: VoiceID("am_michael"),
                context: NarrationSynthesisCacheContext(
                    renderVersion: NarrationFileNaming.renderVersion + 1,
                    rendererBuildDigest: "build-a", includesWordTimings: true)),
            NarrationSynthesisCache.key(
                for: plan(), voice: VoiceID("am_michael"),
                context: NarrationSynthesisCacheContext(
                    rendererBuildDigest: "build-a", includesWordTimings: false)),
        ]
        #expect(!variants.contains(base))
        #expect(Set(variants).count == variants.count)
    }

    // MARK: Incremental re-render

    @Test func editingOneParagraphResynthesizesOnlyThatBlockAndKeepsOtherAudio() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try TestEPUBFixture.twoChapters(in: root)
        let cache = root.appendingPathComponent("synthesis-cache", isDirectory: true)
        let recorder = CallRecorder()

        let first = config(epub: epub, root: root, run: "first", cache: cache)
        let firstResult = try await HeadlessNarrationRunner().run(
            first, tts: ContentSeededEngine(recorder: recorder))
        #expect(firstResult.complete)
        #expect(firstResult.synthesisCache?.hits == 0)
        let firstCalls = await recorder.texts
        #expect(firstResult.synthesisCache?.misses == firstCalls.count)
        let firstDigests = try chapterAudioDigests(in: first.workDir)
        #expect(firstDigests.count == 2)

        try editSecondParagraphOfChapterOne(in: epub)
        await recorder.reset()

        // A new source revision gets a new work directory, as the pipeline does.
        let second = config(epub: epub, root: root, run: "second", cache: cache)
        let secondResult = try await HeadlessNarrationRunner().run(
            second, tts: ContentSeededEngine(recorder: recorder))
        #expect(secondResult.complete)

        let secondCalls = await recorder.texts
        #expect(!secondCalls.isEmpty)
        #expect(secondCalls.allSatisfy { $0.contains("edited engine") })
        #expect(secondResult.synthesisCache?.misses == secondCalls.count)
        #expect(
            secondResult.synthesisCache?.hits
                == firstCalls.count - firstCalls.filter { $0.contains("stub engine") }.count)

        // Chapter 2 is untouched: it decodes to sample-identical audio. Chapter 1
        // holds the edit, so its audio differs.
        let secondDigests = try chapterAudioDigests(in: second.workDir)
        #expect(secondDigests[1] == firstDigests[1])
        #expect(secondDigests[0] != firstDigests[0])

        // The rebuilt sidecar resolves against the edited source and new M4B.
        let blocks = try await SidecarSourceBlockLoader.blocks(from: epub)
        let timing = try await ChapteredAudioTimingReader.timings(at: second.outM4BURL)
        let anchors = try AlignmentSidecar.decode(
            Data(contentsOf: try #require(second.sidecarURL)))
        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors, blocks: blocks,
            chapterTimings: timing.chapterTimings, audioDuration: timing.duration)
        #expect(report.anchorCount == anchors.count)
        #expect(report.anchorsWithWords > 0)
    }

    @Test func rendererBuildChangeReusesNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try TestEPUBFixture.twoChapters(in: root)
        let cache = root.appendingPathComponent("synthesis-cache", isDirectory: true)
        let recorder = CallRecorder()

        _ = try await HeadlessNarrationRunner().run(
            config(epub: epub, root: root, run: "a", cache: cache, digest: "build-a"),
            tts: ContentSeededEngine(recorder: recorder))
        let result = try await HeadlessNarrationRunner().run(
            config(epub: epub, root: root, run: "b", cache: cache, digest: "build-b"),
            tts: ContentSeededEngine(recorder: recorder))
        #expect(result.synthesisCache?.hits == 0)
        #expect((result.synthesisCache?.misses ?? 0) > 0)
    }

    @Test func runWithoutCacheReportsNoCacheStats() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try TestEPUBFixture.twoChapters(in: root)
        let result = try await HeadlessNarrationRunner().run(
            config(epub: epub, root: root, run: "plain", cache: nil),
            tts: ContentSeededEngine(recorder: CallRecorder()))
        #expect(result.complete)
        #expect(result.synthesisCache == nil)
    }

    // MARK: Dry run

    @Test func dryRunListsExactlyTheBlocksAnEditWouldResynthesize() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try TestEPUBFixture.twoChapters(in: root)
        let cache = root.appendingPathComponent("synthesis-cache", isDirectory: true)
        let first = config(epub: epub, root: root, run: "first", cache: cache)

        // Empty cache: everything would render.
        let cold = try await HeadlessNarrationRunner().preview(first, neuralEvaluator: nil)
        #expect(!cold.blocks.isEmpty)
        #expect(cold.blocksToRender.count == cold.blocks.count)

        let recorder = CallRecorder()
        _ = try await HeadlessNarrationRunner().run(
            first, tts: ContentSeededEngine(recorder: recorder))
        let warm = try await HeadlessNarrationRunner().preview(first, neuralEvaluator: nil)
        #expect(warm.blocksToRender.isEmpty)
        #expect(warm.cachedChunkCount == warm.chunkCount)

        try editSecondParagraphOfChapterOne(in: epub)
        let second = config(epub: epub, root: root, run: "second", cache: cache)
        let edited = try await HeadlessNarrationRunner().preview(second, neuralEvaluator: nil)
        #expect(edited.blocksToRender.count == 1)
        let changed = try #require(edited.blocksToRender.first)
        #expect(changed.chapterDisplayNumber == 1)
        #expect(changed.text.contains("edited engine"))
        #expect(edited.reportLines().last?.hasPrefix("DRY_RUN 1 of ") == true)

        // The dry run wrote nothing into the new run's paths.
        #expect(!FileManager.default.fileExists(atPath: second.workDir.path))
        #expect(!FileManager.default.fileExists(atPath: second.outM4BURL.path))

        // Its prediction matches what the real render then synthesizes.
        await recorder.reset()
        let result = try await HeadlessNarrationRunner().run(
            second, tts: ContentSeededEngine(recorder: recorder))
        #expect(result.synthesisCache?.misses == changed.chunkCount - changed.cachedChunkCount)
    }
}
