// SPDX-License-Identifier: GPL-3.0-or-later
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

    /// Overload that injects a pronunciation-override closure so the override→
    /// link-syntax rewrite can be exercised through the real render path.
    private func makeService(
        _ db: DatabaseService, tts: TTSEngine, writer: AudioFileWriting,
        overrides: @escaping () -> PronunciationOverrides
    ) -> NarrationService {
        NarrationService(
            db: db.writer, audiobookID: "b1",
            tts: tts, audioWriter: writer,
            cacheDirectory: FileManager.default.temporaryDirectory,
            state: NarrationState(), pronunciationOverrides: overrides)
    }

    /// Counts non-overlapping occurrences of `needle` across every synthesized
    /// sub-chunk — robust to however the chunker groups the rewritten text.
    private func linkOccurrences(_ calls: [(text: String, voice: VoiceID)], _ needle: String)
        -> Int
    {
        calls.reduce(0) { $0 + $1.text.components(separatedBy: needle).count - 1 }
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
        // (4+2)×0.1 spoken + the lead-out pad appended once at the chapter end.
        let expectedDuration = 0.6 + NarrationService.leadOutPadSeconds
        #expect(track.map { abs($0.duration - expectedDuration) < 0.0001 } == true)
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

    /// Read-along write-side: rendering a chapter must propagate its synthesized
    /// anchors into `timeline_item` (via AlignmentService.recalculateTimeline),
    /// because that table — not `alignment_anchor` — is what the reader queries
    /// (`WHERE audio_start_time >= 0`). Without the recalc the reader shows no
    /// timestamps and never highlights. Asserts the exact read-side predicate.
    @Test func renderChapterPopulatesTimelineItemForReadAlong() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(
            chapterIndex: 0, blocks: blocks,
            voice: VoiceID("af_warm"))

        // Mirror ReaderFeedViewModel.reload()'s exact predicate.
        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT epub_block_id, audio_start_time FROM timeline_item
                    WHERE audiobook_id = 'b1'
                      AND epub_block_id IS NOT NULL
                      AND audio_start_time >= 0
                    ORDER BY audio_start_time
                    """)
        }
        // One timeline_item per rendered block, each with a non-negative start.
        #expect(rows.count == 2)
        let blockIDs = rows.compactMap { $0["epub_block_id"] as String? }
        #expect(blockIDs == ["blk0", "blk1"])
        let starts = rows.compactMap { $0["audio_start_time"] as Double? }
        #expect(starts.allSatisfy { $0 >= 0 })
        // Per-chapter 0-based: the first block starts at 0, matching its anchor.
        #expect(abs((starts.first ?? -1) - 0.0) < 0.0001)
    }

    @Test func renderSegmentFileWritesSegmentCacheWithoutPersistingPlaybackState() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["first", "second", "third"])
        let writer = MockAudioWriter()
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: writer)
        svc.state.update(
            phase: .renderingAhead,
            progress: 0.42,
            statusMessage: "Rendering next chapter…")

        let rendered = try await svc.renderSegmentFile(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 2,
            blocks: Array(blocks[1...2]),
            voice: VoiceID("af_warm"))

        let expectedName = NarrationFileNaming.segmentFileName(
            audiobookID: "b1", chapterIndex: 0, segmentIndex: 2, voice: VoiceID("af_warm"))
        #expect(rendered.fileURL.lastPathComponent == expectedName)
        #expect(writer.writtenURLs.map(\.lastPathComponent) == [expectedName])
        #expect(rendered.chapterIndex == 0)
        #expect(rendered.chapterDisplayNumber == 1)
        #expect(rendered.segmentIndex == 2)

        let secondDuration = Double("second".count) * 0.1
        let spokenDuration = secondDuration + Double("third".count) * 0.1
        #expect(abs(rendered.duration - spokenDuration) < 0.0001)
        #expect(writer.chunkCounts == [2])
        #expect(rendered.anchors.map(\.epubBlockID) == ["blk1", "blk2"])
        #expect(abs(rendered.anchors[0].audioTime - 0.0) < 0.0001)
        #expect(abs(rendered.anchors[1].audioTime - secondDuration) < 0.0001)

        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        let persistedAnchorCount = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchCount(db)
        }
        let alignedTimelineRows = try db.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM timeline_item
                    WHERE audiobook_id = 'b1' AND audio_start_time >= 0
                    """) ?? -1
        }
        #expect(trackCount == 0)
        #expect(persistedAnchorCount == 0)
        #expect(alignedTimelineRows == 0)
        #expect(svc.state.phase == .renderingAhead)
        #expect(svc.state.progress == 0.42)
        #expect(svc.state.statusMessage == "Rendering next chapter…")
        #expect(svc.state.renderedChapterCount == 0)
    }

    @Test func renderSegmentPersistsTrackTimelineAndSegmentKey() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["first", "second", "third"])
        let writer = MockAudioWriter()
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: writer)

        try await svc.renderSegment(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 0,
            blocks: Array(blocks[0...1]),
            voice: VoiceID("af_warm"))
        try await svc.renderSegment(
            chapterIndex: 0,
            chapterDisplayNumber: 1,
            segmentIndex: 1,
            blocks: [blocks[2]],
            voice: VoiceID("af_warm"))

        let tracks = try TrackDAO(db: db.writer).tracks(for: "b1")
        #expect(tracks.map(\.id) == ["syn-b1-ch0-s0", "syn-b1-ch0-s1"])
        #expect(tracks.map(\.title) == ["Chapter 1", "Chapter 1"])
        #expect(tracks.map(\.sortOrder) == [0, 1])
        #expect(tracks.map(\.narrationVoice) == ["af_warm", "af_warm"])
        #expect(abs((tracks.first?.duration ?? -1) - 1.1) < 0.0001)
        #expect(abs((tracks.last?.duration ?? -1) - 0.5) < 0.0001)

        let expectedNames = [
            NarrationFileNaming.segmentFileName(
                audiobookID: "b1", chapterIndex: 0, segmentIndex: 0,
                voice: VoiceID("af_warm")),
            NarrationFileNaming.segmentFileName(
                audiobookID: "b1", chapterIndex: 0, segmentIndex: 1,
                voice: VoiceID("af_warm")),
        ]
        #expect(writer.writtenURLs.map(\.lastPathComponent) == expectedNames)

        let anchors = try db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == "b1")
                .order(Column("epub_block_id"))
                .fetchAll(db)
        }
        #expect(anchors.map(\.epubBlockID) == ["blk0", "blk1", "blk2"])
        #expect(anchors.map(\.audioTime) == [0.0, 0.5, 0.0])

        let rows = try db.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT epub_block_id, audio_start_time, audio_end_time, segment_key
                    FROM timeline_item
                    WHERE audiobook_id = 'b1'
                      AND epub_block_id IS NOT NULL
                      AND audio_start_time >= 0
                    ORDER BY epub_block_id
                    """)
        }
        #expect(rows.compactMap { $0["epub_block_id"] as String? } == ["blk0", "blk1", "blk2"])
        #expect(rows.compactMap { $0["segment_key"] as String? } == ["0-0", "0-0", "0-1"])
        #expect(rows.compactMap { $0["audio_start_time"] as Double? } == [0.0, 0.5, 0.0])
        #expect(rows.compactMap { $0["audio_end_time"] as Double? } == [0.5, 1.1, 0.5])
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

    /// A long multi-sentence block whose sentences are all DISTINCT, so the
    /// chunker's merged sub-chunks are unique strings (a duplicate would let a
    /// single `lengthCapOnText` match — and skip — more than one sub-chunk).
    private func longDistinctBlockText() -> String {
        (1...8).map { i in
            "Sentence number \(i) describes the quick brown fox jumping over a lazy dog."
        }.joined(separator: " ")
    }

    @Test func multiSubChunkBlockStillYieldsOneAnchorSpanningSummedDuration() async throws {
        let db = try DatabaseService(inMemory: ())
        // A long multi-sentence block that the chunker splits into several
        // sub-chunks (> 200 chars). It must still produce exactly ONE anchor,
        // spanning the sum of every sub-chunk's duration.
        let long = longDistinctBlockText()
        let blocks = try seed(db, [long])

        let subChunks = NarrationTextChunker.split(TextNormalizer.normalize(long))
        #expect(subChunks.count > 1)  // guard: the block really does fan out

        let secondsPerChar = 0.1
        let mock = MockTTSEngine(secondsPerChar: secondsPerChar)
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        #expect(anchors.count == 1)  // ONE anchor per original block, not per sub-chunk
        #expect(anchors[0].epubBlockID == "blk0")

        // The single anchor spans the SUM of every sub-chunk's duration.
        let expectedDuration = subChunks.reduce(0.0) { $0 + Double($1.count) * secondsPerChar }
        let span = (anchors[0].audioEndTime ?? 0) - anchors[0].audioTime
        #expect(abs(span - expectedDuration) < 0.0001)

        // Every sub-chunk was synthesized and handed to the writer; the writer
        // also receives the trailing lead-out silence (one extra append, no TTS
        // call), so the chunk count is sub-chunks + 1.
        #expect(mock.calls.count == subChunks.count)
        #expect(writer.chunkCounts == [subChunks.count + 1])
    }

    @Test func lengthCapSubChunkIsSkippedWithoutAbortingTheChapter() async throws {
        let db = try DatabaseService(inMemory: ())
        let long = longDistinctBlockText()
        let blocks = try seed(db, [long])

        let subChunks = NarrationTextChunker.split(TextNormalizer.normalize(long))
        #expect(subChunks.count > 1)

        let secondsPerChar = 0.1
        let mock = MockTTSEngine(secondsPerChar: secondsPerChar)
        // Make the FIRST sub-chunk raise the length-cap error. The chapter must
        // still complete with the remaining sub-chunks.
        mock.lengthCapOnText = subChunks[0]
        let writer = MockAudioWriter()
        let svc = makeService(db, tts: mock, writer: writer)

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_warm"))

        // Track + anchor still written (chapter not aborted).
        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        #expect(trackCount == 1)
        let anchors = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchAll(db)
        }
        #expect(anchors.count == 1)

        // The skipped sub-chunk's duration is excluded from the span; only the
        // surviving sub-chunks were written.
        let survivors = Array(subChunks.dropFirst())
        let expectedDuration = survivors.reduce(0.0) { $0 + Double($1.count) * secondsPerChar }
        let span = (anchors[0].audioEndTime ?? 0) - anchors[0].audioTime
        #expect(abs(span - expectedDuration) < 0.0001)
        // Surviving sub-chunks + the trailing lead-out silence.
        #expect(writer.chunkCounts == [survivors.count + 1])
    }

    @Test func rerenderingAChapterIsIdempotentAndUpdatesVoice() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["abcd", "ef"])
        let svc = makeService(
            db, tts: MockTTSEngine(secondsPerChar: 0.1), writer: MockAudioWriter())

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))
        // Re-render the same chapter with a different voice — must upsert in place,
        // not throw on the duplicate anchor primary key or create duplicate rows.
        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("bf_emma"))

        let anchorCount = try db.read { db in
            try AlignmentAnchorRecord.filter(Column("audiobook_id") == "b1").fetchCount(db)
        }
        let trackCount = try db.read { db in try TrackRecord.fetchCount(db) }
        let voiceCol = try db.read { db in
            try String.fetchOne(
                db, sql: "SELECT narration_voice FROM track WHERE audiobook_id = 'b1'")
        }
        #expect(anchorCount == 2)  // 2, not 4 — upserted
        #expect(trackCount == 1)  // 1, not 2
        #expect(voiceCol == "bf_emma")  // re-render updated the voice
    }

    // MARK: - Pronunciation overrides (Part B / B3)

    private static let kubeNeedle = "[Kubernetes](/kuːbərˈnɛtɪs/)"

    /// The injected override must reach the engine wrapped in Misaki link syntax —
    /// not the bare word — so G2P pronounces it from the user's IPA.
    @Test func pronunciationOverrideReachesEngineAsLinkSyntax() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Deploying Kubernetes to production now."])
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter()) {
            PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])
        }

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        // The engine saw the rewritten link, never the un-wrapped word.
        #expect(linkOccurrences(mock.calls, Self.kubeNeedle) == 1)
        #expect(!mock.calls.contains { $0.text.contains("Deploying Kubernetes to") })
    }

    /// A long multi-sentence block fans out through the sentence-merge chunk path.
    /// Every occurrence of the override word must reach the engine as an intact
    /// link — none bisected by a sub-chunk boundary.
    @Test func overrideLinkSurvivesSentenceMergeChunking() async throws {
        let db = try DatabaseService(inMemory: ())
        let long = (1...6).map {
            "Sentence number \($0) talks about deploying Kubernetes carefully."
        }.joined(separator: " ")
        let blocks = try seed(db, [long])
        // Guard: the block really does fan out into multiple sub-chunks.
        #expect(NarrationTextChunker.split(TextNormalizer.normalize(long)).count > 1)

        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter()) {
            PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])
        }

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        // All six occurrences arrive intact; no half-formed link survives.
        #expect(linkOccurrences(mock.calls, Self.kubeNeedle) == 6)
        #expect(
            !mock.calls.contains {
                $0.text.contains("[Kubernetes]") && !$0.text.contains(Self.kubeNeedle)
            })
    }

    /// One terminator-free run longer than `maxChars` forces the chunker into the
    /// word-wrap (space-splitting) fallback — the path most likely to bisect a
    /// token. The link has no internal space, so it must stay atomic.
    @Test func overrideLinkSurvivesWordWrapFallback() async throws {
        let db = try DatabaseService(inMemory: ())
        let filler = Array(repeating: "padding", count: 40).joined(separator: " ")
        let long = "\(filler) Kubernetes \(filler)"  // >200 chars, no sentence break
        let blocks = try seed(db, [long])

        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter()) {
            PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])
        }

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        #expect(linkOccurrences(mock.calls, Self.kubeNeedle) == 1)
        #expect(
            !mock.calls.contains {
                $0.text.contains("[Kubernetes]") && !$0.text.contains(Self.kubeNeedle)
            })
    }

    /// The default (no-override) closure must leave text untouched, so existing
    /// callers and the macOS/iOS default paths are unaffected by the feature.
    @Test func defaultEmptyOverridesLeaveTextUnchanged() async throws {
        let db = try DatabaseService(inMemory: ())
        let blocks = try seed(db, ["Plain text here."])
        let mock = MockTTSEngine(secondsPerChar: 0.1)
        let svc = makeService(db, tts: mock, writer: MockAudioWriter())  // default overrides

        try await svc.renderChapter(chapterIndex: 0, blocks: blocks, voice: VoiceID("af_heart"))

        #expect(mock.calls.map(\.text) == ["Plain text here."])
    }
}
