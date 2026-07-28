// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct ArchivedEPUBResumeTests {
    private final class StubEngine: TTSEngine {
        func prepare() async throws {}

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws {
            progress(.ready)
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            TTSChunk(
                samples: [Float](repeating: 0.1, count: 4_800),
                sampleRate: 24_000,
                duration: 0.2)
        }
    }

    @Test func archivedEPUBPersistentDatabaseRunIsIdempotent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let expandedEPUB = try TestEPUBFixture.twoChapters(in: tmp)
        let epub = tmp.appendingPathComponent("fixture.epub")
        try FileManager.default.zipItem(
            at: expandedEPUB,
            to: epub,
            shouldKeepParent: false)
        let out = tmp.appendingPathComponent("archived-persistent.m4b")
        let dbURL = tmp.appendingPathComponent("archived-narration.sqlite")
        var config = NarrationRunConfig(
            epubURL: epub,
            outM4BURL: out,
            sidecarURL: nil,
            workDir: tmp.appendingPathComponent("archived-persistent-work"),
            voice: VoiceID("af_heart"),
            title: "Archived Fixture",
            author: "Tester",
            maxNewChaptersPerRun: nil,
            databaseURL: dbURL)
        config.generatePronunciationReview = false

        let first = try await HeadlessNarrationRunner().run(config, tts: StubEngine())
        let second = try await HeadlessNarrationRunner().run(config, tts: StubEngine())

        #expect(first.complete)
        #expect(second.complete)
        #expect(second.capturedThisRun == 0)
    }
}
