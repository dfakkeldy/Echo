import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct NarrationServiceTests {

    private func blocks(_ audiobookID: String, _ texts: [String?]) -> [EPubBlockRecord] {
        texts.enumerated().map { i, t in
            EPubBlockRecord(
                id: "blk\(i)", audiobookID: audiobookID, spineHref: "c.xhtml",
                spineIndex: 0, blockIndex: i, sequenceIndex: i,
                blockKind: "paragraph", text: t, htmlContent: nil, cardColor: nil,
                chapterThemeColor: nil, imagePath: nil, chapterIndex: 0,
                isHidden: false, hiddenReason: nil, isFrontMatter: false,
                wordCount: nil, markers: nil, textFormats: nil,
                createdAt: nil, modifiedAt: nil)
        }
    }

    /// Inserts the audiobook row plus the blocks (so `alignment_anchor`'s
    /// `epub_block_id` foreign key is satisfied) and returns the blocks.
    private func seed(_ db: DatabaseService, _ texts: [String?]) throws -> [EPubBlockRecord] {
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1','Book',0,'2026-06-13T00:00:00Z')"
            )
        }
        let blocks = blocks("b1", texts)
        try EPubBlockDAO(db: db.writer).insertAll(blocks)
        return blocks
    }

    private func makeService(_ db: DatabaseService, tts: TTSEngine, writer: AudioFileWriting)
        -> NarrationService
    {
        NarrationService(
            db: db.writer, audiobookID: "b1",
            tts: tts, audioWriter: writer,
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState())
    }

    @Test func writesOneTrackPerChapterWithVoiceAndDuration() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))

        let track = try db.read { db in
            try TrackRecord.filter(Column("audiobook_id") == "b1").fetchOne(db)
        }
        #expect(track?.sortOrder == 0)
        #expect(track.map { abs($0.duration - 0.6) < 0.0001 } == true)  // (4+2)×0.1
        // Direct column check — proves narration_voice mapping:
        let voiceCol = try db.read { db in
            try String.fetchOne(
                db, sql: "SELECT narration_voice FROM track WHERE audiobook_id = 'b1'")
        }
        #expect(voiceCol == "af_warm")
    }

    @Test func writesSynthesizedAnchorPerTextBlockInOrder() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())
        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))
        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1")
                .order(Column("audio_time")).fetchAll(db)
        }
        #expect(anchors.count == 2)
        #expect(anchors.allSatisfy { $0.source == "synthesized" })
        #expect(anchors[0].epubBlockID == "blk0")
        #expect(abs(anchors[0].audioTime - 0.0) < 0.0001)
        #expect(abs(anchors[1].audioTime - 0.4) < 0.0001)
    }

    @Test func skipsBlocksWithNoText() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["hi", nil, ""])
        let tts = MockTTSEngine()
        let svc = makeService(db, tts: tts, writer: MockAudioWriter())
        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))
        let anchorCount = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchCount(db)
        }
        #expect(anchorCount == 1)
        #expect(tts.calls.count == 1)
    }

    @Test func cancellationStopsBeforeWritingTrack() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(db, tts: MockTTSEngine(), writer: MockAudioWriter())
        let task = Task {
            try await svc.renderChapter(
                chapterIndex: 0,
                blocks: blocks, voice: VoiceID("af_warm"))
        }
        task.cancel()
        _ = try? await task.value
        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        #expect(trackCount == 0)
    }
}
