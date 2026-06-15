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

    private let trackDAO: TrackDAO
    private let anchorDAO: AlignmentAnchorDAO

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
        self.trackDAO = TrackDAO(db: db)
        self.anchorDAO = AlignmentAnchorDAO(db: db)
    }

    /// Render one chapter. Cancellable between blocks; on cancel, nothing is persisted.
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
            "\(audiobookID)-ch\(chapterIndex)-\(voice.rawValue).m4a")
        let duration = try await audioWriter.write(chunks, to: fileURL)

        try Task.checkCancellation()  // last gate before any DB write

        let track = TrackRecord(
            id: "syn-\(audiobookID)-ch\(chapterIndex)", audiobookID: audiobookID,
            title: "Chapter \(chapterIndex + 1)", duration: duration,
            filePath: fileURL.path, isEnabled: true, sortOrder: chapterIndex,
            playlistPosition: nil, narrationVoice: voice.rawValue)
        try trackDAO.insertAll([track], audiobookID: audiobookID)
        for anchor in anchors { try anchorDAO.insert(anchor) }

        state.renderedChapterCount += 1
        logger.info("Rendered chapter \(chapterIndex) → \(anchors.count) anchors")
    }
}
