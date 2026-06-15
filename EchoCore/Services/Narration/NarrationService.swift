import FluidAudio
import Foundation
import GRDB
import os.log

enum NarrationError: Error, Equatable {
    case synthesisFailed
    case audiobookNotFound
    /// A single sub-chunk exceeded the model's input length cap. Surfaced so a
    /// test double can exercise the "skip this sub-chunk, keep the chapter"
    /// path; the real engine raises FluidAudio's `KokoroAneError` length cases.
    case lengthCapExceeded
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

            // FluidAudio does no internal chunking and caps IPA input at ~510
            // phonemes — feeding a whole 400+ char block in one synthesize call
            // drives the palettized vocoder into a dynamic BNNS tensor shape that
            // traps (uncatchable SIGTRAP). Bound each call to a small, predictable
            // run. One anchor per ORIGINAL block (keyed on block.id) is preserved
            // by spanning the summed sub-chunk durations, so read-along is unchanged.
            var blockDuration: TimeInterval = 0
            for subText in NarrationTextChunker.split(text) {
                try Task.checkCancellation()
                do {
                    let chunk = try await tts.synthesize(subText, voice: voice)
                    chunks.append(chunk)
                    blockDuration += chunk.duration
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error where Self.isLengthCapError(error) {
                    // A length-cap throw from one sub-chunk must not abort the
                    // whole chapter — skip it and keep going.
                    logger.error(
                        "Skipping over-long sub-chunk in block \(block.id): \(error.localizedDescription)"
                    )
                    continue
                }
            }

            anchors.append(
                AlignmentAnchorRecord(
                    id: "syn-\(audiobookID)-\(block.id)",
                    audiobookID: audiobookID, epubBlockID: block.id,
                    audioTime: cursor, audioEndTime: cursor + blockDuration,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.synthesized.rawValue,
                    note: nil, createdAt: now, modifiedAt: now))
            cursor += blockDuration
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

    /// True for an error that means a single sub-chunk overran the model's input
    /// length cap, so the caller should skip it rather than abort the chapter.
    /// Covers FluidAudio's two length cases plus our own test marker.
    private static func isLengthCapError(_ error: Error) -> Bool {
        if case NarrationError.lengthCapExceeded = error { return true }
        if let k = error as? KokoroAneError {
            switch k {
            case .phonemeSequenceTooLong, .acousticFramesExceedCap:
                return true
            default:
                return false
            }
        }
        return false
    }
}
