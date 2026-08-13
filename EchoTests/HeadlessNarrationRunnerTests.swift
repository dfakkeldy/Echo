// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct HeadlessNarrationRunnerTests {
    private enum VoicePlanResumeMutation: String, CaseIterable, Sendable {
        case usedSpeakerVoice
        case explicitBlockMove
        case rangeEndpoint
    }
    private actor EvaluatedWords {
        private var words: [String] = []

        func append(_ word: String) {
            words.append(word)
        }

        func snapshot() -> [String] {
            words
        }
    }

    private func auditDecision(
        chapterIndex: Int,
        chapterRange: PronunciationAuditDecision.AudioRange?,
        blockID: String? = nil,
        wordStart: Int = 2,
        timingPrecision: PronunciationAuditDecision.TimingPrecision? = nil
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: blockID ?? "blk-\(chapterIndex)",
            wordStart: wordStart,
            wordEnd: wordStart,
            normalizedWord: "verified",
            sourceWord: "verified",
            sourceContext: "The result was verified here",
            selectedIPA: "vˈɛɹɪfˌaɪd",
            kokoroTokenIDs: [60, 31, 57],
            source: .monitoredLexicon,
            ruleID: "g2p.lexicon.verified",
            rationale: "Watched ordinary-lexicon pronunciation selected for “verified”.",
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: chapterRange,
            timingPrecision: chapterRange == nil ? nil : (timingPrecision ?? .exactSynthesisWord))
    }

    private func auditDiagnostic(
        reason: PronunciationAuditDiagnostic.Reason,
        chapterIndex: Int
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: reason,
            blockID: "blk-\(chapterIndex)",
            chunkIndex: 1,
            chapterIndex: chapterIndex,
            expectedDisplayText: "verified [site](https://example.com)",
            reconstructedSpokenSurface: reason == .spokenSurfaceMismatch ? "verified site" : "",
            fallbackHits: [])
    }

    private func captureIdentity(chapterIndex: Int)
        -> HeadlessNarrationRunner.ChapterCapture.Identity
    {
        HeadlessNarrationRunner.ChapterCapture.Identity(
            schemaVersion: 1,
            captureSetID: "test-set",
            sourceFingerprint: "test-source",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            chapterIndex: chapterIndex,
            chapterContentSignature: "chapter-\(chapterIndex)",
            audioFileName: "chapter-\(chapterIndex).m4a",
            audioFileByteCount: 1)
    }

    private func narrationBlock(id: String, text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "chapter.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: "paragraph", text: text, htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }

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
        private(set) var voices: [VoiceID] = []

        func append(_ voice: VoiceID) {
            voices.append(voice)
        }
    }

    private final class VoiceRecordingEngine: TTSEngine {
        let recorder: VoiceRecorder

        init(recorder: VoiceRecorder) {
            self.recorder = recorder
        }

        func prepare() async throws {}

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            await recorder.append(voice)
            return TTSChunk(
                samples: [Float](repeating: 0.1, count: 4_800),
                sampleRate: 24_000,
                duration: 0.2)
        }
    }

    /// Engine that emits one ChunkWordTiming per whitespace word (0.2s each) so
    /// the run persists known-true `source == "synthesis"` word rows — the rows
    /// the sidecar word export carries. Mirrors
    /// `NarrationServiceSynthesisTimingTests.WordTimedEngine`.
    private final class WordTimedStubEngine: TTSEngine {
        func prepare() async throws {}
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            let dur = Double(max(words, 1)) * 0.2
            let samples = [Float](repeating: 0.05, count: Int(dur * 24_000))
            let timings = (0..<words).map {
                ChunkWordTiming(
                    wordIndex: $0, start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.2)
            }
            return TTSChunk(
                samples: samples, sampleRate: 24_000,
                duration: Double(samples.count) / 24_000, wordTimings: timings)
        }
    }

    private actor WordTimedVoiceRecorder {
        private var calls: [(text: String, voice: VoiceID)] = []

        func append(text: String, voice: VoiceID) {
            calls.append((text, voice))
        }

        func snapshot() -> [(text: String, voice: VoiceID)] {
            calls
        }
    }

    private final class WordTimedVoiceRecordingEngine: TTSEngine {
        let recorder: WordTimedVoiceRecorder

        init(recorder: WordTimedVoiceRecorder) {
            self.recorder = recorder
        }

        func prepare() async throws {}

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            await recorder.append(text: text, voice: voice)
            return chunk(for: text)
        }

        func synthesize(_ plan: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            await recorder.append(text: plan.displayText, voice: voice)
            return chunk(for: plan.g2pInputText)
        }

        private func chunk(for text: String) -> TTSChunk {
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            let duration = Double(max(words, 1)) * 0.2
            let samples = [Float](repeating: 0.05, count: Int(duration * 24_000))
            let timings = (0..<words).map {
                ChunkWordTiming(
                    wordIndex: $0, start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.2)
            }
            return TTSChunk(
                samples: samples,
                sampleRate: 24_000,
                duration: Double(samples.count) / 24_000,
                wordTimings: timings)
        }
    }

    private final class PrepareMutationEngine: TTSEngine, @unchecked Sendable {
        private let mutation: @Sendable () throws -> Void

        init(mutation: @escaping @Sendable () throws -> Void) {
            self.mutation = mutation
        }

        func prepare() async throws {
            try mutation()
        }

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws
        {
            try mutation()
            progress(.ready)
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            TTSChunk(
                samples: [Float](repeating: 0.1, count: 4_800),
                sampleRate: 24_000,
                duration: 0.2)
        }
    }

    private actor PrepareGate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pause() async {
            started = true
            startWaiter?.resume()
            startWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private final class BlockingPrepareEngine: TTSEngine {
        let gate: PrepareGate

        init(gate: PrepareGate) {
            self.gate = gate
        }

        func prepare() async throws {
            await gate.pause()
        }

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws
        {
            await gate.pause()
            progress(.ready)
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            TTSChunk(
                samples: [Float](repeating: 0.1, count: 4_800),
                sampleRate: 24_000,
                duration: 0.2)
        }
    }

    @Test func batchRendersDefaultToDeterministicNormalization() {
        let cfg = NarrationRunConfig(
            epubURL: URL(fileURLWithPath: "/tmp/book.epub"),
            outM4BURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            sidecarURL: nil,
            workDir: URL(fileURLWithPath: "/tmp/work", isDirectory: true),
            voice: VoiceID("af_heart"),
            title: "Fixture",
            author: "Tester",
            maxNewChaptersPerRun: nil)

        #expect(cfg.enableFMNormalization == false)
        #expect(cfg.generatePronunciationReview)
    }

    @Test func voicePlanConfigurationAcceptsNoExplicitVoice() {
        let config = NarrationRunConfig(
            epubURL: URL(fileURLWithPath: "/tmp/book.epub"),
            outM4BURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            sidecarURL: nil,
            workDir: URL(fileURLWithPath: "/tmp/work", isDirectory: true),
            voice: nil,
            voicePlanURL: URL(fileURLWithPath: "/tmp/book.voice-plan.json"),
            title: "Fixture",
            author: "Echo",
            maxNewChaptersPerRun: nil)

        #expect(config.voice == nil)
        #expect(config.voicePlanURL?.lastPathComponent == "book.voice-plan.json")
    }

    @Test func noPlanConfigurationDefersToTheCatalogDefaultVoice() {
        let config = NarrationRunConfig(
            epubURL: URL(fileURLWithPath: "/tmp/book.epub"),
            outM4BURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            sidecarURL: nil,
            workDir: URL(fileURLWithPath: "/tmp/work", isDirectory: true),
            voice: nil,
            title: "Fixture",
            author: "Echo",
            maxNewChaptersPerRun: nil)

        #expect(HeadlessNarrationRunner.legacyDefaultVoice(for: config) == VoiceCatalog.default.id)
    }

    @Test func planCaptureIdentityUsesSchemaTwoAndRejectsLegacyResume() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let planHash = String(repeating: "a", count: 64)
        let chapterPlanHash = String(repeating: "b", count: 64)
        let audioName = "runner-book-ch0-hsig-plan-0123456789ab-v22.m4a"
        let audio = tmp.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audio)
        let planExpected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 2,
            captureSetID: "plan-set",
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 22,
            rendererIdentity: NarrationFileNaming.rendererIdentity,
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "sig",
            audioFileName: audioName,
            voicePlanSHA256: planHash,
            chapterVoicePlanSHA256: chapterPlanHash)
        let legacyExpected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "legacy-set",
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 22,
            rendererIdentity: NarrationFileNaming.rendererIdentity,
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "sig",
            audioFileName: audioName)

        let sealedPlanCapture = try HeadlessNarrationRunner.sealedCapture(
            .init(duration: 1, anchors: [], pronunciationEvidence: .init(decisions: [], diagnostics: [])),
            audioURL: audio,
            expected: planExpected,
            workDir: tmp)
        let identity = try #require(sealedPlanCapture.identity)
        #expect(identity.schemaVersion == 2)
        #expect(identity.voicePlanSHA256 == planHash)
        #expect(identity.chapterVoicePlanSHA256 == chapterPlanHash)
        #expect(identity.audioFileName.contains("plan-0123456789ab"))
        #expect(
            try HeadlessNarrationRunner.validateCapture(
                sealedPlanCapture, chapterIndex: 0, expected: planExpected, workDir: tmp) == audio)
        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.validateCapture(
                sealedPlanCapture, chapterIndex: 0, expected: legacyExpected, workDir: tmp)
        }
    }

    @Test func legacyCaptureIdentityCannotResumeAsPlanCapture() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let audioName = "runner-book-ch0-hsig-af_heart-v22.m4a"
        let audio = tmp.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audio)
        let legacyExpected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "legacy-set",
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 22,
            rendererIdentity: NarrationFileNaming.rendererIdentity,
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "sig",
            audioFileName: audioName)
        let planExpected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 2,
            captureSetID: "plan-set",
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 22,
            rendererIdentity: NarrationFileNaming.rendererIdentity,
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "sig",
            audioFileName: audioName,
            voicePlanSHA256: String(repeating: "a", count: 64),
            chapterVoicePlanSHA256: String(repeating: "b", count: 64))

        let sealedLegacyCapture = try HeadlessNarrationRunner.sealedCapture(
            .init(duration: 1, anchors: [], pronunciationEvidence: .init(decisions: [], diagnostics: [])),
            audioURL: audio,
            expected: legacyExpected,
            workDir: tmp)
        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.validateCapture(
                sealedLegacyCapture, chapterIndex: 0, expected: planExpected, workDir: tmp)
        }
    }

    @Test(arguments: VoicePlanResumeMutation.allCases)
    private func changedResolvedPlanRejectsInterruptedCaptureAndPreservesWorkDirectory(
        mutation: VoicePlanResumeMutation
    ) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let sourceSHA = try HeadlessNarrationRunner.fileSHA256(at: epub)
        let planURL = tmp.appendingPathComponent("fixture.voice-plan.json")
        let seedPlan = """
        {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"},{"id":"dialogue","voiceID":"bf_emma"}],"assignments":[]}
        """
        try Data(seedPlan.utf8).write(to: planURL)
        let seedResolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epub, voicePlanURL: planURL)
        let firstChapter = seedResolved.blocks.filter { $0.blockID.hasPrefix("s0-") }
        let secondChapter = seedResolved.blocks.filter { $0.blockID.hasPrefix("s1-") }
        let explicitOriginal = try #require(firstChapter.first?.blockID)
        let explicitMoved = try #require(firstChapter.dropFirst().first?.blockID)
        let rangeStart = try #require(secondChapter.first?.blockID)
        let rangeEnd = try #require(secondChapter.dropFirst().first?.blockID)
        let extendedRangeEnd = try #require(secondChapter.dropFirst(2).first?.blockID)

        func plan(dialogueVoice: String, explicitBlock: String, rangeEnd: String) -> String {
            """
            {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"},{"id":"dialogue","voiceID":"\(dialogueVoice)"}],"assignments":[{"speakerID":"dialogue","blocks":["\(explicitBlock)"]},{"speakerID":"dialogue","range":{"start":"\(rangeStart)","end":"\(rangeEnd)"}}]}
            """
        }
        let baselineJSON = plan(
            dialogueVoice: "bf_emma", explicitBlock: explicitOriginal, rangeEnd: rangeEnd)
        try Data(baselineJSON.utf8).write(to: planURL)
        let baseline = try HeadlessNarrationRunner.resolveVoicePlan(epubURL: epub, voicePlanURL: planURL)
        var config = NarrationRunConfig(
            epubURL: epub, outM4BURL: tmp.appendingPathComponent("out.m4b"), sidecarURL: nil,
            workDir: tmp.appendingPathComponent("work"), voice: nil, voicePlanURL: planURL,
            title: "Fixture", author: "Echo", maxNewChaptersPerRun: 1)
        config.generatePronunciationReview = false
        _ = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        let marker = config.workDir.appendingPathComponent(".anchors-ch0.json")
        let before = try Data(contentsOf: marker)
        let contentsBefore = try FileManager.default.contentsOfDirectory(
            atPath: config.workDir.path).sorted()

        let changedJSON: String
        switch mutation {
        case .usedSpeakerVoice:
            changedJSON = plan(dialogueVoice: "bm_fable", explicitBlock: explicitOriginal, rangeEnd: rangeEnd)
        case .explicitBlockMove:
            changedJSON = plan(dialogueVoice: "bf_emma", explicitBlock: explicitMoved, rangeEnd: rangeEnd)
        case .rangeEndpoint:
            changedJSON = plan(dialogueVoice: "bf_emma", explicitBlock: explicitOriginal, rangeEnd: extendedRangeEnd)
        }
        try Data(changedJSON.utf8).write(to: planURL)
        let changed = try HeadlessNarrationRunner.resolveVoicePlan(epubURL: epub, voicePlanURL: planURL)
        #expect(changed.voicePlanSHA256 != baseline.voicePlanSHA256)
        #expect(
            changed.chapterDigest(blockIDs: firstChapter.map(\.blockID))
                != baseline.chapterDigest(blockIDs: firstChapter.map(\.blockID))
                || changed.chapterDigest(blockIDs: secondChapter.map(\.blockID))
                    != baseline.chapterDigest(blockIDs: secondChapter.map(\.blockID)))

        await #expect(throws: Error.self) {
            try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        }
        #expect(try Data(contentsOf: marker) == before)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: config.workDir.path).sorted()
                == contentsBefore)
    }

    @Test func equivalentPlanResumesSchemaTwoCaptureAndChangedPlanFailsClosed() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let sourceSHA = try HeadlessNarrationRunner.fileSHA256(at: epub)
        let planURL = tmp.appendingPathComponent("fixture.voice-plan.json")
        let firstPlan = """
        {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"},{"id":"alternate","voiceID":"am_michael"}],"assignments":[]}
        """
        try Data(firstPlan.utf8).write(to: planURL)
        let resolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epub, voicePlanURL: planURL)
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("out.m4b"),
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("work"),
            voice: nil,
            voicePlanURL: planURL,
            title: "Fixture",
            author: "Echo",
            maxNewChaptersPerRun: 1)
        config.generatePronunciationReview = false

        let first = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        #expect(!first.complete)
        #expect(first.capturedThisRun == 1)
        let firstCapture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: Data(contentsOf: config.workDir.appendingPathComponent(".anchors-ch0.json")))
        let firstIdentity = try #require(firstCapture.identity)
        #expect(firstIdentity.schemaVersion == 2)
        #expect(firstIdentity.voicePlanSHA256 == resolved.voicePlanSHA256)
        #expect(firstIdentity.audioFileName.contains(resolved.voicePlanID))

        let reorderedEquivalentPlan = """
        {"assignments":[],"speakers":[{"voiceID":"am_michael","id":"alternate"},{"voiceID":"af_heart","id":"narrator"}],"defaultSpeakerID":"narrator","source":{"epubSHA256":"\(sourceSHA)"},"schemaVersion":1}
        """
        try Data(reorderedEquivalentPlan.utf8).write(to: planURL)
        let second = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        #expect(second.complete)
        #expect(second.capturedThisRun == 1)

        let changedDefaultPlan = """
        {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"alternate","speakers":[{"id":"narrator","voiceID":"af_heart"},{"id":"alternate","voiceID":"am_michael"}],"assignments":[]}
        """
        try Data(changedDefaultPlan.utf8).write(to: planURL)
        await #expect(throws: Error.self) {
            try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        }
    }

    @Test func planRunSuppliesEveryResolvedBlockVoiceToTheAuditRequest() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let sourceSHA = try HeadlessNarrationRunner.fileSHA256(at: epub)
        let planURL = tmp.appendingPathComponent("fixture.voice-plan.json")
        try Data(
            """
            {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"},{"id":"mara","voiceID":"bf_emma"}],"assignments":[{"speakerID":"mara","blocks":["s0-b0"]}]}
            """.utf8).write(to: planURL)
        let resolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epub, voicePlanURL: planURL)
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("voice-plan.m4b"),
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("voice-plan-work"),
            voice: nil,
            voicePlanURL: planURL,
            title: "Fixture",
            author: "Echo",
            maxNewChaptersPerRun: nil)
        var capturedRequest: PronunciationReviewRequest?

        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            reviewGenerator: { request in
                capturedRequest = request
                return .auditOnly(auditURL: request.auditURL)
            })

        let request = try #require(capturedRequest)
        let provenance = try #require(request.blockVoiceProvenance)
        #expect(result.complete)
        #expect(provenance.voicePlanSHA256 == resolved.voicePlanSHA256)
        #expect(provenance.blockVoices == Dictionary(
            uniqueKeysWithValues: resolved.blocks.map { ($0.blockID, $0.voiceID) }))
    }

    @Test func planWithPDFFailsBeforeFreshCleanup() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let work = tmp.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = work.appendingPathComponent(".anchors-ch0.json")
        try Data("keep me".utf8).write(to: marker)
        let pdf = tmp.appendingPathComponent("source.pdf")
        try Data("not a PDF".utf8).write(to: pdf)

        let config = NarrationRunConfig(
            epubURL: pdf,
            outM4BURL: tmp.appendingPathComponent("out.m4b"),
            sidecarURL: nil,
            workDir: work,
            voice: nil,
            voicePlanURL: tmp.appendingPathComponent("plan.json"),
            title: "Fixture",
            author: "Echo",
            maxNewChaptersPerRun: nil,
            clearExistingCapturesBeforeRun: true)

        await #expect(throws: Error.self) {
            try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func planWithChapterOverrideFailsBeforeFreshCleanup() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("source.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let plan = tmp.appendingPathComponent("plan.json")
        try Data("""
        {"schemaVersion":1,"source":{"epubSHA256":"\(try HeadlessNarrationRunner.fileSHA256(at: epub))"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"}],"assignments":[]}
        """.utf8).write(to: plan)
        let work = tmp.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = work.appendingPathComponent(".anchors-ch0.json")
        try Data("keep me".utf8).write(to: marker)
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("out.m4b"),
            sidecarURL: nil,
            workDir: work,
            voice: nil,
            voicePlanURL: plan,
            title: "Fixture",
            author: "Echo",
            maxNewChaptersPerRun: nil,
            clearExistingCapturesBeforeRun: true)
        config.chapterVoicesByDisplayNumber = [1: VoiceID("af_bella")]

        await #expect(throws: Error.self) {
            try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func invalidPlanFailsBeforeFreshCleanup() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("source.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let plan = tmp.appendingPathComponent("plan.json")
        try Data("not JSON".utf8).write(to: plan)
        let work = tmp.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = work.appendingPathComponent(".anchors-ch0.json")
        try Data("keep me".utf8).write(to: marker)
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("out.m4b"),
            sidecarURL: nil,
            workDir: work,
            voice: nil,
            voicePlanURL: plan,
            title: "Fixture",
            author: "Echo",
            maxNewChaptersPerRun: nil,
            clearExistingCapturesBeforeRun: true)

        await #expect(throws: Error.self) {
            try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func planWithConflictingExplicitVoiceFailsBeforeFreshCleanup() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("source.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let plan = tmp.appendingPathComponent("plan.json")
        try Data("{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"\(try HeadlessNarrationRunner.fileSHA256(at: epub))\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[{\"id\":\"narrator\",\"voiceID\":\"af_heart\"}],\"assignments\":[]}".utf8).write(to: plan)
        let work = tmp.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = work.appendingPathComponent(".anchors-ch0.json"); try Data("keep".utf8).write(to: marker)
        let config = NarrationRunConfig(epubURL: epub, outM4BURL: tmp.appendingPathComponent("out.m4b"), sidecarURL: nil, workDir: work, voice: VoiceID("af_bella"), voicePlanURL: plan, title: "Fixture", author: "Echo", maxNewChaptersPerRun: nil, clearExistingCapturesBeforeRun: true)
        await #expect(throws: Error.self) { try await HeadlessNarrationRunner().run(config, tts: StubEngine()) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func planWithDirectorySourceFailsBeforeFreshCleanup() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let expanded = try TestEPUBFixture.twoChapters(in: source)
        let boundEPUB = source.appendingPathComponent("bound.epub")
        try FileManager.default.zipItem(at: expanded, to: boundEPUB, shouldKeepParent: false)
        let plan = tmp.appendingPathComponent("plan.json")
        try Data(
            "{\"schemaVersion\":1,\"source\":{\"epubSHA256\":\"\(try HeadlessNarrationRunner.fileSHA256(at: boundEPUB))\"},\"defaultSpeakerID\":\"narrator\",\"speakers\":[{\"id\":\"narrator\",\"voiceID\":\"af_heart\"}],\"assignments\":[]}".utf8
        ).write(to: plan)
        let work = tmp.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let marker = work.appendingPathComponent(".anchors-ch0.json")
        let markerBytes = Data("keep marker".utf8)
        try markerBytes.write(to: marker)
        let output = tmp.appendingPathComponent("out.m4b")
        let outputBytes = Data("keep output".utf8)
        try outputBytes.write(to: output)
        let config = NarrationRunConfig(epubURL: source, outM4BURL: output, sidecarURL: nil, workDir: work, voice: nil, voicePlanURL: plan, title: "Fixture", author: "Echo", maxNewChaptersPerRun: nil, clearExistingCapturesBeforeRun: true)
        await #expect(throws: Error.self) { try await HeadlessNarrationRunner().run(config, tts: StubEngine()) }
        #expect(try Data(contentsOf: marker) == markerBytes)
        #expect(try Data(contentsOf: output) == outputBytes)
    }

    @Test func partialRunLeavesPronunciationReviewPendingWithoutInvokingGenerator() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("partial.m4b"),
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("partial-work"),
            voice: VoiceID("af_heart"),
            title: "Partial",
            author: "Tester",
            maxNewChaptersPerRun: 1)
        var invoked = false

        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            reviewGenerator: { request in
                invoked = true
                return .auditOnly(auditURL: request.auditURL)
            })

        #expect(!result.complete)
        #expect(result.pronunciationReview == .pending)
        #expect(!invoked)
    }

    @Test func completedOptOutRemovesStaleReviewArtifactsAndSkipsGenerator() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("disabled.m4b")
        let audit = tmp.appendingPathComponent("disabled.pronunciation-audit.json")
        let reel = tmp.appendingPathComponent("disabled.pronunciation-reel.m4b")
        try Data("stale audit".utf8).write(to: audit)
        try Data("stale reel".utf8).write(to: reel)
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("disabled-work"),
            voice: VoiceID("af_heart"),
            title: "Disabled",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        config.generatePronunciationReview = false
        var invoked = false

        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            reviewGenerator: { request in
                invoked = true
                return .auditOnly(auditURL: request.auditURL)
            })

        #expect(result.complete)
        #expect(result.pronunciationReview == .disabled)
        #expect(!invoked)
        #expect(!FileManager.default.fileExists(atPath: audit.path))
        #expect(!FileManager.default.fileExists(atPath: reel.path))
    }

    @Test func chapterVoiceListSelectsTheVoiceUsedForEachChapter() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let recorder = VoiceRecorder()
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("mixed.m4b"),
            sidecarURL: tmp.appendingPathComponent("mixed.alignment.json"),
            workDir: tmp.appendingPathComponent("mixed-work"),
            voice: VoiceID("af_heart"),
            title: "Mixed",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        config.chapterVoicesByDisplayNumber = [1: VoiceID("af_bella"), 2: VoiceID("bf_emma")]
        var capturedReviewRequest: PronunciationReviewRequest?

        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: VoiceRecordingEngine(recorder: recorder),
            reviewGenerator: { request in
                capturedReviewRequest = request
                return .auditOnly(auditURL: request.auditURL)
            })

        #expect(result.complete)
        let voices = await recorder.voices
        let reviewRequest = try #require(capturedReviewRequest)
        #expect(voices.contains(VoiceID("af_bella")))
        #expect(voices.contains(VoiceID("bf_emma")))
        #expect(voices.first == VoiceID("af_bella"))
        #expect(voices.last == VoiceID("bf_emma"))
        #expect(reviewRequest.voice == VoiceID("mixed"))
        #expect(Set(reviewRequest.chapterVoices.values) == Set(voices))
    }

    @Test func chapterVoiceListIgnoresNonNarratableSpineItems() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoNarratableChaptersWithNonNarratableSpineItems(in: tmp)
        let recorder = VoiceRecorder()
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("planned-only.m4b"),
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("planned-only-work"),
            voice: VoiceID("af_heart"),
            title: "Planned only",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        config.chapterVoicesByDisplayNumber = [1: VoiceID("af_bella"), 2: VoiceID("bf_emma")]
        config.generatePronunciationReview = false

        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: VoiceRecordingEngine(recorder: recorder))

        #expect(result.complete)
        #expect(Set(await recorder.voices) == Set([VoiceID("af_bella"), VoiceID("bf_emma")]))
    }

    @Test func changingChapterVoiceListRejectsExistingCaptures() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("resume.m4b"),
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("resume-work"),
            voice: VoiceID("af_heart"),
            title: "Resume",
            author: "Tester",
            maxNewChaptersPerRun: 1)
        config.chapterVoicesByDisplayNumber = [1: VoiceID("af_bella"), 2: VoiceID("bf_emma")]
        config.generatePronunciationReview = false

        let first = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        #expect(first.complete == false)

        config.chapterVoicesByDisplayNumber = [1: VoiceID("af_bella"), 2: VoiceID("bm_fable")]
        do {
            _ = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
            Issue.record("Expected changed chapter voices to invalidate the existing capture.")
        } catch {
            #expect(error.localizedDescription.contains("capture identity mismatch"))
        }
    }

    @Test func invalidChapterVoiceDoesNotClearFreshRunArtifacts() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let work = tmp.appendingPathComponent("invalid-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let existingCapture = work.appendingPathComponent(".anchors-ch0.json")
        let existingAudio = work.appendingPathComponent("existing-ch0.m4a")
        try Data("capture".utf8).write(to: existingCapture)
        try Data("audio".utf8).write(to: existingAudio)
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("invalid.m4b"),
            sidecarURL: nil,
            workDir: work,
            voice: VoiceID("af_heart"),
            title: "Invalid",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        config.chapterVoicesByDisplayNumber = [99: VoiceID("bf_emma")]
        config.clearExistingCapturesBeforeRun = true

        do {
            _ = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
            Issue.record("Expected an unknown narrated chapter to be rejected.")
        } catch {
            #expect(error.localizedDescription.contains("chapter 99 is not narratable"))
        }
        #expect(FileManager.default.fileExists(atPath: existingCapture.path))
        #expect(FileManager.default.fileExists(atPath: existingAudio.path))
    }

    @Test func completedRunReportsInjectedAuditOnlyOutcomeAndSnapshotsWatchWords() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("audit-only.m4b")
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("audit-only-work"),
            voice: VoiceID("af_heart"),
            title: "Audit Only",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        var capturedRequest: PronunciationReviewRequest?

        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            reviewGenerator: { request in
                capturedRequest = request
                return .auditOnly(auditURL: request.auditURL)
            })

        let request = try #require(capturedRequest)
        #expect(result.pronunciationReview == .auditOnly(auditURL: request.auditURL))
        #expect(request.audiobookURL == out)
        #expect(request.auditURL.lastPathComponent == "audit-only.pronunciation-audit.json")
        #expect(request.reelURL.lastPathComponent == "audit-only.pronunciation-reel.m4b")
        #expect(request.watchWords == request.watchWords.sorted())
        #expect(Set(request.watchWords) == PronunciationWatchVocabulary.words)
    }

    @Test func headlessAndAppPlanningCarryEquivalentAdvisoryEvidence() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let chapterURL = epub.appending(path: "OEBPS/chap01.xhtml")
        let original = try String(contentsOf: chapterURL, encoding: .utf8)
        try original.replacingOccurrences(
            of: "It contains enough words for narration synthesis to produce a non-trivial output.",
            with: "Please record enough words."
        )
        .write(to: chapterURL, atomically: true, encoding: .utf8)

        let auditPack = await EnglishPronunciationAuditPack.bundledOrEmpty()
        let appBlock = EPubBlockRecord(
            id: "app-record",
            audiobookID: "app-book",
            spineHref: "chap01.xhtml",
            spineIndex: 0,
            blockIndex: 1,
            sequenceIndex: 1,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Please record enough words.",
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil)
        let appPlan = try NarrationRenderPlanner.make(
            blocks: [appBlock],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationPack: .empty,
            pronunciationAuditPack: auditPack)
        let appEvidence = try #require(
            appPlan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "record"
            }?.advisoryEvidence)

        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("equivalent.m4b"),
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("equivalent-work"),
            voice: VoiceID("af_heart"),
            title: "Equivalence",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        var capturedRequest: PronunciationReviewRequest?
        _ = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            pronunciationPackLoader: { .empty },
            pronunciationAuditPackLoader: { auditPack },
            reviewGenerator: { request in
                capturedRequest = request
                return .auditOnly(auditURL: request.auditURL)
            })

        let headlessEvidence = try #require(
            capturedRequest?.decisions.first {
                $0.normalizedWord == "record"
            }?.advisoryEvidence)
        #expect(headlessEvidence == appEvidence)
    }

    @Test func headlessNeuralShadowPersistsAdvisoryAndDoesNotChangeResumeIdentity()
        async throws
    {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let chapterURL = epub.appending(path: "OEBPS/chap01.xhtml")
        let original = try String(contentsOf: chapterURL, encoding: .utf8)
        try original.replacingOccurrences(
            of: "It contains enough words for narration synthesis to produce a non-trivial output.",
            with: "Xyzqwf xyzqwf was verified in this synthetic narration fixture."
        )
        .write(to: chapterURL, atomically: true, encoding: .utf8)
        let work = tmp.appendingPathComponent("neural-shadow-work")
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("neural-shadow.m4b"),
            sidecarURL: nil,
            workDir: work,
            voice: VoiceID("af_heart"),
            title: "Neural Shadow",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        let evaluated = EvaluatedWords()
        let candidate = NeuralG2PCandidate(
            candidateID:
                "sha256:aa7069d4801f3e5e6b7b2685b844cc249b3feec9d1c1ab5fc532959948344fbe",
            ipa: "zizkwf",
            modelRevision: MiniBARTG2PEngine.modelRevision,
            conversionPolicyVersion: ARPAbetToKokoroIPA.policyVersion,
            validationPolicyVersion: MiniBARTG2PEngine.validationPolicyVersion,
            selectionPolicyVersion: MiniBARTG2PEngine.selectionPolicyVersion)
        var firstReview: PronunciationReviewRequest?

        let first = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            neuralEvaluator: { word in
                await evaluated.append(word)
                return .candidate(candidate)
            },
            reviewGenerator: { request in
                firstReview = request
                return .auditOnly(auditURL: request.auditURL)
            })
        let fallback = try #require(
            firstReview?.decisions.first { $0.normalizedWord == "xyzqwf" })
        let neural = try #require(
            fallback.advisoryEvidence?.alternatives.first {
                $0.candidateID == candidate.candidateID
            })
        let firstCapture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: Data(contentsOf: work.appendingPathComponent(".anchors-ch0.json")))

        let resumed = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            neuralEvaluator: nil,
            reviewGenerator: { request in .auditOnly(auditURL: request.auditURL) })
        let resumedCapture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: Data(contentsOf: work.appendingPathComponent(".anchors-ch0.json")))

        let evaluatedWords = await evaluated.snapshot()
        #expect(first.complete)
        #expect(evaluatedWords.filter { $0 == "xyzqwf" } == ["xyzqwf", "xyzqwf"])
        #expect(!evaluatedWords.contains("verified"))
        #expect(fallback.source == .fallback)
        #expect(neural.authority == .uncertain)
        #expect(neural.validation == .shadow)
        #expect(neural.policyVersion == "mini-bart-g2p-beam5-max20-v1")
        #expect(resumed.complete)
        #expect(resumed.capturedThisRun == 0)
        #expect(resumedCapture.identity == firstCapture.identity)
    }

    @Test func headlessNeuralCancellationAbortsChapterWithoutPublishingCapture() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let chapterURL = epub.appending(path: "OEBPS/chap01.xhtml")
        let original = try String(contentsOf: chapterURL, encoding: .utf8)
        try original.replacingOccurrences(
            of: "It contains enough words for narration synthesis to produce a non-trivial output.",
            with: "Xyzqwf appears in this synthetic narration fixture."
        )
        .write(to: chapterURL, atomically: true, encoding: .utf8)
        let work = tmp.appendingPathComponent("neural-cancel-work")
        let out = tmp.appendingPathComponent("neural-cancel.m4b")
        let config = NarrationRunConfig(
            epubURL: epub, outM4BURL: out, sidecarURL: nil, workDir: work,
            voice: VoiceID("af_heart"), title: "Neural Cancel", author: "Tester",
            maxNewChaptersPerRun: nil)

        await #expect(throws: CancellationError.self) {
            _ = try await HeadlessNarrationRunner().run(
                config,
                tts: StubEngine(),
                neuralEvaluator: { _ in .rejected(.cancelled) })
        }

        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: work.appendingPathComponent(".anchors-ch0.json").path))
    }

    private enum ReviewFixtureError: Error {
        case failed
    }

    @Test func completedRunPropagatesReviewArtifactFailure() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("failure.m4b"),
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("failure-work"),
            voice: VoiceID("af_heart"),
            title: "Failure",
            author: "Tester",
            maxNewChaptersPerRun: nil)

        await #expect(throws: ReviewFixtureError.failed) {
            _ = try await HeadlessNarrationRunner().run(
                config,
                tts: StubEngine(),
                reviewGenerator: { _ in throw ReviewFixtureError.failed })
        }
    }

    @Test func failedReviewRerunRemovesPreviouslySuccessfulAcceptanceArtifacts() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("stale-review.m4b")
        let audit = tmp.appendingPathComponent("stale-review.pronunciation-audit.json")
        let reel = tmp.appendingPathComponent("stale-review.pronunciation-reel.m4b")
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("stale-review-work"),
            voice: VoiceID("af_heart"),
            title: "Stale Review",
            author: "Tester",
            maxNewChaptersPerRun: nil)

        _ = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            reviewGenerator: { request in
                try Data("first audit".utf8).write(to: request.auditURL)
                try Data("first reel".utf8).write(to: request.reelURL)
                return .generated(auditURL: request.auditURL, reelURL: request.reelURL)
            })
        #expect(FileManager.default.fileExists(atPath: audit.path))
        #expect(FileManager.default.fileExists(atPath: reel.path))

        await #expect(throws: ReviewFixtureError.failed) {
            _ = try await HeadlessNarrationRunner().run(
                config,
                tts: StubEngine(),
                reviewGenerator: { _ in throw ReviewFixtureError.failed })
        }

        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(!FileManager.default.fileExists(atPath: audit.path))
        #expect(!FileManager.default.fileExists(atPath: reel.path))
    }

    @Test func sourceMutationDuringEnginePreparationFailsBeforeFinalExport() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let chapterURL = epub.appending(path: "OEBPS/chap01.xhtml")
        let out = tmp.appendingPathComponent("mutated-source.m4b")
        let sidecar = tmp.appendingPathComponent("mutated-source.alignment.json")
        try Data("stale sidecar".utf8).write(to: sidecar)
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("mutated-source-work"),
            voice: VoiceID("af_heart"),
            title: "Mutated Source",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        config.generatePronunciationReview = false
        let engine = PrepareMutationEngine {
            let original = try String(contentsOf: chapterURL, encoding: .utf8)
            try original.replacing("enough words", with: "changed after import").write(
                to: chapterURL,
                atomically: true,
                encoding: .utf8)
        }

        do {
            _ = try await HeadlessNarrationRunner().run(config, tts: engine)
            Issue.record("A source changed after import unexpectedly reached final export")
        } catch {
            #expect(error.localizedDescription.contains("source changed"))
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func runLeaseRejectsSharedWorkOrOutputAndIgnoresStaleMetadata() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let realWork = tmp.appendingPathComponent("work", isDirectory: true)
        let aliasWork = tmp.appendingPathComponent("work-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realWork, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasWork,
            withDestinationURL: realWork)
        let base = NarrationRunConfig(
            epubURL: tmp.appendingPathComponent("book.epub"),
            outM4BURL: tmp.appendingPathComponent("book.m4b"),
            sidecarURL: tmp.appendingPathComponent("book.alignment.json"),
            workDir: realWork,
            voice: VoiceID("af_heart"),
            title: "Lease",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        var sameOutput = base
        sameOutput.workDir = tmp.appendingPathComponent("different-work")
        var sameWork = base
        sameWork.outM4BURL = tmp.appendingPathComponent("different.m4b")
        sameWork.sidecarURL = nil
        var aliasedWork = sameWork
        aliasedWork.workDir = aliasWork
        aliasedWork.outM4BURL = tmp.appendingPathComponent("alias-output.m4b")

        do {
            let lease = try HeadlessNarrationRunner.acquireRunLease(for: base)
            #expect(throws: Error.self) {
                _ = try HeadlessNarrationRunner.acquireRunLease(for: sameOutput)
            }
            #expect(throws: Error.self) {
                _ = try HeadlessNarrationRunner.acquireRunLease(for: sameWork)
            }
            #expect(throws: Error.self) {
                _ = try HeadlessNarrationRunner.acquireRunLease(for: aliasedWork)
            }
            withExtendedLifetime(lease) {}
        }

        for lockURL in HeadlessNarrationRunner.runLeaseLockURLs(for: base) {
            try Data("malformed stale metadata".utf8).write(to: lockURL)
        }
        let reacquired = try HeadlessNarrationRunner.acquireRunLease(for: base)
        withExtendedLifetime(reacquired) {}
    }

    @Test func directCLIFreshRunHoldsLeaseAcrossCleanupAndPreparation() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("contended-fresh.m4b")
        var firstConfig = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("first-work"),
            voice: VoiceID("af_heart"),
            title: "First",
            author: "Tester",
            maxNewChaptersPerRun: 1)
        firstConfig.generatePronunciationReview = false
        firstConfig.clearExistingCapturesBeforeRun = true
        var secondConfig = firstConfig
        secondConfig.workDir = tmp.appendingPathComponent("second-work")
        let gate = PrepareGate()
        let firstRun = Task {
            try await HeadlessNarrationRunner().run(
                firstConfig,
                tts: BlockingPrepareEngine(gate: gate))
        }
        await gate.waitUntilStarted()

        await #expect(throws: Error.self) {
            _ = try await HeadlessNarrationRunner().run(
                secondConfig,
                tts: StubEngine())
        }

        await gate.release()
        let partial = try await firstRun.value
        #expect(!partial.complete)
        #expect(partial.capturedThisRun == 1)
    }

    @Test func directCLIFreshPartialRunClearsAllPriorFinalArtifactsUnderRunnerOwnership()
        async throws
    {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("fresh-partial.m4b")
        let sidecar = tmp.appendingPathComponent("fresh-partial.alignment.json")
        let audit = tmp.appendingPathComponent("fresh-partial.pronunciation-audit.json")
        let reel = tmp.appendingPathComponent("fresh-partial.pronunciation-reel.m4b")
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("fresh-partial-work"),
            voice: VoiceID("af_heart"),
            title: "Fresh Partial",
            author: "Tester",
            maxNewChaptersPerRun: nil)

        _ = try await HeadlessNarrationRunner().run(
            config,
            tts: StubEngine(),
            reviewGenerator: { request in
                try Data("audit".utf8).write(to: request.auditURL)
                try Data("reel".utf8).write(to: request.reelURL)
                return .generated(auditURL: request.auditURL, reelURL: request.reelURL)
            })
        #expect(
            [out, sidecar, audit, reel].allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })

        config.maxNewChaptersPerRun = 1
        config.clearExistingCapturesBeforeRun = true
        let partial = try await HeadlessNarrationRunner().run(config, tts: StubEngine())

        #expect(!partial.complete)
        #expect(partial.capturedThisRun == 1)
        #expect(
            [out, sidecar, audit, reel].allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            })
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

    @Test func resumeRejectsChangedSourceBeforeUsingExistingCapture() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let workDir = tmp.appendingPathComponent("source-change-work")
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("source-change.m4b"),
            sidecarURL: nil,
            workDir: workDir,
            voice: VoiceID("af_heart"),
            title: "Source Identity",
            author: "Tester",
            maxNewChaptersPerRun: 1)
        let first = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        #expect(!first.complete)

        let chapterURL = epub.appending(path: "OEBPS/chap01.xhtml")
        let original = try String(contentsOf: chapterURL, encoding: .utf8)
        try original.replacing("enough words", with: "materially changed words").write(
            to: chapterURL,
            atomically: true,
            encoding: .utf8)

        do {
            _ = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
            Issue.record("Changed source unexpectedly reused an existing capture")
        } catch {
            #expect(error.localizedDescription.contains("capture identity"))
        }
        #expect(
            FileManager.default.fileExists(
                atPath: workDir.appendingPathComponent(".anchors-ch0.json").path))
    }

    @Test func completedResumeExportsOnlyAudioNamedByValidatedCaptures() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let workDir = tmp.appendingPathComponent("stale-audio-work")
        let out = tmp.appendingPathComponent("stale-audio.m4b")
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: nil,
            workDir: workDir,
            voice: VoiceID("af_heart"),
            title: "Exact Audio Identity",
            author: "Tester",
            maxNewChaptersPerRun: nil)
        let first = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        let capture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: Data(contentsOf: workDir.appendingPathComponent(".anchors-ch0.json")))
        let identity = try #require(capture.identity)
        let staleAudio = workDir.appendingPathComponent("runner-stale-ch0-extra.m4a")
        #expect(staleAudio.lastPathComponent != identity.audioFileName)
        let staleFixture = try await SilentAudioFixture.makeSilentM4A(seconds: 12)
        defer { try? FileManager.default.removeItem(at: staleFixture) }
        try FileManager.default.copyItem(at: staleFixture, to: staleAudio)

        let resumed = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        let exportedDuration = try await AVURLAsset(url: out).load(.duration).seconds

        #expect(first.complete && resumed.complete)
        #expect(resumed.capturedThisRun == 0)
        // AAC/container priming can shift the asset duration by a fraction of a
        // second. A 12-second sentinel makes the identity assertion direct: any
        // glob-based export that selected or appended the stale file would cross
        // this bound by many seconds.
        #expect(exportedDuration < 12)
        #expect(abs(exportedDuration - resumed.durationSeconds) < 0.25)
    }

    /// Pure sidecar assembly: per-chapter-relative anchor AND word times are both
    /// shifted by the running chapter offset into absolute book time.
    @Test func sidecarAssemblyConvertsWordTimesToAbsolute() {
        let captures = [
            HeadlessNarrationRunner.ChapterCapture(
                duration: 10,
                anchors: [
                    HeadlessNarrationRunner.ChapterCapture.Entry(
                        suffix: "s0-b0", time: 0.5,
                        words: [
                            .init(word: "Hello", start: 0.5, end: 0.9),
                            .init(word: "there", start: 0.9, end: 1.4),
                        ])
                ]),
            HeadlessNarrationRunner.ChapterCapture(
                duration: 20,
                anchors: [
                    HeadlessNarrationRunner.ChapterCapture.Entry(
                        suffix: "s1-b0", time: 1.0,
                        words: [.init(word: "Again", start: 1.0, end: 1.6)]),
                    HeadlessNarrationRunner.ChapterCapture.Entry(
                        suffix: "s1-b1", time: 3.0, words: nil),
                ]),
        ]

        let assembled = HeadlessNarrationRunner.assembleSidecarAnchors(
            captures: captures, includeWordTimings: true)

        #expect(assembled.anchors.map(\.timestamp) == [0.5, 11.0, 13.0])
        #expect(assembled.anchorsWithWords == 2)
        #expect(assembled.anchors[0].words?.map(\.start) == [0.5, 0.9])
        // Chapter 2 words are offset by chapter 1's 10s duration.
        #expect(
            assembled.anchors[1].words == [
                AlignmentSidecar.Anchor.Word(word: "Again", start: 11.0, end: 11.6)
            ])
        // An anchor captured without words stays word-less.
        #expect(assembled.anchors[2].words == nil)
    }

    /// The `--no-word-timings` opt-out strips words even from captures that
    /// recorded them (e.g. a resumed run whose earlier batches captured words).
    @Test func sidecarAssemblyCanOmitWordTimings() {
        let captures = [
            HeadlessNarrationRunner.ChapterCapture(
                duration: 5,
                anchors: [
                    HeadlessNarrationRunner.ChapterCapture.Entry(
                        suffix: "s0-b0", time: 0,
                        words: [.init(word: "Hi", start: 0, end: 0.3)])
                ])
        ]

        let assembled = HeadlessNarrationRunner.assembleSidecarAnchors(
            captures: captures, includeWordTimings: false)

        #expect(assembled.anchorsWithWords == 0)
        #expect(assembled.anchors.count == 1)
        #expect(assembled.anchors[0].words == nil)
    }

    /// A capture written by an older build (no `words` key) still decodes —
    /// resume compatibility for interrupted pre-word-export runs.
    @Test func legacyChapterCaptureWithoutWordsStillDecodes() throws {
        let legacy = Data(
            """
            {"duration": 4.5, "anchors": [{"suffix": "s0-b0", "time": 1.5}]}
            """.utf8)
        let capture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self, from: legacy)
        #expect(capture.duration == 4.5)
        #expect(capture.anchors.first?.suffix == "s0-b0")
        #expect(capture.anchors.first?.words == nil)
    }

    @Test func newChapterCaptureRoundTripsPronunciationEvidence() throws {
        let decision = auditDecision(
            chapterIndex: 4,
            chapterRange: .init(start: 1.25, end: 1.75))
        let diagnostics = [
            auditDiagnostic(reason: .spokenSurfaceMismatch, chapterIndex: 4),
            auditDiagnostic(reason: .incompleteRender, chapterIndex: 4),
        ]
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 3,
            anchors: [
                .init(suffix: "s4-b0", time: 0.5)
            ],
            identity: .init(
                schemaVersion: 1,
                captureSetID: "set-a",
                sourceFingerprint: "source-a",
                voice: VoiceID("af_heart"),
                renderVersion: 11,
                rendererIdentity: "echo.onnx-kokoro",
                normalizationMode: "deterministic",
                chapterIndex: 4,
                chapterContentSignature: "chapter-a",
                audioFileName: "runner-book-ch4-hchaptera-af_heart-v11.m4a",
                audioFileByteCount: 42),
            pronunciationEvidence: .init(
                decisions: [decision],
                diagnostics: diagnostics))

        let data = try JSONEncoder().encode(capture)
        let decoded = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: data)

        let evidence = try #require(decoded.pronunciationEvidence)
        #expect(decoded.identity == capture.identity)
        #expect(evidence.decisions == [decision])
        #expect(evidence.diagnostics == diagnostics)
    }

    @Test func capturePayloadAcceptsExactThenOverlappingBlockFallback() throws {
        let exact = auditDecision(
            chapterIndex: 0,
            chapterRange: .init(start: 2, end: 3),
            blockID: "blk-0",
            wordStart: 2)
        let fallback = auditDecision(
            chapterIndex: 0,
            chapterRange: .init(start: 0, end: 8),
            blockID: "blk-0",
            wordStart: 20,
            timingPrecision: .blockAnchorFallback)
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 10,
            anchors: [.init(suffix: "blk-0", time: 0)],
            pronunciationEvidence: .init(decisions: [exact, fallback], diagnostics: []))

        #expect(try HeadlessNarrationRunner.capturePayloadSHA256(capture).count == 64)
    }

    @Test func capturePayloadRejectsOutOfOrderTimingWithinSamePrecision() {
        let first = auditDecision(
            chapterIndex: 0,
            chapterRange: .init(start: 3, end: 4),
            blockID: "blk-0",
            wordStart: 2)
        let second = auditDecision(
            chapterIndex: 0,
            chapterRange: .init(start: 2, end: 3),
            blockID: "blk-0",
            wordStart: 20)
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 10,
            anchors: [.init(suffix: "blk-0", time: 0)],
            pronunciationEvidence: .init(decisions: [first, second], diagnostics: []))

        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.capturePayloadSHA256(capture)
        }
    }

    @Test func capturePayloadRejectsOutOfOrderBlockFallbackTiming() {
        let first = auditDecision(
            chapterIndex: 0,
            chapterRange: .init(start: 3, end: 8),
            blockID: "blk-0",
            wordStart: 2,
            timingPrecision: .blockAnchorFallback)
        let second = auditDecision(
            chapterIndex: 0,
            chapterRange: .init(start: 1, end: 2),
            blockID: "blk-1",
            wordStart: 20,
            timingPrecision: .blockAnchorFallback)
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 10,
            anchors: [
                .init(suffix: "blk-0", time: 0),
                .init(suffix: "blk-1", time: 1),
            ],
            pronunciationEvidence: .init(decisions: [first, second], diagnostics: []))

        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.capturePayloadSHA256(capture)
        }
    }

    @Test func injectedG2PInvalidOutputPreservesSealedEvidenceAndSpeaksOneDeterministicRescueChunk()
        throws
    {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let audioName = "invalid-g2p-ch0-af_heart-v21.m4a"
        let audioURL = workDir.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audioURL)
        let expected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "invalid-g2p-set",
            sourceFingerprint: "invalid-g2p-source",
            voice: VoiceID("af_heart"),
            renderVersion: NarrationFileNaming.renderVersion,
            rendererIdentity: NarrationFileNaming.rendererIdentity,
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "stable-cache-signature",
            audioFileName: audioName)
        let rawResult = KokoroG2P.Result(
            phonemes: "\u{0000}",
            fallbackHits: [.init(word: "ordinary", ipa: "\u{0000}")],
            tokenEvidence: [
                .init(
                    text: "ordinary",
                    selectedPhonemes: "\u{0000}",
                    lexicalTag: nil,
                    rating: 1,
                    displayCharacterRange: 0..<8,
                    phonemeCharacterRange: 0..<1,
                    usedFallback: true)
            ],
            pronunciationEvidenceValidation: .matched)
        let planner = try PronunciationPlanner(g2pResult: { _, _ in rawResult })
        let renderPlan = try NarrationRenderPlanner.make(
            blocks: [narrationBlock(id: "invalid-g2p", text: "ordinary")],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            pronunciationPlanner: planner)
        let plannedBlock = try #require(renderPlan.blocks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)

        let rescueChunk = try #require(plannedBlock.synthesisChunks.first)
        #expect(plannedBlock.synthesisChunks.count == 1)
        #expect(rescueChunk.displayText == "ordinary")
        #expect(rescueChunk.g2pInputText == "o r d i n a r y")
        #expect(!rescueChunk.phonemes.isEmpty)
        #expect(!rescueChunk.phonemeIDs.isEmpty)
        #expect(rescueChunk.wordCount == 1)
        #expect(
            plannedBlock.synthesisChunks.flatMap {
                WordTokenizer.words(in: $0.displayText).map(String.init)
            } == ["ordinary"])
        #expect(decision.selectedIPA == "\u{0000}")
        #expect(decision.source == .fallback)
        #expect(decision.ruleID == "g2p.fallback.ordinary")
        #expect(decision.kokoroTokenIDs.isEmpty)
        #expect(decision.advisoryEvidence?.category == .lexical)
        #expect(decision.advisoryEvidence?.selectedAuthority == .uncertain)
        #expect(decision.advisoryEvidence?.selectionReason == .deterministicFallback)
        #expect(
            plannedBlock.pronunciationDecisionDiagnostics.map(\.reason) == [
                .decisionEvidenceMismatch
            ])
        #expect(plannedBlock.pronunciationDecisionDiagnostics.first?.chunkIndex == 0)
        let capturedDecision = decision.attachingRenderTiming(
            chapterIndex: 0,
            chapterRelativeAudioRange: nil,
            timingPrecision: nil)
        #expect(
            PronunciationListeningReel.entries(
                decisions: [capturedDecision],
                audiobookURL: audioURL,
                sourceDuration: CMTime(seconds: 1, preferredTimescale: 600)
            ).isEmpty)

        let sealed = try HeadlessNarrationRunner.sealedCapture(
            .init(
                duration: 1,
                anchors: [],
                pronunciationEvidence: .init(
                    decisions: [capturedDecision],
                    diagnostics: plannedBlock.pronunciationDecisionDiagnostics.map {
                        $0.attachingChapter(0)
                    })),
            audioURL: audioURL,
            expected: expected,
            workDir: workDir)
        _ = try HeadlessNarrationRunner.validateCapture(
            sealed,
            chapterIndex: 0,
            expected: expected,
            workDir: workDir)

        let assembled = HeadlessNarrationRunner.assemblePronunciationEvidence(
            indexedCaptures: [.init(chapterIndex: 0, capture: sealed)])
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: assembled.coverage,
            legacyChapterIndexes: assembled.legacyChapterIndexes,
            audiobookURL: URL(fileURLWithPath: "/tmp/invalid-g2p.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: assembled.decisions,
            diagnostics: assembled.diagnostics)

        #expect(manifest.schemaVersion == PronunciationAuditManifest.currentSchemaVersion)
        #expect(manifest.coverage == .incompleteEvidence)
        #expect(sealed.identity?.chapterContentSignature == "stable-cache-signature")
        #expect(
            try JSONDecoder().decode(
                PronunciationAuditManifest.self,
                from: manifest.encoded()) == manifest)
    }

    @Test func capturePayloadStillRejectsEmptyDecisionWithNonLexicalAdvisory() throws {
        let malformed = PronunciationAuditDecision(
            blockID: "malformed",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "ordinary",
            sourceWord: "ordinary",
            sourceContext: "ordinary",
            selectedIPA: "",
            kokoroTokenIDs: [],
            source: .monitoredLexicon,
            ruleID: "g2p.lexicon.ordinary",
            rationale: "Malformed fixture.",
            advisoryEvidence: PronunciationAdvisoryEvidence(
                category: .contextual,
                selectedAuthority: .trusted,
                selectedCandidateID: nil,
                alternatives: [],
                selectionReason: .trustedLexicon,
                overrideSuppressedAutomation: false,
                policyVersion: "fixture-v1"))
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 1,
            anchors: [],
            pronunciationEvidence: .init(decisions: [malformed], diagnostics: []))

        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.capturePayloadSHA256(capture)
        }
    }

    @Test func capturePayloadRejectsOccurrenceOverrideMasqueradingAsInvalidG2P() throws {
        let malformed = PronunciationAuditDecision(
            blockID: "malformed-override",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "ordinary",
            sourceWord: "ordinary",
            sourceContext: "ordinary",
            selectedIPA: "\u{0000}",
            kokoroTokenIDs: [],
            source: .occurrenceOverride,
            ruleID: "override.occurrence.ordinary",
            rationale: "Malformed fixture.",
            advisoryEvidence: PronunciationAdvisoryEvidence(
                category: .lexical,
                selectedAuthority: .trusted,
                selectedCandidateID: nil,
                alternatives: [],
                selectionReason: .occurrenceOverride,
                overrideSuppressedAutomation: false,
                policyVersion: "fixture-v1"))
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 1,
            anchors: [],
            pronunciationEvidence: .init(decisions: [malformed], diagnostics: []))

        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.capturePayloadSHA256(capture)
        }
    }

    @Test func capturePayloadRejectsInvalidG2PWithWrongSourceRuleRelationship() throws {
        let malformed = PronunciationAuditDecision(
            blockID: "malformed-rule",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "ordinary",
            sourceWord: "ordinary",
            sourceContext: "ordinary",
            selectedIPA: "\u{0000}",
            kokoroTokenIDs: [],
            source: .monitoredLexicon,
            ruleID: "g2p.fallback.ordinary",
            rationale: "Malformed fixture.",
            advisoryEvidence: PronunciationAdvisoryEvidence(
                category: .lexical,
                selectedAuthority: .trusted,
                selectedCandidateID: nil,
                alternatives: [],
                selectionReason: .trustedLexicon,
                overrideSuppressedAutomation: false,
                policyVersion: "fixture-v1"))
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 1,
            anchors: [],
            pronunciationEvidence: .init(decisions: [malformed], diagnostics: []))

        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.capturePayloadSHA256(capture)
        }
    }

    @Test func captureValidationFailsClosedAcrossRendererAndSourceIdentityMismatches() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let audioName = "runner-book-ch2-hsig-af_heart-v11.m4a"
        let audio = tmp.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audio)
        let expected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "set-a",
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            chapterIndex: 2,
            chapterContentSignature: "sig",
            audioFileName: audioName)
        func capture(_ identity: HeadlessNarrationRunner.ChapterCapture.Identity)
            -> HeadlessNarrationRunner.ChapterCapture
        {
            .init(
                duration: 1,
                anchors: [],
                identity: identity,
                pronunciationEvidence: .init(decisions: [], diagnostics: []))
        }
        let validCapture = try HeadlessNarrationRunner.sealedCapture(
            .init(
                duration: 1,
                anchors: [],
                pronunciationEvidence: .init(decisions: [], diagnostics: [])),
            audioURL: audio,
            expected: expected,
            workDir: tmp)
        let valid = try #require(validCapture.identity)

        #expect(
            try HeadlessNarrationRunner.validateCapture(
                capture(valid), chapterIndex: 2, expected: expected, workDir: tmp)
                == audio)
        let mismatches: [HeadlessNarrationRunner.ChapterCapture.Identity] = [
            .init(
                schemaVersion: 2, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: "set-b",
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: "source-b", voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: VoiceID("am_michael"),
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: 12, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: "different-renderer",
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: "fm-auto-v1", chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: 3,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: "other-signature",
                audioFileName: valid.audioFileName, audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: "other.m4a", audioFileByteCount: valid.audioFileByteCount),
            .init(
                schemaVersion: valid.schemaVersion, captureSetID: valid.captureSetID,
                sourceFingerprint: valid.sourceFingerprint, voice: valid.voice,
                renderVersion: valid.renderVersion, rendererIdentity: valid.rendererIdentity,
                normalizationMode: valid.normalizationMode, chapterIndex: valid.chapterIndex,
                chapterContentSignature: valid.chapterContentSignature,
                audioFileName: valid.audioFileName, audioFileByteCount: 5),
        ]
        for mismatch in mismatches {
            #expect(throws: Error.self) {
                _ = try HeadlessNarrationRunner.validateCapture(
                    capture(mismatch), chapterIndex: 2, expected: expected, workDir: tmp)
            }
        }
    }

    @Test func sealingCaptureAcceptsFreshWorkDirectoryURLWithoutDirectoryHint() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let workPath = parent.appendingPathComponent("work").path
        let workDir = URL(fileURLWithPath: workPath)
        #expect(!FileManager.default.fileExists(atPath: workPath))
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let audioName = "runner-book-ch0-hsig-am_michael-v12.m4a"
        let audio = workDir.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audio)
        let expected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "set-a",
            sourceFingerprint: "source-a",
            voice: VoiceID("am_michael"),
            renderVersion: 12,
            rendererIdentity: "echo.kokoro-82m.onnx.misaki-us.v1",
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "sig",
            audioFileName: audioName)

        let capture = try HeadlessNarrationRunner.sealedCapture(
            .init(
                duration: 1,
                anchors: [],
                pronunciationEvidence: .init(decisions: [], diagnostics: [])),
            audioURL: audio,
            expected: expected,
            workDir: workDir)

        #expect(capture.identity?.audioFileName == audioName)
        #expect(
            try HeadlessNarrationRunner.validateCapture(
                capture,
                chapterIndex: 0,
                expected: expected,
                workDir: workDir) == audio)
    }

    @Test func sealingCaptureRejectsAudioFromSiblingDirectory() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let workDir = parent.appendingPathComponent("work", isDirectory: true)
        let siblingDir = parent.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let audioName = "runner-book-ch0-hsig-am_michael-v12.m4a"
        let audio = siblingDir.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audio)
        let expected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "set-a",
            sourceFingerprint: "source-a",
            voice: VoiceID("am_michael"),
            renderVersion: 12,
            rendererIdentity: "echo.kokoro-82m.onnx.misaki-us.v1",
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "sig",
            audioFileName: audioName)

        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.sealedCapture(
                .init(
                    duration: 1,
                    anchors: [],
                    pronunciationEvidence: .init(decisions: [], diagnostics: [])),
                audioURL: audio,
                expected: expected,
                workDir: workDir)
        }
    }

    @Test func captureValidationRejectsSameByteCountAudioMutation() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let audioName = "runner-book-ch2-hsig-af_heart-v11.m4a"
        let audio = tmp.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audio)
        let expected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "set-a",
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            chapterIndex: 2,
            chapterContentSignature: "sig",
            audioFileName: audioName)
        let payload = HeadlessNarrationRunner.ChapterCapture(
            duration: 1,
            anchors: [],
            pronunciationEvidence: .init(decisions: [], diagnostics: []))
        let capture = try HeadlessNarrationRunner.sealedCapture(
            payload,
            audioURL: audio,
            expected: expected,
            workDir: tmp)

        _ = try HeadlessNarrationRunner.validateCapture(
            capture, chapterIndex: 2, expected: expected, workDir: tmp)
        try Data([4, 3, 2, 1]).write(to: audio)

        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.validateCapture(
                capture, chapterIndex: 2, expected: expected, workDir: tmp)
        }
    }

    @Test func captureValidationRejectsMarkerPayloadMutationWithUnchangedAudio() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let audioName = "runner-book-ch2-hsig-af_heart-v11.m4a"
        let audio = tmp.appendingPathComponent(audioName)
        try Data([1, 2, 3, 4]).write(to: audio)
        let expected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "set-a",
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            chapterIndex: 2,
            chapterContentSignature: "sig",
            audioFileName: audioName)
        let decision = auditDecision(
            chapterIndex: 2,
            chapterRange: .init(start: 0.4, end: 0.8))
        let payload = HeadlessNarrationRunner.ChapterCapture(
            duration: 2,
            anchors: [
                .init(
                    suffix: "s2-b0",
                    time: 0.25,
                    words: [.init(word: "verified", start: 0.4, end: 0.8)])
            ],
            pronunciationEvidence: .init(decisions: [decision], diagnostics: []))
        let sealed = try HeadlessNarrationRunner.sealedCapture(
            payload,
            audioURL: audio,
            expected: expected,
            workDir: tmp)
        _ = try HeadlessNarrationRunner.validateCapture(
            sealed, chapterIndex: 2, expected: expected, workDir: tmp)

        let changedDecision = PronunciationAuditDecision(
            blockID: decision.blockID,
            wordStart: decision.wordStart,
            wordEnd: decision.wordEnd,
            normalizedWord: decision.normalizedWord,
            sourceWord: decision.sourceWord,
            sourceContext: decision.sourceContext,
            selectedIPA: "tampered-ipa",
            kokoroTokenIDs: [999],
            source: decision.source,
            ruleID: decision.ruleID,
            rationale: decision.rationale,
            chapterIndex: decision.chapterIndex,
            chapterRelativeAudioRange: decision.chapterRelativeAudioRange,
            bookRelativeAudioRange: decision.bookRelativeAudioRange,
            timingPrecision: decision.timingPrecision)
        let evidenceTampered = HeadlessNarrationRunner.ChapterCapture(
            duration: sealed.duration,
            anchors: sealed.anchors,
            identity: sealed.identity,
            pronunciationEvidence: .init(decisions: [changedDecision], diagnostics: []))
        let timingTampered = HeadlessNarrationRunner.ChapterCapture(
            duration: 3,
            anchors: [.init(suffix: "s2-b0", time: 0.5)],
            identity: sealed.identity,
            pronunciationEvidence: sealed.pronunciationEvidence)

        for tampered in [evidenceTampered, timingTampered] {
            #expect(throws: Error.self) {
                _ = try HeadlessNarrationRunner.validateCapture(
                    tampered, chapterIndex: 2, expected: expected, workDir: tmp)
            }
        }
    }

    @Test func capturePayloadRejectsNonFiniteOrOutOfBoundsTiming() throws {
        let invalidCaptures = [
            HeadlessNarrationRunner.ChapterCapture(duration: .nan, anchors: []),
            HeadlessNarrationRunner.ChapterCapture(
                duration: 1,
                anchors: [.init(suffix: "s0-b0", time: 2)]),
            HeadlessNarrationRunner.ChapterCapture(
                duration: 1,
                anchors: [
                    .init(
                        suffix: "s0-b0",
                        time: 0,
                        words: [.init(word: "bad", start: 0.8, end: 0.2)])
                ]),
        ]

        for capture in invalidCaptures {
            #expect(throws: Error.self) {
                _ = try HeadlessNarrationRunner.capturePayloadSHA256(capture)
            }
        }
    }

    @Test func captureSetIdentityChangesForSourceChapterOrderAndCount() {
        let baseline = HeadlessNarrationRunner.captureSetID(
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            orderedChapterSignatures: ["0:a", "1:b"])
        let changedSource = HeadlessNarrationRunner.captureSetID(
            sourceFingerprint: "source-b",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            orderedChapterSignatures: ["0:a", "1:b"])
        let reordered = HeadlessNarrationRunner.captureSetID(
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            orderedChapterSignatures: ["1:b", "0:a"])
        let changedCount = HeadlessNarrationRunner.captureSetID(
            sourceFingerprint: "source-a",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            orderedChapterSignatures: ["0:a"])

        #expect(Set([baseline, changedSource, reordered, changedCount]).count == 4)
    }

    @Test func legacyCaptureResumesOnlyWithExactCurrentlyExpectedAudioFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let expectedName = "runner-book-ch0-hsig-af_heart-v11.m4a"
        let expected = HeadlessNarrationRunner.ExpectedChapterCaptureIdentity(
            schemaVersion: 1,
            captureSetID: "set",
            sourceFingerprint: "source",
            voice: VoiceID("af_heart"),
            renderVersion: 11,
            rendererIdentity: "echo.onnx-kokoro",
            normalizationMode: "deterministic",
            chapterIndex: 0,
            chapterContentSignature: "sig",
            audioFileName: expectedName)
        let legacy = HeadlessNarrationRunner.ChapterCapture(duration: 1, anchors: [])
        let expectedAudio = tmp.appendingPathComponent(expectedName)
        try Data([1]).write(to: expectedAudio)

        #expect(
            try HeadlessNarrationRunner.validateCapture(
                legacy, chapterIndex: 0, expected: expected, workDir: tmp)
                == expectedAudio)

        try FileManager.default.removeItem(at: expectedAudio)
        try Data([1]).write(to: tmp.appendingPathComponent("runner-stale-ch0.m4a"))
        #expect(throws: Error.self) {
            _ = try HeadlessNarrationRunner.validateCapture(
                legacy, chapterIndex: 0, expected: expected, workDir: tmp)
        }
    }

    @Test func legacyChapterCaptureWithoutPronunciationEvidenceStillDecodes() throws {
        let legacy = Data(
            """
            {"duration": 4.5, "anchors": [{"suffix": "s0-b0", "time": 1.5}]}
            """.utf8)

        let capture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: legacy)

        #expect(capture.pronunciationEvidence == nil)
    }

    @Test func newEmptyChapterCaptureEncodesNonNilPronunciationEvidenceEnvelope() throws {
        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 0,
            anchors: [],
            pronunciationEvidence: .init(decisions: [], diagnostics: []))

        let data = try JSONEncoder().encode(capture)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: data)

        #expect(object.keys.contains("pronunciationEvidence"))
        #expect(decoded.pronunciationEvidence?.decisions.isEmpty == true)
        #expect(decoded.pronunciationEvidence?.diagnostics.isEmpty == true)
    }

    @Test func pronunciationEvidenceAssemblyMakesRangesBookRelativeAndKeepsDiagnosticsExplicit()
        throws
    {
        let firstDecision = auditDecision(
            chapterIndex: 2,
            chapterRange: .init(start: 1, end: 1.5))
        let secondDecision = auditDecision(
            chapterIndex: 5,
            chapterRange: .init(start: 0.25, end: 0.75))
        let firstDiagnostic = auditDiagnostic(reason: .incompleteRender, chapterIndex: 2)
        let secondDiagnostic = auditDiagnostic(reason: .spokenSurfaceMismatch, chapterIndex: 5)
        let first = HeadlessNarrationRunner.ChapterCapture(
            duration: 4,
            anchors: [.init(suffix: "s2-b0", time: 1)],
            identity: captureIdentity(chapterIndex: 2),
            pronunciationEvidence: .init(
                decisions: [firstDecision],
                diagnostics: [firstDiagnostic]))
        let second = HeadlessNarrationRunner.ChapterCapture(
            duration: 6,
            anchors: [.init(suffix: "s5-b0", time: 0.25)],
            identity: captureIdentity(chapterIndex: 5),
            pronunciationEvidence: .init(
                decisions: [secondDecision],
                diagnostics: [secondDiagnostic]))

        // Deliberately supply reverse order: the pure assembly owns stable
        // chapter reading order rather than trusting task completion order.
        let assembled = HeadlessNarrationRunner.assemblePronunciationEvidence(
            indexedCaptures: [
                .init(chapterIndex: 5, capture: second),
                .init(chapterIndex: 2, capture: first),
            ])
        let sidecar = HeadlessNarrationRunner.assembleSidecarAnchors(
            captures: [first, second],
            includeWordTimings: true)

        #expect(assembled.coverage == .complete)
        #expect(assembled.legacyChapterIndexes.isEmpty)
        #expect(assembled.totalDuration == 10)
        #expect(assembled.decisions.map(\.chapterIndex) == [2, 5])
        #expect(assembled.decisions[0].chapterRelativeAudioRange == .init(start: 1, end: 1.5))
        #expect(assembled.decisions[0].bookRelativeAudioRange == .init(start: 1, end: 1.5))
        #expect(
            assembled.decisions[1].chapterRelativeAudioRange == .init(start: 0.25, end: 0.75))
        #expect(assembled.decisions[1].bookRelativeAudioRange == .init(start: 4.25, end: 4.75))
        #expect(
            assembled.decisions[1].bookRelativeAudioRange?.start == sidecar.anchors[1].timestamp)
        #expect(assembled.diagnostics == [firstDiagnostic, secondDiagnostic])
        #expect(assembled.diagnostics.allSatisfy { $0.chapterIndex != nil })
    }

    @Test func pronunciationEvidenceAssemblyReportsExactLegacyResumeChapters() {
        let legacyFirst = HeadlessNarrationRunner.ChapterCapture(duration: 2, anchors: [])
        let current = HeadlessNarrationRunner.ChapterCapture(
            duration: 3,
            anchors: [],
            identity: captureIdentity(chapterIndex: 3),
            pronunciationEvidence: .init(decisions: [], diagnostics: []))
        let legacyLast = HeadlessNarrationRunner.ChapterCapture(duration: 5, anchors: [])

        let assembled = HeadlessNarrationRunner.assemblePronunciationEvidence(
            indexedCaptures: [
                .init(chapterIndex: 7, capture: legacyLast),
                .init(chapterIndex: 1, capture: legacyFirst),
                .init(chapterIndex: 3, capture: current),
            ])

        #expect(assembled.coverage == .incompleteLegacyCapture)
        #expect(assembled.legacyChapterIndexes == [1, 7])
        #expect(assembled.decisions.isEmpty)
        #expect(assembled.diagnostics.isEmpty)
        #expect(assembled.totalDuration == 10)
    }

    @Test func completedRunPersistsEvidenceFromExactRenderReceipt() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let chapterURL = epub.appending(path: "OEBPS/chap01.xhtml")
        let original = try String(contentsOf: chapterURL, encoding: .utf8)
        try original.replacing(
            "It contains enough words",
            with: "It contains the verified result and enough words"
        ).write(to: chapterURL, atomically: true, encoding: .utf8)
        let workDir = tmp.appendingPathComponent("receipt-work", isDirectory: true)
        let config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: tmp.appendingPathComponent("receipt.m4b"),
            sidecarURL: nil,
            workDir: workDir,
            voice: VoiceID("af_heart"),
            title: "Receipt Fixture",
            author: "Tester",
            maxNewChaptersPerRun: nil)

        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: WordTimedStubEngine())
        let capture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: Data(contentsOf: workDir.appendingPathComponent(".anchors-ch0.json")))
        let evidence = try #require(capture.pronunciationEvidence)
        let secondCapture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: Data(contentsOf: workDir.appendingPathComponent(".anchors-ch1.json")))
        let secondEvidence = try #require(secondCapture.pronunciationEvidence)
        let verified = try #require(
            evidence.decisions.first { $0.normalizedWord == "verified" })
        let resume = try #require(
            secondEvidence.decisions.first { $0.normalizedWord == "resume" })

        #expect(result.complete)
        #expect(verified.chapterIndex == 0)
        #expect(verified.chapterRelativeAudioRange != nil)
        #expect(verified.bookRelativeAudioRange == nil)
        #expect(resume.chapterIndex == 1)
        #expect(resume.chapterRelativeAudioRange != nil)
        #expect(resume.bookRelativeAudioRange == nil)
    }

    /// End-to-end: an engine with a duration head produces a sidecar whose
    /// anchors carry per-word times consistent with the anchor timestamps and
    /// the blocks' whitespace tokenization, and the CLI progress event reports
    /// how many anchors carried words.
    @Test func sourceBoundMixedVoicePlanResumesToOneChapteredM4BAndNormalSidecar() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let oebps = expanded.appendingPathComponent("OEBPS", isDirectory: true)
        try """
        <html><body><h1>North</h1><p>Narrator opens the northern road.</p><p>Mara sees a light ahead.</p><p>Jon answers from the bridge.</p></body></html>
        """.write(
            to: oebps.appendingPathComponent("chap01.xhtml"),
            atomically: true,
            encoding: .utf8)
        try """
        <html><body><h1>South</h1><p>Narrator follows the southern road.</p><p>Mara names the harbor.</p><p>Jon closes the gate.</p></body></html>
        """.write(
            to: oebps.appendingPathComponent("chap02.xhtml"),
            atomically: true,
            encoding: .utf8)

        let epub = tmp.appendingPathComponent("story.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let planURL = tmp.appendingPathComponent("story.voice-plan.json")
        let sourceSHA = try HeadlessNarrationRunner.fileSHA256(at: epub)
        try Data(
            """
            {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"am_michael"}],"assignments":[]}
            """.utf8).write(to: planURL)
        let seedResolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epub, voicePlanURL: planURL)
        let parsed = try parseEPUBBlocks(audiobookID: "story", epubURL: expanded).blocks
        let portableIDByText = Dictionary(uniqueKeysWithValues: parsed.compactMap { block in
            block.text.map { ($0, AlignmentSidecar.portableSuffix(of: block.id)) }
        })
        let narratorTexts = ["Narrator opens the northern road.", "Narrator follows the southern road."]
        let povTexts = ["Mara sees a light ahead.", "Mara names the harbor."]
        let dialogueTexts = ["Jon answers from the bridge.", "Jon closes the gate."]
        let povIDs = try povTexts.map { text in
            guard let id = portableIDByText[text] else { throw CocoaError(.fileNoSuchFile) }
            return id
        }
        let dialogueIDs = try dialogueTexts.map { text in
            guard let id = portableIDByText[text] else { throw CocoaError(.fileNoSuchFile) }
            return id
        }
        #expect(!povIDs.isEmpty)
        #expect(!dialogueIDs.isEmpty)
        func jsonArray(_ ids: [String]) -> String {
            ids.map { "\"\($0)\"" }.joined(separator: ",")
        }
        try Data(
            """
            {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"am_michael"},{"id":"pov","voiceID":"bf_emma"},{"id":"dialogue","voiceID":"am_fenrir"}],"assignments":[{"speakerID":"pov","blocks":[\(jsonArray(povIDs))]},{"speakerID":"dialogue","blocks":[\(jsonArray(dialogueIDs))]}]}
            """.utf8).write(to: planURL)
        let resolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epub, voicePlanURL: planURL)
        #expect(resolved.blocks.map(\.voiceID).contains(VoiceID("am_michael")))
        #expect(resolved.blocks.map(\.voiceID).contains(VoiceID("bf_emma")))
        #expect(resolved.blocks.map(\.voiceID).contains(VoiceID("am_fenrir")))

        let output = tmp.appendingPathComponent("story.m4b")
        let sidecar = tmp.appendingPathComponent("story.alignment.json")
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: output,
            sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("story-work"),
            voice: nil,
            voicePlanURL: planURL,
            title: "Story",
            author: "Echo",
            maxNewChaptersPerRun: 1)
        config.generatePronunciationReview = false
        let recorder = WordTimedVoiceRecorder()

        let partial = try await HeadlessNarrationRunner().run(
            config,
            tts: WordTimedVoiceRecordingEngine(recorder: recorder))
        #expect(!partial.complete)
        #expect(partial.capturedThisRun == 1)

        config.maxNewChaptersPerRun = nil
        let result = try await HeadlessNarrationRunner().run(
            config,
            tts: WordTimedVoiceRecordingEngine(recorder: recorder))

        #expect(result.complete)
        #expect(result.chapters == 2)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        let recorded = await recorder.snapshot()
        let expectedVoicesByText = Dictionary(uniqueKeysWithValues: narratorTexts.map {
            ($0, VoiceID("am_michael"))
        } + povTexts.map { ($0, VoiceID("bf_emma")) }
            + dialogueTexts.map { ($0, VoiceID("am_fenrir")) })
        let sourceBoundCalls = recorded.filter { expectedVoicesByText[$0.text] != nil }
        #expect(sourceBoundCalls.count == expectedVoicesByText.count)
        #expect(sourceBoundCalls.allSatisfy { expectedVoicesByText[$0.text] == $0.voice })

        let asset = AVURLAsset(url: output)
        let locales = try await asset.load(.availableChapterLocales)
        let chapters = try await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: locales.map(\.identifier))
        #expect(chapters.count == 2)

        let deliveryFiles = try FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
        #expect(deliveryFiles.filter { $0.pathExtension == "m4b" } == [output])
        #expect(deliveryFiles.filter { $0.lastPathComponent.hasSuffix(".alignment.json") } == [sidecar])
        let forbiddenDeliveryTokens = ["narrator", "pov", "dialogue", "am_michael", "bf_emma", "am_fenrir"]
        #expect(deliveryFiles.allSatisfy { file in
            forbiddenDeliveryTokens.allSatisfy { !file.lastPathComponent.contains($0) }
        })

        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecar))
        #expect(anchors.count == resolved.blocks.count)
        #expect(zip(anchors, anchors.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        let words = anchors.compactMap(\.words).flatMap { $0 }
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.start < $0.end })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start < $1.start })
        let sidecarText = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        #expect(!sidecarText.contains("speakerID"))
        #expect(!sidecarText.contains("voiceID"))

        let workFiles = try FileManager.default.contentsOfDirectory(
            at: config.workDir, includingPropertiesForKeys: nil)
        let chapterM4As = workFiles.filter { $0.pathExtension == "m4a" }
        let markersOrState = workFiles.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(".anchors-ch") || name.contains("state")
        }
        #expect(workFiles.count == chapterM4As.count + markersOrState.count)
        #expect(chapterM4As.count == 2)
        #expect(markersOrState.count == 2)
        #expect(chapterM4As.allSatisfy { file in
            forbiddenDeliveryTokens.allSatisfy { !file.lastPathComponent.contains($0) }
        })

        var legacyConfig = config
        legacyConfig.outM4BURL = tmp.appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("uniform.m4b")
        legacyConfig.sidecarURL = tmp.appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("uniform.alignment.json")
        legacyConfig.workDir = tmp.appendingPathComponent("legacy-work", isDirectory: true)
        legacyConfig.voicePlanURL = nil
        legacyConfig.voice = VoiceID("af_heart")
        let legacy = try await HeadlessNarrationRunner().run(
            legacyConfig,
            tts: WordTimedStubEngine())
        #expect(legacy.complete)
        #expect(FileManager.default.fileExists(atPath: legacyConfig.outM4BURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyConfig.sidecarURL!.path))
    }

    @Test func planDigestSkipsVisibleNonSpeakableBlocksAndResumesToCompletion() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expanded = try TestEPUBFixture.twoChapters(in: tmp)
        let oebps = expanded.appendingPathComponent("OEBPS", isDirectory: true)
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
        <body><section>
        <h1>Digest Fixture</h1>
        <p>Speakable prose before the image.</p>
        <img src="no-alt.png"/>
        <p></p>
        <p>   </p>
        <p>Speakable prose after the image.</p>
        </section></body></html>
        """.write(
            to: oebps.appendingPathComponent("chap01.xhtml"),
            atomically: true,
            encoding: .utf8)
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9aRX0AAAAASUVORK5CYII=")!
            .write(to: oebps.appendingPathComponent("no-alt.png"))
        let opfURL = oebps.appendingPathComponent("content.opf")
        var opf = try String(contentsOf: opfURL, encoding: .utf8)
        opf = opf.replacingOccurrences(
            of: "<item id=\"chap01\"",
            with: "<item id=\"no-alt\" href=\"no-alt.png\" media-type=\"image/png\"/>\\n<item id=\"chap01\"")
        try opf.write(to: opfURL, atomically: true, encoding: .utf8)

        let epub = tmp.appendingPathComponent("digest.epub")
        try FileManager.default.zipItem(at: expanded, to: epub, shouldKeepParent: false)
        let sourceSHA = try HeadlessNarrationRunner.fileSHA256(at: epub)
        let planURL = tmp.appendingPathComponent("digest.voice-plan.json")
        try Data(
            """
            {"schemaVersion":1,"source":{"epubSHA256":"\(sourceSHA)"},"defaultSpeakerID":"narrator","speakers":[{"id":"narrator","voiceID":"af_heart"}],"assignments":[]}
            """.utf8).write(to: planURL)

        let resolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epub, voicePlanURL: planURL)
        let parsedEPUB = try parseEPUBBlocks(audiobookID: "digest", epubURL: expanded)
        var blocks = parsedEPUB.blocks
        _ = try EPUBImportService.resolveTOCEntriesAndAssignChapterIndices(
            parse: parsedEPUB,
            audiobookID: "digest",
            assignsStructureChapterIndices: true,
            blocks: &blocks)
        let firstChapter = try #require(NarrationChapterPlanner.plan(from: blocks).first)
        let firstChapterIDs = firstChapter.blocks.map { AlignmentSidecar.portableSuffix(of: $0.id) }
        let noAltImage = try #require(firstChapter.blocks.first(where: {
            $0.blockKind == EPubBlockRecord.Kind.image.rawValue && $0.text == nil && !$0.isHidden
        }))
        let noAltImageID = AlignmentSidecar.portableSuffix(of: noAltImage.id)
        #expect(firstChapterIDs.contains(noAltImageID))
        #expect(!resolved.blocks.map(\.blockID).contains(noAltImageID))
        let resolvedFirstChapterIDs = firstChapterIDs.filter { id in
            resolved.blocks.contains(where: { $0.blockID == id })
        }
        #expect(resolvedFirstChapterIDs.count < firstChapterIDs.count)

        let output = tmp.appendingPathComponent("digest.m4b")
        let sidecar = tmp.appendingPathComponent("digest.alignment.json")
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: output,
            sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("digest-work"),
            voice: nil,
            voicePlanURL: planURL,
            title: "Digest Fixture",
            author: "Echo",
            maxNewChaptersPerRun: 1)
        config.generatePronunciationReview = false

        let first = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        #expect(!first.complete)
        #expect(first.capturedThisRun == 1)
        let firstCapture = try JSONDecoder().decode(
            HeadlessNarrationRunner.ChapterCapture.self,
            from: Data(contentsOf: config.workDir.appendingPathComponent(".anchors-ch0.json")))
        let firstIdentity = try #require(firstCapture.identity)
        #expect(firstIdentity.schemaVersion == HeadlessNarrationRunner.planChapterCaptureSchemaVersion)
        #expect(firstIdentity.chapterVoicePlanSHA256 == resolved.chapterDigest(blockIDs: firstChapterIDs))
        #expect(firstIdentity.chapterVoicePlanSHA256 == resolved.chapterDigest(blockIDs: resolvedFirstChapterIDs))

        config.maxNewChaptersPerRun = nil
        let completed = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        #expect(completed.complete)
        #expect(completed.capturedThisRun == 1)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        let resumed = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        #expect(resumed.complete)
        #expect(resumed.capturedThisRun == 0)
    }

    @Test func sidecarCarriesWordTimingsFromSynthesis() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("worded.m4b")
        let sidecar = tmp.appendingPathComponent("worded.alignment.json")
        let cfg = NarrationRunConfig(
            epubURL: epub, outM4BURL: out, sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("worded-work"), voice: VoiceID("af_heart"),
            title: "Fixture", author: "Tester", maxNewChaptersPerRun: nil)

        var reportedWordAnchors: Int?
        let result = try await HeadlessNarrationRunner().run(
            cfg,
            tts: WordTimedStubEngine(),
            progress: { progress in
                if case .wroteSidecar(_, let anchorsWithWords) = progress {
                    reportedWordAnchors = anchorsWithWords
                }
            })
        #expect(result.complete)

        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecar))
        let worded = anchors.filter { $0.words != nil }
        #expect(!worded.isEmpty)
        #expect(reportedWordAnchors == worded.count)
        for anchor in worded {
            let words = anchor.words!
            #expect(!words.isEmpty)
            // Absolute timebase: words start at/after their anchor, in order.
            #expect(words[0].start >= anchor.timestamp - 0.05)
            #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
            #expect(words.allSatisfy { $0.start <= $0.end })
        }
        // Chapter 2 anchors sit after chapter 1's audio, so their (absolute)
        // words must too — proving the per-chapter offset reached the words.
        let last = try #require(worded.max(by: { $0.timestamp < $1.timestamp }))
        #expect(last.words!.allSatisfy { $0.start >= last.timestamp - 0.05 })
        #expect(last.timestamp > 0)
    }

    /// `includeWordTimings: false` (the `--no-word-timings` CLI flag) keeps the
    /// generated sidecar anchors-only even when the engine emits word timings.
    @Test func noWordTimingsConfigProducesAnchorsOnlySidecar() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("wordless.m4b")
        let sidecar = tmp.appendingPathComponent("wordless.alignment.json")
        var cfg = NarrationRunConfig(
            epubURL: epub, outM4BURL: out, sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("wordless-work"), voice: VoiceID("af_heart"),
            title: "Fixture", author: "Tester", maxNewChaptersPerRun: nil)
        cfg.includeWordTimings = false

        let result = try await HeadlessNarrationRunner().run(cfg, tts: WordTimedStubEngine())
        #expect(result.complete)

        let data = try Data(contentsOf: sidecar)
        #expect(!String(decoding: data, as: UTF8.self).contains("words"))
        let anchors = try AlignmentSidecar.decode(data)
        #expect(!anchors.isEmpty)
        #expect(anchors.allSatisfy { $0.words == nil })
    }

    @Test func producesM4BFromPDFFile() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pdf = try TestPDFFixture.singleChapter(in: tmp)
        let out = tmp.appendingPathComponent("pdf-book.m4b")
        let sidecar = tmp.appendingPathComponent("pdf-book.alignment.json")
        let cfg = NarrationRunConfig(
            epubURL: pdf, outM4BURL: out, sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("pdf-work"), voice: VoiceID("af_heart"),
            title: "PDF Fixture", author: "Tester", maxNewChaptersPerRun: nil)

        let result = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(result.complete)
        #expect(result.chapters == 1)
        #expect(FileManager.default.fileExists(atPath: out.path))

        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecar))
        #expect(!anchors.isEmpty)
        #expect(anchors.allSatisfy { $0.blockId.contains("-b") })
    }

    @Test func multiPagePDFBatchesByPageChaptersAndResumes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pdf = try TestPDFFixture.threePagesWithoutChapterMarkers(in: tmp)
        let out = tmp.appendingPathComponent("paged-pdf.m4b")
        let sidecar = tmp.appendingPathComponent("paged-pdf.alignment.json")
        let cfg = NarrationRunConfig(
            epubURL: pdf, outM4BURL: out, sidecarURL: sidecar,
            workDir: tmp.appendingPathComponent("paged-pdf-work"), voice: VoiceID("af_heart"),
            title: "Paged PDF Fixture", author: "Tester", maxNewChaptersPerRun: 1)

        let first = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(first.complete == false)
        #expect(first.chapters == 3)
        #expect(first.capturedThisRun == 1)
        #expect(!FileManager.default.fileExists(atPath: out.path))

        let second = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(second.complete == false)
        #expect(second.capturedThisRun == 1)

        let third = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(third.complete)
        #expect(third.chapters == 3)
        #expect(third.capturedThisRun == 1)
        #expect(FileManager.default.fileExists(atPath: out.path))

        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecar))
        #expect(!anchors.isEmpty)
    }

    @Test func prefersEPUBOverPDFWhenScanningDirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expandedEPUB = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try? FileManager.default.removeItem(at: epub)
        // `shouldKeepParent: false` so the EPUB's contents (mimetype, META-INF/…)
        // sit at the archive root — `parseEPUBBlocks` looks for
        // `META-INF/container.xml` at the extracted root, not nested under the
        // source directory's name, so the default (parent-keeping) zip is rejected.
        try FileManager.default.zipItem(at: expandedEPUB, to: epub, shouldKeepParent: false)

        _ = try TestPDFFixture.singleChapter(in: tmp)

        let out = tmp.appendingPathComponent("preferred.m4b")
        let cfg = NarrationRunConfig(
            epubURL: tmp, outM4BURL: out, sidecarURL: nil,
            workDir: tmp.appendingPathComponent("preferred-work"), voice: VoiceID("af_heart"),
            title: "Preferred Source", author: "Tester", maxNewChaptersPerRun: nil)

        let result = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(result.chapters == 2)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func rejectsUnsupportedSourceTypes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = tmp.appendingPathComponent("notes.txt")
        try "Unsupported source text.".write(
            to: input, atomically: true, encoding: .utf8)

        let out = tmp.appendingPathComponent("bad.m4b")
        let cfg = NarrationRunConfig(
            epubURL: input, outM4BURL: out, sidecarURL: nil,
            workDir: tmp.appendingPathComponent("bad-work"), voice: VoiceID("af_heart"),
            title: "Bad", author: "Tester", maxNewChaptersPerRun: nil)

        await #expect(throws: Error.self) {
            _ = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        }
    }

    @Test func persistentDatabaseRunIsIdempotent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let epub = try TestEPUBFixture.twoChapters(in: tmp)
        let out = tmp.appendingPathComponent("persistent.m4b")
        let dbURL = tmp.appendingPathComponent("narration.sqlite")
        let cfg = NarrationRunConfig(
            epubURL: epub, outM4BURL: out, sidecarURL: nil,
            workDir: tmp.appendingPathComponent("persistent-work"), voice: VoiceID("af_heart"),
            title: "Fixture", author: "Tester", maxNewChaptersPerRun: nil, databaseURL: dbURL)

        let first = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(first.complete)

        let second = try await HeadlessNarrationRunner().run(cfg, tts: StubEngine())
        #expect(second.complete)
        #expect(second.capturedThisRun == 0)
    }
}
