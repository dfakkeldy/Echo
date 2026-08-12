// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationServiceSynthesisTimingTests {
    enum InvalidRetryTiming: CaseIterable, Sendable {
        case noncontiguousIndexes
        case outOfBoundsRange
    }

    /// Engine that emits one ChunkWordTiming per whitespace word when `emit` is on.
    private final class WordTimedEngine: TTSEngine {
        let emit: Bool
        init(emit: Bool) { self.emit = emit }
        func prepare() async throws {}
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            let dur = max(Double(max(words, 1)) * 0.2, 0.25)
            let samples = [Float](repeating: 0.05, count: Int(dur * 24_000))
            let timings: [ChunkWordTiming]? =
                emit
                ? (0..<words).map {
                    ChunkWordTiming(
                        wordIndex: $0, start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.2)
                } : nil
            return TTSChunk(
                samples: samples, sampleRate: 24_000,
                duration: Double(samples.count) / 24_000, wordTimings: timings)
        }
    }

    /// Rejects the original planned chunk with silence, then accepts its retry
    /// children with deterministic timings so receipt identity can be exercised.
    private final class RetryWordTimedEngine: TTSEngine, @unchecked Sendable {
        private(set) var plannedCalls: [PlannedSynthesisChunk] = []
        let invalidTiming: InvalidRetryTiming?

        init(invalidTiming: InvalidRetryTiming? = nil) {
            self.invalidTiming = invalidTiming
        }

        func prepare() async throws {}

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            timedChunk(wordCount: WordTokenizer.words(in: text).count, silent: false)
        }

        func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            plannedCalls.append(chunk)
            let isOriginalParent = plannedCalls.count == 1
            return timedChunk(wordCount: chunk.wordCount, silent: isOriginalParent)
        }

        private func timedChunk(wordCount: Int, silent: Bool) -> TTSChunk {
            let duration = Double(max(wordCount, 1)) * 0.3
            let sampleCount = max(2, Int(duration * 24_000))
            let samples = (0..<sampleCount).map { index in
                silent ? Float.zero : (index.isMultiple(of: 2) ? Float(0.05) : Float(-0.05))
            }
            var timings = (0..<wordCount).map { index in
                ChunkWordTiming(
                    wordIndex: index,
                    start: Double(index) * 0.3,
                    end: Double(index + 1) * 0.3)
            }
            if !silent, !timings.isEmpty {
                switch invalidTiming {
                case .noncontiguousIndexes:
                    timings[0] = ChunkWordTiming(
                        wordIndex: 1,
                        start: timings[0].start,
                        end: timings[0].end)
                case .outOfBoundsRange:
                    let last = timings.index(before: timings.endIndex)
                    timings[last] = ChunkWordTiming(
                        wordIndex: timings[last].wordIndex,
                        start: timings[last].start,
                        end: duration + 0.1)
                case nil:
                    break
                }
            }
            return TTSChunk(
                samples: samples,
                sampleRate: 24_000,
                duration: duration,
                wordTimings: timings)
        }
    }

    /// Reproduces the governed short-block failure at the TTSEngine boundary:
    /// the first complete-plan synthesis is acoustically rejected, while a second
    /// synthesis of the same immutable plan is acceptable and carries exact timing.
    private final class AtomicRetryWordTimedEngine: TTSEngine, @unchecked Sendable {
        private(set) var plannedCalls: [(chunk: PlannedSynthesisChunk, voice: VoiceID)] = []

        func prepare() async throws {}

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            timedChunk(wordCount: WordTokenizer.words(in: text).count, silent: false)
        }

        func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            plannedCalls.append((chunk, voice))
            return timedChunk(wordCount: chunk.wordCount, silent: plannedCalls.count == 1)
        }

        private func timedChunk(wordCount: Int, silent: Bool) -> TTSChunk {
            let duration = Double(wordCount) * 0.3
            let sampleCount = max(2, Int(duration * 24_000))
            let samples = (0..<sampleCount).map { index in
                silent ? Float.zero : (index.isMultiple(of: 2) ? Float(0.05) : Float(-0.05))
            }
            let timings = (0..<wordCount).map { index in
                ChunkWordTiming(
                    wordIndex: index,
                    start: Double(index) * 0.3,
                    end: Double(index + 1) * 0.3)
            }
            return TTSChunk(
                samples: samples,
                sampleRate: 24_000,
                duration: duration,
                wordTimings: timings)
        }
    }

    private final class FinalDurationWriter: AudioFileWriting, @unchecked Sendable {
        let finalDuration: TimeInterval

        init(finalDuration: TimeInterval) {
            self.finalDuration = finalDuration
        }

        func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
            let stream = try makeStream(to: url, sampleRate: chunks.first?.sampleRate ?? 24_000)
            for chunk in chunks {
                try await stream.append(chunk)
            }
            return try await stream.finalize()
        }

        func makeStream(to url: URL, sampleRate: Double) throws -> any AudioFileStream {
            FinalDurationStream(finalDuration: finalDuration)
        }
    }

    private final class FinalDurationStream: AudioFileStream, @unchecked Sendable {
        let finalDuration: TimeInterval

        init(finalDuration: TimeInterval) {
            self.finalDuration = finalDuration
        }

        func append(_ chunk: TTSChunk) async throws {}

        func finalize() async throws -> TimeInterval {
            finalDuration
        }
    }

    private func block(_ id: String, _ text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "b1", spineHref: "c.xhtml", spineIndex: 0, blockIndex: 0,
            sequenceIndex: 0, blockKind: "paragraph", text: text, htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: 0, isHidden: false,
            hiddenReason: nil, isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }

    private func seed(_ db: DatabaseService, _ blocks: [EPubBlockRecord]) throws {
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-26T00:00:00Z')"
            )
        }
        try EPubBlockDAO(db: db.writer).insertAll(blocks)
    }

    private func render(_ db: DatabaseService, emit: Bool) async throws {
        let svc = NarrationService(
            db: db.writer, audiobookID: "b1", tts: WordTimedEngine(emit: emit),
            audioWriter: MockAudioWriter(), cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })
        try await svc.renderChapter(
            chapterIndex: 0, blocks: [block("blk0", "one two")], voice: VoiceID("af_heart"))
    }

    @Test func writesSynthesisRowsWhenEngineEmitsTimings() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, [block("blk0", "one two")])
        try await render(db, emit: true)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk0")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.source == "synthesis" })
    }

    @Test func writesSynthesizedRowsWhenEngineEmitsNoTimings() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, [block("blk0", "one two")])
        try await render(db, emit: false)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk0")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.source == "synthesized" })
    }

    @Test func exactSynthesisWordReceiptUsesValidatedChapterRelativeTiming() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = [block("blk0", "verified")]
        try seed(db, blocks)
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: WordTimedEngine(emit: true),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 5,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        let decision = try #require(rendered.pronunciationDecisions.first)
        let range = try #require(decision.chapterRelativeAudioRange)
        #expect(rendered.pronunciationDecisions.count == 1)
        #expect(decision.normalizedWord == "verified")
        #expect(decision.chapterIndex == 5)
        #expect(decision.timingPrecision == .exactSynthesisWord)
        #expect(abs(range.start) < 0.0001)
        #expect(abs(range.end - 0.2) < 0.0001)
        #expect(range.end > range.start)
    }

    @Test func receiptRangeNeverExceedsFinalizedRenderedFileDuration() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = [block("blk0", "verified")]
        try seed(db, blocks)
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: WordTimedEngine(emit: true),
            audioWriter: FinalDurationWriter(finalDuration: 0.1),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        let decision = try #require(rendered.pronunciationDecisions.first)
        #expect(abs(rendered.duration - 0.1) < 0.0001)
        #expect(decision.chapterRelativeAudioRange == nil)
        #expect(decision.timingPrecision == nil)
    }

    @Test func tinyFinalizationRoundingDeltaClampsReceiptToRenderedDuration() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = [block("blk0", "verified")]
        try seed(db, blocks)
        let finalDuration = 0.2 - 1e-12
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: WordTimedEngine(emit: true),
            audioWriter: FinalDurationWriter(finalDuration: finalDuration),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        let decision = try #require(rendered.pronunciationDecisions.first)
        let range = try #require(decision.chapterRelativeAudioRange)
        #expect(decision.timingPrecision == .exactSynthesisWord)
        #expect(range.end == rendered.duration)
        #expect(range.end <= rendered.duration)
    }

    @Test func rejectedRetainedAudioLeavesWatchedDecisionRangeFree() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = [block("blk0", "verified")]
        try seed(db, blocks)
        let engine = MockTTSEngine(secondsPerChar: 0.1)
        engine.returnsSilenceForAllText = true
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: engine,
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 7,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        let decision = try #require(rendered.pronunciationDecisions.first)
        let diagnostic = try #require(
            rendered.pronunciationAuditDiagnostics.first {
                $0.reason == .qualityRejected && $0.blockID == "blk0"
            })
        #expect(rendered.anchors.first?.audioEndTime ?? 0 > 0)
        #expect(decision.normalizedWord == "verified")
        #expect(decision.chapterIndex == 7)
        #expect(decision.chapterRelativeAudioRange == nil)
        #expect(decision.timingPrecision == nil)
        #expect(diagnostic.chapterIndex == 7)
        #expect(diagnostic.chunkIndex == 0)
        #expect(diagnostic.expectedDisplayText == "verified")
    }

    @Test func laterOriginalChunkUsesCumulativePlannedWordBaseForExactReceipt() async throws {
        let db = try DatabaseService(inMemory: ())
        let sentence =
            "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu."
        let text = Array(repeating: sentence, count: 8).joined(separator: " ") + " verified."
        let blocks = [block("blk0", text)]
        try seed(db, blocks)
        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]))
        let chunks = try #require(plan.blocks.first?.synthesisChunks)
        let watchedChunkIndex = try #require(
            chunks.firstIndex { chunk in
                WordTokenizer.words(in: chunk.displayText).contains {
                    PronunciationAuditContext.normalizedWord(String($0)) == "verified"
                }
            })
        try #require(watchedChunkIndex > 0)
        let watchedWords = WordTokenizer.words(in: chunks[watchedChunkIndex].displayText)
        let localWordIndex = try #require(
            watchedWords.firstIndex {
                PronunciationAuditContext.normalizedWord(String($0)) == "verified"
            })
        let originalWordBase = chunks[..<watchedChunkIndex].reduce(0) {
            $0 + $1.wordCount
        }
        let expectedStart = Double(originalWordBase + localWordIndex) * 0.2

        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: WordTimedEngine(emit: true),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        let decision = try #require(
            rendered.pronunciationDecisions.first { $0.normalizedWord == "verified" })
        let range = try #require(decision.chapterRelativeAudioRange)
        #expect(decision.wordStart == originalWordBase + localWordIndex)
        #expect(decision.timingPrecision == .exactSynthesisWord)
        #expect(abs(range.start - expectedStart) < 0.0001)
        #expect(abs(range.end - (expectedStart + 0.2)) < 0.0001)
    }

    @Test func multiwordDecisionUsesPositivePersistedBlockAnchorFallback() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = [block("blk0", "New York welcomes visitors.")]
        try seed(db, blocks)
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: WordTimedEngine(emit: true),
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            pronunciationOccurrenceOverrides: {
                PronunciationOccurrenceOverrides(entries: [
                    PronunciationOccurrenceOverride(
                        blockID: "blk0",
                        wordStart: 0,
                        wordEnd: 1,
                        word: "New York",
                        ipa: "nˈu jˈɔɹk")
                ])
            },
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        let decision = try #require(rendered.pronunciationDecisions.first)
        let range = try #require(decision.chapterRelativeAudioRange)
        let anchor = try #require(rendered.anchors.first)
        #expect(decision.wordStart == 0)
        #expect(decision.wordEnd == 1)
        #expect(decision.timingPrecision == .blockAnchorFallback)
        #expect(abs(range.start - anchor.audioTime) < 0.0001)
        #expect(abs(range.end - (anchor.audioEndTime ?? -1)) < 0.0001)
        #expect(range.end > range.start)
    }

    @Test func acceptedRetryChildrenKeepOriginalDecisionIdentityAndExactTiming() async throws {
        let db = try DatabaseService(inMemory: ())
        let text =
            "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu verified."
        let blocks = [block("blk0", text)]
        try seed(db, blocks)
        let engine = RetryWordTimedEngine()
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: engine,
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        try #require(engine.plannedCalls.count > 1)
        let parentWords = WordTokenizer.words(in: engine.plannedCalls[0].displayText).map(String.init)
        let childWords = engine.plannedCalls.dropFirst().flatMap {
            WordTokenizer.words(in: $0.displayText).map(String.init)
        }
        #expect(childWords == parentWords)
        let decisions = rendered.pronunciationDecisions.filter {
            $0.normalizedWord == "verified"
        }
        let decision = try #require(decisions.first)
        let range = try #require(decision.chapterRelativeAudioRange)
        #expect(decisions.count == 1)
        #expect(decision.timingPrecision == .exactSynthesisWord)
        #expect(range.end > range.start)
    }

    @Test func legitimateShortBlockRetriesAtomicallyWithCompleteEvidence() async throws {
        let db = try DatabaseService(inMemory: ())
        let displayText = "\"Stop,\" she said."
        let blockID = "s3-b16"
        let blocks = [block(blockID, displayText)]
        try seed(db, blocks)
        let engine = AtomicRetryWordTimedEngine()
        let writer = MockAudioWriter()
        let voice = VoiceID("af_heart")
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: engine,
            audioWriter: writer,
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 3,
            blocks: blocks,
            voice: voice,
            blockVoice: { requestedBlockID in
                #expect(requestedBlockID == blockID)
                return voice
            })
        let timingRows = try WordTimingDAO(db: db.writer).words(
            forAudiobook: "b1",
            blockID: blockID)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: voice,
            blockVoiceProvenance: PronunciationBlockVoiceProvenance(
                voicePlanSHA256: String(repeating: "a", count: 64),
                blockVoices: [blockID: voice]),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: rendered.fileURL,
            reelURL: nil,
            audiobookSHA256: String(repeating: "b", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: rendered.pronunciationDecisions,
            diagnostics: rendered.pronunciationAuditDiagnostics)

        let anchor = try #require(rendered.anchors.first)
        #expect(rendered.anchors.count == 1)
        #expect((anchor.audioEndTime ?? 0) > anchor.audioTime)
        #expect(writer.chunkCounts == [2])
        #expect(engine.plannedCalls.count == 2)
        #expect(engine.plannedCalls.map(\.chunk.displayText) == [displayText, displayText])
        #expect(engine.plannedCalls.allSatisfy { $0.voice == voice })
        #expect(timingRows.count == 3)
        #expect(timingRows.allSatisfy { $0.source == "synthesis" })
        #expect(rendered.synthesisWordTimingsByBlock[blockID]?.count == 3)
        #expect(
            rendered.pronunciationAuditDiagnostics.contains {
                $0.reason == .qualityRejected
            } == false)
        #expect(manifest.schemaVersion == PronunciationAuditManifest.planSchemaVersion)
        #expect(manifest.coverage == .complete)
    }

    @Test(arguments: InvalidRetryTiming.allCases)
    func invalidRetryChildTimingFallsBackWithoutLosingOriginalDecision(
        _ invalidTiming: InvalidRetryTiming
    ) async throws {
        let db = try DatabaseService(inMemory: ())
        let text =
            "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu verified."
        let blocks = [block("blk0", text)]
        try seed(db, blocks)
        let engine = RetryWordTimedEngine(invalidTiming: invalidTiming)
        let service = NarrationService(
            db: db.writer,
            audiobookID: "b1",
            tts: engine,
            audioWriter: MockAudioWriter(),
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(),
            fmEnabled: { false })

        let rendered = try await service.renderChapter(
            chapterIndex: 0,
            blocks: blocks,
            voice: VoiceID("af_heart"))

        try #require(engine.plannedCalls.count > 1)
        let decisions = rendered.pronunciationDecisions.filter {
            $0.normalizedWord == "verified"
        }
        let decision = try #require(decisions.first)
        let range = try #require(decision.chapterRelativeAudioRange)
        let anchor = try #require(rendered.anchors.first)
        #expect(decisions.count == 1)
        #expect(decision.timingPrecision == .blockAnchorFallback)
        #expect(abs(range.start - anchor.audioTime) < 0.0001)
        #expect(abs(range.end - (anchor.audioEndTime ?? -1)) < 0.0001)
    }
}
