// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationServiceSynthesisTimingTests {
    /// Engine that emits one ChunkWordTiming per whitespace word when `emit` is on.
    private final class WordTimedEngine: TTSEngine {
        let emit: Bool
        init(emit: Bool) { self.emit = emit }
        func prepare() async throws {}
        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            let dur = Double(max(words, 1)) * 0.2
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
            state: NarrationState())
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

    @Test func keepsInterpolatedWhenEngineEmitsNoTimings() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, [block("blk0", "one two")])
        try await render(db, emit: false)
        let rows = try WordTimingDAO(db: db.writer).words(forAudiobook: "b1", blockID: "blk0")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.source == "interpolated" })
    }
}
