// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB
import Synchronization
@preconcurrency import WhisperKit
import os.log

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
    private var runGeneration = 0
    private var runToken = RunToken()

    private nonisolated final class RunToken: Sendable {
        private let cancelled = Mutex(false)
        func cancel() { cancelled.withLock { $0 = true } }
        func check() throws {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
        }
    }
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
        runGeneration &+= 1
        runToken = RunToken()

        timer = Timer.scheduledTimer(withTimeInterval: Config.interval, repeats: true) {
            [weak self] _ in
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
        runGeneration &+= 1
        runToken.cancel()
        timer?.invalidate()
        timer = nil
        let task = transcriptionTask
        transcriptionTask = nil
        whisperKit = nil  // sync: a restart re-acquires a fresh handle
        task?.cancel()

        // Wait for the in-flight transcription to unwind before releasing the
        // shared model: the task acquires the model internally, so releasing
        // before it finishes could out-release a still-resolving acquire and
        // leak/over-release the shared model.
        // Ownership/cancellation: https://github.com/dfakkeldy/Echo/pull/652
        Task {
            await task?.value
            WhisperSession.shared.release()
        }
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
        let generation = runGeneration
        transcriptionTask = Task {
            defer { isProcessing = false }
            do {
                try await loadModelIfNeeded(generation: generation)
                try checkRun(generation)
                let samples = try await AudioSegmentReader.samples(
                    from: fileURL, at: windowStart, duration: windowEnd - windowStart
                )
                try checkRun(generation)
                guard samples.count >= Int(Config.sampleRate * 2.0) else { return }

                guard let wk = whisperKit else { return }
                let words = await AlignmentTranscript.transcribeWords(
                    with: wk, samples: samples, captureStart: windowStart
                )
                try checkRun(generation)
                guard words.count >= Config.minWordsForAnchor else { return }

                await matchAndInsertAnchor(
                    words: words, windowStart: windowStart, windowEnd: windowEnd,
                    generation: generation)
            } catch {
                logger.error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func checkRun(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isRunning, generation == runGeneration else { throw CancellationError() }
    }

    private func loadModelIfNeeded(generation: Int) async throws {
        if whisperKit != nil { return }
        let model = try await WhisperSession.shared.acquire(model: Config.modelSize)
        try checkRun(generation)
        self.whisperKit = model
    }

    private func matchAndInsertAnchor(
        words: [TranscribedWord],
        windowStart: TimeInterval,
        windowEnd: TimeInterval,
        generation: Int
    ) async {
        let writer = blockDAO.db
        let bookID = audiobookID
        let match = await Self.matchCurrentWindow(
            writer: writer, bookID: bookID, words: words, windowStart: windowStart)
        guard (try? checkRun(generation)) != nil, let match else { return }

        guard
            let projected = AlignmentTranscript.projectBlockStart(
                words: words, matchedBlockWindowStart: match.bestWindowStart
            ), projected >= windowStart - 90, projected <= windowEnd
        else {
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

        do {
            try checkRun(generation)
            let token = runToken
            try await withTaskCancellationHandler {
                try await writer.write { connection in
                    try token.check()
                    var record = anchor
                    try record.upsert(connection)
                    try token.check()
                }
            } onCancel: {
                token.cancel()
            }
            try checkRun(generation)
            try await alignmentService.recalculateTimelineAsync()
        } catch { return }
        logger.info("Inserted continuous anchor for block \(match.block.id) at \(projected)s")
    }
    @concurrent
    private nonisolated static func matchCurrentWindow(
        writer: any DatabaseWriter, bookID: String, words: [TranscribedWord],
        windowStart: TimeInterval
    ) async -> AutoAlignmentTextMatcher.Match? {
        guard !Task.isCancelled,
            let blocks = try? EPubBlockDAO(db: writer).blocks(for: bookID),
            let timelineItems = try? TimelineDAO(db: writer).items(for: bookID)
        else { return nil }
        // Find current block based on timeline — use a single-pass scan
        // (O(N)) with indexed block positions, on the concurrent executor.
        let blockIndex = Dictionary(
            uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
        var currentBlockIdx = 0
        var bestTime: TimeInterval = 0
        for item in timelineItems {
            guard let blockID = item.epubBlockID else { continue }
            let time = item.audioStartTime
            if time <= windowStart, time >= bestTime {
                bestTime = time
                if let idx = blockIndex[blockID] {
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
        guard !Task.isCancelled else { return nil }
        return AutoAlignmentTextMatcher.findBestMatch(
            transcribedText: text, candidates: candidates, matchThreshold: Config.matchThreshold)
    }

}
