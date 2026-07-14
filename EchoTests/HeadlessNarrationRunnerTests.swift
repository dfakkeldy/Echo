// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct HeadlessNarrationRunnerTests {
    private func auditDecision(
        chapterIndex: Int,
        chapterRange: PronunciationAuditDecision.AudioRange?
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "blk-\(chapterIndex)",
            wordStart: 2,
            wordEnd: 2,
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
            timingPrecision: chapterRange == nil ? nil : .exactSynthesisWord)
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

    private func captureIdentity(chapterIndex: Int) -> HeadlessNarrationRunner.ChapterCapture.Identity {
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

    private final class PrepareMutationEngine: TTSEngine, @unchecked Sendable {
        private let mutation: @Sendable () throws -> Void

        init(mutation: @escaping @Sendable () throws -> Void) {
            self.mutation = mutation
        }

        func prepare() async throws {
            try mutation()
        }

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws {
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

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws {
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
        #expect([out, sidecar, audit, reel].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })

        config.maxNewChaptersPerRun = 1
        config.clearExistingCapturesBeforeRun = true
        let partial = try await HeadlessNarrationRunner().run(config, tts: StubEngine())

        #expect(!partial.complete)
        #expect(partial.capturedThisRun == 1)
        #expect([out, sidecar, audit, reel].allSatisfy {
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
        #expect(assembled.decisions[1].bookRelativeAudioRange?.start == sidecar.anchors[1].timestamp)
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
