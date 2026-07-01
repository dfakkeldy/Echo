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
