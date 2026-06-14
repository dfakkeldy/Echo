import Foundation
import GRDB
import os.log

enum NarrationError: Error, Equatable {
    case synthesisFailed
    case audiobookNotFound
}

/// Renders narration one chapter at a time (render-then-play): synthesize each
/// block → write one AAC file → insert a TrackRecord + one `.synthesized`
/// AlignmentAnchorRecord per text block. Mirrors AutoAlignmentService.
@MainActor @Observable
final class NarrationService {
    private let logger = Logger(category: "Narration")
    private let db: DatabaseWriter
    private let audiobookID: String
    let tts: TTSEngine
    private let audioWriter: AudioFileWriting
    private let cacheDirectory: URL
    let state: NarrationState

    init(
        db: DatabaseWriter, audiobookID: String, tts: TTSEngine,
        audioWriter: AudioFileWriting, cacheDirectory: URL, state: NarrationState
    ) {
        self.db = db
        self.audiobookID = audiobookID
        self.tts = tts
        self.audioWriter = audioWriter
        self.cacheDirectory = cacheDirectory
        self.state = state
    }

    /// Render one chapter. Cancellable between blocks; on cancel, nothing is persisted.
    /// Idempotent: re-rendering the same chapter (e.g. a voice change) upserts in place.
    func renderChapter(chapterIndex: Int, blocks: [EPubBlockRecord], voice: VoiceID) async throws {
        state.update(
            phase: .preparingChapter, progress: 0,
            statusMessage: "Preparing chapter \(chapterIndex + 1)…")

        let spoken = blocks.filter { ($0.text?.isEmpty == false) }
        var chunks: [TTSChunk] = []
        var anchors: [AlignmentAnchorRecord] = []
        var cursor: TimeInterval = 0
        let now = ISO8601DateFormatter().string(from: Date())

        for (i, block) in spoken.enumerated() {
            try Task.checkCancellation()
            let text = TextNormalizer.normalize(block.text ?? "")
            let chunk = try await tts.synthesize(text, voice: voice)
            anchors.append(
                AlignmentAnchorRecord(
                    id: "syn-\(audiobookID)-\(block.id)",
                    audiobookID: audiobookID, epubBlockID: block.id,
                    audioTime: cursor, audioEndTime: cursor + chunk.duration,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.synthesized.rawValue,
                    note: nil, createdAt: now, modifiedAt: now))
            chunks.append(chunk)
            cursor += chunk.duration
            state.update(
                phase: .preparingChapter,
                progress: Double(i + 1) / Double(spoken.count),
                statusMessage: "Preparing chapter \(chapterIndex + 1)…")
        }

        try Task.checkCancellation()
        let fileURL = cacheDirectory.appendingPathComponent(
            NarrationFileNaming.chapterFileName(
                audiobookID: audiobookID, chapterIndex: chapterIndex, voice: voice))
        let duration = try await audioWriter.write(chunks, to: fileURL)

        try Task.checkCancellation()  // last gate before any DB write

        let track = TrackRecord(
            id: "syn-\(audiobookID)-ch\(chapterIndex)", audiobookID: audiobookID,
            title: "Chapter \(chapterIndex + 1)", duration: duration,
            filePath: fileURL.path, isEnabled: true, sortOrder: chapterIndex,
            playlistPosition: nil, narrationVoice: voice.rawValue)

        // One atomic, idempotent transaction off the main thread: upsert the track
        // + every anchor so a re-render (e.g. a voice change) updates in place
        // instead of throwing on a duplicate primary key, and a failure can't
        // leave a half-written chapter.
        try await db.write { db in
            var savedTrack = track
            try savedTrack.save(db)
            for var anchor in anchors { try anchor.save(db) }
        }

        state.renderedChapterCount += 1
        logger.info("Rendered chapter \(chapterIndex) → \(anchors.count) anchors")
    }
}
