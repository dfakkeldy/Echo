import Foundation
import AVFoundation
import GRDB
import os.log
@preconcurrency import WhisperKit

/// Opt-in background service that periodically transcribes the audio around
/// the playback position and inserts correction anchors when the transcript
/// confidently matches a nearby EPUB block.
///
/// Captures by reading the audio *file* directly at the player's media time.
/// The previous implementation tapped the output mixer, which sits after the
/// time-pitch node — at 1.25× playback every captured window was
/// time-compressed, so wall-clock sample counts mapped to the wrong media
/// times and every anchor landed early by the speed factor.
@MainActor
final class ContinuousAlignmentService {
    private let logger = Logger(category: "ContinuousAlignment")

    // Dependencies
    private let audioEngine: AudioEngine
    private let alignmentService: AlignmentService
    private let timelineDAO: TimelineDAO
    private let blockDAO: EPubBlockDAO
    private let audiobookID: String

    // State
    private var isRunning = false
    private var isProcessing = false
    private var timer: Timer?
    private var transcriptionTask: Task<Void, Never>?

    // WhisperKit
    private var whisperKit: WhisperKit?

    // Configuration
    private nonisolated enum Config {
        static let interval: TimeInterval = 15.0
        static let sampleRate: Double = 16_000
        static let modelSize = "base.en"
        static let matchThreshold = 0.35
        /// Fewer transcribed words than this means music or silence — not
        /// enough signal to risk an anchor.
        static let minWordsForAnchor = 8
    }

    init(audioEngine: AudioEngine, db: DatabaseWriter, audiobookID: String) {
        self.audioEngine = audioEngine
        self.alignmentService = AlignmentService(db: db, audiobookID: audiobookID)
        self.timelineDAO = TimelineDAO(db: db)
        self.blockDAO = EPubBlockDAO(db: db)
        self.audiobookID = audiobookID
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        timer = Timer.scheduledTimer(withTimeInterval: Config.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.processCurrentWindow()
            }
        }
        logger.info("Continuous alignment started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        timer?.invalidate()
        timer = nil

        WhisperSession.shared.release()
        whisperKit = nil
        logger.info("Continuous alignment stopped")
    }

    private func processCurrentWindow() {
        guard !isProcessing else {
            logger.info("Skipping window — previous transcription still in progress")
            return
        }
        guard let fileURL = audioEngine.audioFileURL else { return }

        // Media-time window ending at the playback position. Reading the
        // file keeps the window on the media clock regardless of playback
        // speed and feeds Whisper clean 1× audio.
        let windowEnd = audioEngine.currentTime
        let windowStart = max(0, windowEnd - Config.interval)
        guard windowEnd - windowStart >= 2.0 else { return }

        isProcessing = true
        transcriptionTask = Task {
            defer { isProcessing = false }
            do {
                try await loadModelIfNeeded()
                let samples = try await AudioSegmentReader.samples(
                    from: fileURL, at: windowStart, duration: windowEnd - windowStart
                )
                guard samples.count >= Int(Config.sampleRate * 2.0) else { return }

                guard let wk = whisperKit else { return }
                let words = await AlignmentTranscript.transcribeWords(
                    with: wk, samples: samples, captureStart: windowStart
                )
                guard words.count >= Config.minWordsForAnchor else { return }

                await matchAndInsertAnchor(words: words, windowStart: windowStart, windowEnd: windowEnd)
            } catch {
                logger.error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadModelIfNeeded() async throws {
        if whisperKit != nil { return }
        self.whisperKit = try await WhisperSession.shared.acquire(model: Config.modelSize)
    }

    private func matchAndInsertAnchor(words: [TranscribedWord],
                                      windowStart: TimeInterval,
                                      windowEnd: TimeInterval) async {
        guard let blocks = try? blockDAO.blocks(for: audiobookID) else { return }
        guard let timelineItems = try? timelineDAO.items(for: audiobookID) else { return }

        // Find current block based on timeline — use a single-pass scan
        // (O(N)) instead of sorting the entire timeline (O(N log N)) to avoid
        // main-thread stalls every 15 seconds.
        var currentBlockIdx = 0
        var bestTime: TimeInterval = 0
        for item in timelineItems {
            guard let blockID = item.epubBlockID else { continue }
            let time = item.audioStartTime
            if time <= windowStart, time >= bestTime {
                bestTime = time
                if let idx = blocks.firstIndex(where: { $0.id == blockID }) {
                    currentBlockIdx = idx
                }
            }
        }

        // Search window of candidates around the current position
        let searchWindow = 10
        let startIdx = max(0, currentBlockIdx - searchWindow)
        let endIdx = min(blocks.count, currentBlockIdx + searchWindow)
        let candidates = Array(blocks[startIdx..<endIdx])

        let text = words.map(\.text).joined(separator: " ")
        guard let match = AutoAlignmentTextMatcher.findBestMatch(
            transcribedText: text, candidates: candidates, matchThreshold: Config.matchThreshold
        ) else { return }

        guard let projected = AlignmentTranscript.projectBlockStart(
            words: words, matchedBlockWindowStart: match.bestWindowStart
        ), projected >= windowStart - 90, projected <= windowEnd else {
            logger.info("Continuous match for \(match.block.id) projected out of range — skipped")
            return
        }

        let anchor = AlignmentAnchorRecord(
            id: "auto-continuous-\(UUID().uuidString)",
            audiobookID: audiobookID,
            epubBlockID: match.block.id,
            audioTime: projected,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.continuousBackground.rawValue,
            note: "Continuous auto-alignment",
            createdAt: AlignmentService.isoFormatter.string(from: Date()),
            modifiedAt: nil
        )

        try? alignmentService.insertAnchors([anchor])
        logger.info("Inserted continuous anchor for block \(match.block.id) at \(projected)s")
    }
}
