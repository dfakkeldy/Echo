// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing
import ZIPFoundation

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
        let result = try await HeadlessNarrationRunner().run(cfg, tts: WordTimedStubEngine()) {
            progress in
            if case .wroteSidecar(_, let anchorsWithWords) = progress {
                reportedWordAnchors = anchorsWithWords
            }
        }
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
