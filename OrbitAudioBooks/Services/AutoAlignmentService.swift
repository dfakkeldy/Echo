import AVFoundation
import Foundation
import GRDB
import os.log

@preconcurrency import WhisperKit

// MARK: - AutoAlignmentService

/// Orchestrates a progressive 3-tier auto-alignment pipeline that transcribes
/// strategic short audio clips with WhisperKit and matches them against EPUB
/// text to create alignment anchors automatically.
///
/// **Tier 1 — Chapter Snap:** Transcribes ~8 s at chapter start/end boundaries,
/// fuzzy-matches to nearby EPUB blocks, and inserts `chapterStart`/`chapterEnd`
/// anchors.
///
/// **Tier 2 — Drift Detection:** Transcribes ~5 s at each chapter midpoint and
/// compares against the interpolated timeline. Flags chapters where the
/// transcript diverges from the expected text.
///
/// **Tier 3 — Drift Repair:** Bisects flagged chapters to locate the drift point
/// and inserts a correction anchor.
@MainActor
final class AutoAlignmentService {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "AutoAlignment")

    // MARK: - Dependencies

    private let alignmentService: AlignmentService
    private let blockDAO: EPubBlockDAO
    private let anchorDAO: AlignmentAnchorDAO
    private let timelineDAO: TimelineDAO
    private let audiobookID: String
    private let audioEngine: AudioEngine

    // MARK: - WhisperKit State

    private var whisperKit: WhisperKit?
    private var modelUnloadTimer: Timer?
    private let whisperQueue = DispatchQueue(label: "com.orbitaudiobooks.whisperkit",
                                              qos: .userInitiated)

    // MARK: - Progress

    let state: AutoAlignmentState

    // MARK: - Configuration

    private nonisolated enum Config {
        static let chapterStartCaptureDuration: TimeInterval = 5.0
        static let chapterEndCaptureDuration: TimeInterval = 5.0
        static let driftCheckDuration: TimeInterval = 5.0
        static let preambleSkipDuration: TimeInterval = 8.0
        static let matchThreshold: Double = 0.35
        static let driftConfidenceThreshold: Double = 0.40
        static let modelKeepAliveSeconds: TimeInterval = 120.0
        static let modelSize: String = "base.en"
        static let sampleRate: Double = 16_000
        static let blockMatchWindowCount: Int = 20
    }

    // MARK: - Lifecycle

    init(db: DatabaseWriter, audiobookID: String, audioEngine: AudioEngine,
         state: AutoAlignmentState) {
        self.alignmentService = AlignmentService(db: db, audiobookID: audiobookID)
        self.blockDAO = EPubBlockDAO(db: db)
        self.anchorDAO = AlignmentAnchorDAO(db: db)
        self.timelineDAO = TimelineDAO(db: db)
        self.audiobookID = audiobookID
        self.audioEngine = audioEngine
        self.state = state
    }

    // MARK: - Public API

    /// Start the full 3-tier auto-alignment pipeline.
    ///
    /// - Parameters:
    ///   - chapters: The audiobook's chapter list (from `PlayerModel.alignmentPickerChapters`).
    ///   - blocks: All EPUB blocks for this audiobook, in reading order.
    /// - Returns: A cancellable `Task` the UI can store for cancellation.
    func startAutoAlignment(chapters: [Chapter], blocks: [EPubBlockRecord]) -> Task<Void, Error> {
        state.reset()
        state.totalChapters = chapters.count

        return Task {
            try await runPipeline(chapters: chapters, blocks: blocks)
        }
    }

    // MARK: - Pipeline Orchestration

    private func runPipeline(chapters: [Chapter], blocks: [EPubBlockRecord]) async throws {
        guard !chapters.isEmpty else {
            state.fail("No chapters found for this audiobook.")
            return
        }
        guard !blocks.isEmpty else {
            state.fail("No EPUB blocks found for this audiobook.")
            return
        }

        // ── Load model ──
        state.phase = .loadingModel
        state.update(phase: .loadingModel, progress: 0.0,
                     statusMessage: "Loading speech recognition model…")
        state.log("Loading WhisperKit model '\(Config.modelSize)'…")
        do {
            try await loadWhisperModel()
            state.log("Model loaded ✓")
        } catch {
            state.fail("Failed to load speech recognition model: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else { return }

        // ── Tier 1: Chapter Snap ──
        state.phase = .tier1_ChapterSnap
        state.log("═══ Tier 1: Chapter Snap — \(chapters.count) chapters ═══")
        let anchorCount = try await runTier1(chapters: chapters, blocks: blocks)
        state.log("Tier 1 done: \(anchorCount) anchors created")
        logger.info("Tier 1 complete — \(anchorCount) anchors created")

        guard !Task.isCancelled else { return }

        // ── Tier 2: Drift Detection ──
        state.phase = .tier2_DriftDetection
        state.log("═══ Tier 2: Drift Detection ═══")
        let flaggedChapters = try await runTier2(chapters: chapters, blocks: blocks)
        state.driftedChapterIDs = flaggedChapters
        state.log("Tier 2 done: \(flaggedChapters.count) flagged, \(chapters.count - flaggedChapters.count) clean")
        logger.info("Tier 2 complete — \(flaggedChapters.count) chapters flagged")

        guard !Task.isCancelled else { return }

        // ── Tier 3: Drift Repair ──
        if !flaggedChapters.isEmpty {
            state.phase = .tier3_DriftRepair
            state.log("═══ Tier 3: Drift Repair — \(flaggedChapters.count) chapters ═══")
            let repairs = try await runTier3(flaggedChapters: flaggedChapters,
                                               chapters: chapters, blocks: blocks)
            state.repairAnchorCount = repairs
            logger.info("Tier 3 complete — \(repairs) repair anchors inserted")
        }

        guard !Task.isCancelled else { return }

        state.log("═══ Pipeline complete: \(state.anchoredChapterCount) chapters anchored, \(state.driftedChapterIDs.count) drifted, \(state.repairAnchorCount) repairs ═══")
        state.complete()
        scheduleModelUnload()
    }

    // MARK: - Tier 1: Chapter Snap

    private func runTier1(chapters: [Chapter],
                          blocks: [EPubBlockRecord]) async throws -> Int {
        let existingAnchors = try anchorDAO.anchors(for: audiobookID)
        var createdAnchors: [AlignmentAnchorRecord] = []
        let iso = ISO8601DateFormatter()

        // Pre-compute estimated timeline positions for all visible blocks
        // using proportional word count.  This lets us select candidates by
        // audio time rather than EPUB chapter index — critical when the audio
        // chapter count differs from the EPUB chapter count (e.g. LibriVox
        // collections or multi-part M4Bs).
        let allVisible = blocks.filter { !$0.isHidden }.sorted { $0.sequenceIndex < $1.sequenceIndex }
        let totalWords = allVisible.reduce(0.0) { $0 + Double(max(1, $1.wordCount ?? 1)) }
        let totalDuration = audioEngine.duration ?? 1.0

        var estimatedTimeByBlockID: [String: TimeInterval] = [:]
        var cumulative: Double = 0
        for block in allVisible {
            let weight = Double(max(1, block.wordCount ?? 1))
            let midFraction = (cumulative + weight / 2.0) / totalWords
            estimatedTimeByBlockID[block.id] = midFraction * totalDuration
            cumulative += weight
        }

        /// Returns blocks whose estimated position is within `window` seconds of `time`,
        /// capped at `limit`. Prevents false matches against unrelated book sections.
        func blocksNear(_ time: TimeInterval, window: TimeInterval, limit: Int) -> [EPubBlockRecord] {
            allVisible
                .filter { abs((estimatedTimeByBlockID[$0.id] ?? 0) - time) < window }
                .prefix(limit)
                .map { $0 }
        }

        for (idx, chapter) in chapters.enumerated() {
            try Task.checkCancellation()

            state.currentChapterIndex = idx
            let baseProgress = Double(idx) / Double(max(1, chapters.count))

            let chapterDuration = chapter.endSeconds - chapter.startSeconds
            guard chapterDuration > 5 else {
                state.log("ch\(idx): skip — too short (\(String(format: "%.0f", chapterDuration))s)")
                continue
            }

            // Check whether a chapter-start anchor already exists near this boundary.
            let hasStartAnchor = existingAnchors.contains {
                $0.anchorKind == "chapterStart" && abs($0.audioTime - chapter.startSeconds) < 15
            }
            let hasEndAnchor = existingAnchors.contains {
                $0.anchorKind == "chapterEnd" && abs($0.audioTime - chapter.endSeconds) < 15
            }

            state.log("ch\(idx): \(allVisible.count) visible blocks total, duration \(String(format: "%.0f", chapterDuration))s, startAnchor:\(hasStartAnchor) endAnchor:\(hasEndAnchor)")

            // ── Chapter Start (sliding window, time-based candidates) ──
            if !hasStartAnchor {
                // For very short chapters use a smaller preamble skip so we
                // still have room to capture before the chapter ends.
                let effectivePreamble: TimeInterval = chapterDuration < 30
                    ? min(Config.preambleSkipDuration, chapterDuration * 0.3)
                    : Config.preambleSkipDuration

                let maxSearchOffset = min(chapterDuration * 0.40, 120.0)
                let windowAdvance = Config.chapterStartCaptureDuration * 0.75
                let maxAttempts = min(3, max(1, Int(maxSearchOffset / windowAdvance)))
                var attempt = 0
                var foundStart = false

                // Allow capture up to the chapter end minus a 5 % margin.
                let endMargin = chapterDuration * 0.05

                while attempt < maxAttempts, !foundStart {
                    try Task.checkCancellation()

                    let windowStart = chapter.startSeconds
                        + effectivePreamble
                        + (Double(attempt) * windowAdvance)

                    guard windowStart + Config.chapterStartCaptureDuration < chapter.endSeconds - endMargin else {
                        break
                    }

                    if attempt == 0 {
                        state.update(phase: .tier1_ChapterSnap, progress: baseProgress,
                                     statusMessage: "Chapter \(idx + 1) of \(chapters.count) — start…")
                    } else {
                        state.update(phase: .tier1_ChapterSnap, progress: baseProgress,
                                     statusMessage: "Chapter \(idx + 1) start — retrying further in…")
                    }

                    guard let transcribed = try await captureAndTranscribe(
                        at: windowStart, duration: Config.chapterStartCaptureDuration
                    ), !transcribed.isEmpty else {
                        attempt += 1
                        continue
                    }

                    // Filter to blocks near this time to prevent false matches
                    // across unrelated parts of the book.
                    let candidates = blocksNear(windowStart, window: 300, limit: 30)
                    if let (matched, confidence) = findBestMatch(transcribedText: transcribed,
                                                                  candidates: candidates) {
                        let preview = String(matched.text?.prefix(60) ?? "").replacingOccurrences(of: "\n", with: " ")
                        state.log("ch\(idx) start ✓ attempt \(attempt + 1): conf=\(String(format: "%.2f", confidence)) offset=\(String(format: "%.0f", windowStart - chapter.startSeconds))s → \"\(preview)\"")
                        let anchor = AlignmentAnchorRecord(
                            id: "auto-start-\(UUID().uuidString)",
                            audiobookID: audiobookID,
                            epubBlockID: matched.id,
                            audioTime: windowStart,
                            audioEndTime: nil,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue,
                            source: AlignmentAnchorRecord.Source.imported.rawValue,
                            note: "auto: ch\(idx) start (attempt \(attempt + 1), conf \(String(format: "%.2f", confidence)))",
                            createdAt: iso.string(from: Date()),
                            modifiedAt: nil
                        )
                        createdAnchors.append(anchor)
                        foundStart = true
                    } else {
                        let preview = String(transcribed.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                        state.log("ch\(idx) start ✗ attempt \(attempt + 1): no match for \"\(preview)\"")
                    }
                    attempt += 1
                }
                if !foundStart {
                    state.log("ch\(idx) start ✗ all \(attempt) attempts exhausted")
                }
            } else {
                state.log("ch\(idx) start → already anchored")
            }

            // ── Chapter End (sliding window backwards, time-based candidates) ──
            if !hasEndAnchor, chapterDuration > 15 {
                let subProgress = baseProgress + (0.5 / Double(max(1, chapters.count)))
                let maxAttempts = 3
                var attempt = 0
                var foundEnd = false

                while attempt < maxAttempts, !foundEnd {
                    try Task.checkCancellation()

                    let windowStart = chapter.endSeconds
                        - Config.chapterEndCaptureDuration
                        - (Double(attempt) * Config.chapterEndCaptureDuration)

                    guard windowStart > chapter.startSeconds + 15 else { break }

                    if attempt == 0 {
                        state.update(phase: .tier1_ChapterSnap, progress: subProgress,
                                     statusMessage: "Chapter \(idx + 1) of \(chapters.count) — end…")
                    }

                    guard let transcribed = try await captureAndTranscribe(
                        at: windowStart, duration: Config.chapterEndCaptureDuration
                    ), !transcribed.isEmpty else {
                        attempt += 1
                        continue
                    }

                    let candidates = blocksNear(windowStart, window: 300, limit: 30)
                    if let (matched, confidence) = findBestMatch(transcribedText: transcribed,
                                                                  candidates: candidates) {
                        let preview = String(matched.text?.prefix(60) ?? "").replacingOccurrences(of: "\n", with: " ")
                        state.log("ch\(idx) end ✓ attempt \(attempt + 1): conf=\(String(format: "%.2f", confidence)) → \"\(preview)\"")
                        let anchor = AlignmentAnchorRecord(
                            id: "auto-end-\(UUID().uuidString)",
                            audiobookID: audiobookID,
                            epubBlockID: matched.id,
                            audioTime: windowStart,
                            audioEndTime: nil,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterEnd.rawValue,
                            source: AlignmentAnchorRecord.Source.imported.rawValue,
                            note: "auto: ch\(idx) end (attempt \(attempt + 1), conf \(String(format: "%.2f", confidence)))",
                            createdAt: iso.string(from: Date()),
                            modifiedAt: nil
                        )
                        createdAnchors.append(anchor)
                        foundEnd = true
                    } else {
                        let preview = String(transcribed.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                        state.log("ch\(idx) end ✗ attempt \(attempt + 1): no match for \"\(preview)\"")
                    }
                    attempt += 1
                }
                if !foundEnd {
                    state.log("ch\(idx) end ✗ all \(attempt) attempts exhausted")
                }
            } else if hasEndAnchor {
                state.log("ch\(idx) end → already anchored")
            }
        }

        if !createdAnchors.isEmpty {
            try alignmentService.insertAnchors(createdAnchors)
        }

        state.anchoredChapterCount = createdAnchors.count / 2
        return createdAnchors.count
    }

    // MARK: - Tier 2: Drift Detection

    private func runTier2(chapters: [Chapter],
                          blocks: [EPubBlockRecord]) async throws -> [Int] {
        var flagged: [Int] = []

        for (idx, chapter) in chapters.enumerated() {
            try Task.checkCancellation()

            state.currentChapterIndex = idx
            let progress = Double(idx) / Double(max(1, chapters.count))
            state.update(phase: .tier2_DriftDetection, progress: progress,
                         statusMessage: "Checking chapter \(idx + 1) of \(chapters.count)…")

            let midpoint = (chapter.startSeconds + chapter.endSeconds) / 2.0
            guard let transcribed = try await captureAndTranscribe(at: midpoint,
                                                                    duration: Config.driftCheckDuration),
                  !transcribed.isEmpty else { continue }

            // Find the expected block at this time from the interpolated timeline.
            guard let expectedBlock = blockAtTime(midpoint, blocks: blocks),
                  let expectedText = expectedBlock.text, !expectedText.isEmpty else { continue }

            let confidence = transcribed.normalizedLevenshteinSimilarity(to: expectedText)
            if confidence < Config.driftConfidenceThreshold {
                flagged.append(idx)
                state.log("ch\(idx) drift ⚠ conf=\(String(format: "%.2f", confidence)) < threshold \(String(format: "%.2f", Config.driftConfidenceThreshold))")
                logger.warning("Chapter \(idx) drift detected (confidence: \(confidence, privacy: .public))")
            }
        }

        return flagged
    }

    // MARK: - Tier 3: Drift Repair

    private func runTier3(flaggedChapters: [Int],
                          chapters: [Chapter],
                          blocks: [EPubBlockRecord]) async throws -> Int {
        var repairAnchors: [AlignmentAnchorRecord] = []
        let iso = ISO8601DateFormatter()

        // Use all visible blocks with estimated positions, same as Tier 1.
        let allVisible = blocks.filter { !$0.isHidden }.sorted { $0.sequenceIndex < $1.sequenceIndex }
        let totalWords = allVisible.reduce(0.0) { $0 + Double(max(1, $1.wordCount ?? 1)) }
        let totalDuration = audioEngine.duration ?? 1.0

        var estimatedTimeByBlockID: [String: TimeInterval] = [:]
        var cumulative: Double = 0
        for block in allVisible {
            let weight = Double(max(1, block.wordCount ?? 1))
            let midFraction = (cumulative + weight / 2.0) / totalWords
            estimatedTimeByBlockID[block.id] = midFraction * totalDuration
            cumulative += weight
        }

        func nearestBlock(to time: TimeInterval) -> EPubBlockRecord? {
            allVisible.min(by: {
                abs((estimatedTimeByBlockID[$0.id] ?? 0) - time)
                < abs((estimatedTimeByBlockID[$1.id] ?? 0) - time)
            })
        }

        for (tierIdx, chIdx) in flaggedChapters.enumerated() {
            try Task.checkCancellation()

            let chapter = chapters[chIdx]
            let baseProgress = Double(tierIdx) / Double(max(1, flaggedChapters.count))
            state.currentChapterIndex = chIdx
            state.update(phase: .tier3_DriftRepair, progress: baseProgress,
                         statusMessage: "Repairing chapter \(chIdx + 1)…")

            let span = chapter.endSeconds - chapter.startSeconds
            let checkPoints: [TimeInterval] = [
                chapter.startSeconds + span * 0.25,
                chapter.startSeconds + span * 0.50,
                chapter.startSeconds + span * 0.75,
            ]

            var driftTime: TimeInterval?
            for cp in checkPoints {
                guard let transcribed = try await captureAndTranscribe(at: cp, duration: 3.0),
                      !transcribed.isEmpty else { continue }

                // Match against blocks near this time, not against the
                // interpolated timeline (which may be way off for drifted chapters).
                let candidates = allVisible.filter {
                    abs((estimatedTimeByBlockID[$0.id] ?? 0) - cp) < 120
                }.prefix(20).map { $0 }

                guard let (best, _) = findBestMatch(transcribedText: transcribed,
                                                     candidates: candidates) else {
                    state.log("ch\(chIdx) repair: no match at \(String(format: "%.0f", cp))s")
                    continue
                }

                let estimatedPos = estimatedTimeByBlockID[best.id] ?? 0
                let drift = abs(estimatedPos - cp)
                state.log("ch\(chIdx) repair: found \"\(String(best.text?.prefix(40) ?? ""))\" at est \(String(format: "%.0f", estimatedPos))s (drift \(String(format: "%.0f", drift))s)")

                if drift > 30 {
                    driftTime = cp
                    if let repairBlock = nearestBlock(to: cp) {
                        let anchor = AlignmentAnchorRecord(
                            id: "auto-repair-\(UUID().uuidString)",
                            audiobookID: audiobookID,
                            epubBlockID: repairBlock.id,
                            audioTime: cp,
                            audioEndTime: nil,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                            source: AlignmentAnchorRecord.Source.imported.rawValue,
                            note: "auto: drift repair ch\(chIdx)",
                            createdAt: iso.string(from: Date()),
                            modifiedAt: nil
                        )
                        repairAnchors.append(anchor)
                        state.log("ch\(chIdx) repair ✓ anchor inserted at \(String(format: "%.0f", cp))s")
                    }
                    break
                }
            }

            if driftTime == nil {
                state.log("ch\(chIdx) repair: no significant drift found")
            }
        }

        if !repairAnchors.isEmpty {
            try alignmentService.insertAnchors(repairAnchors)
        }
        return repairAnchors.count
    }

    // MARK: - Audio Capture + Transcription

    /// Reads `duration` seconds of audio starting at `time` from the audio
    /// file, converts to 16 kHz mono Float32, and transcribes with WhisperKit.
    ///
    /// Uses direct file reading rather than a real-time tap, so it does not
    /// interrupt playback or require format conversion on the mixer bus.
    private func captureAndTranscribe(at time: TimeInterval,
                                      duration: TimeInterval) async throws -> String? {
        guard let fileURL = audioEngine.audioFileURL else {
            state.log("capture: no audio file loaded")
            return nil
        }

        let maxTime = audioEngine.duration ?? 0
        guard maxTime > 0, time < maxTime else {
            state.log("capture: bad time \(String(format: "%.1f", time)) max=\(String(format: "%.1f", maxTime))")
            return nil
        }

        let clampedTime = max(0, min(time, maxTime - duration))

        // Read the audio segment on a background queue.
        let samples: [Float] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let file = try AVAudioFile(forReading: fileURL)
                    let fileFormat = file.processingFormat
                    let fileSampleRate = fileFormat.sampleRate

                    let startFrame = AVAudioFramePosition(clampedTime * fileSampleRate)
                    let frameCount = AVAudioFrameCount(duration * fileSampleRate)
                    let totalFrames = file.length

                    guard startFrame < totalFrames else {
                        continuation.resume(returning: [])
                        return
                    }
                    let actualFrames = min(frameCount, AVAudioFrameCount(totalFrames - startFrame))

                    file.framePosition = startFrame

                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: fileFormat, frameCapacity: actualFrames
                    ) else {
                        continuation.resume(throwing: AutoAlignmentError.captureFailed)
                        return
                    }

                    try file.read(into: buffer)

                    // Convert to 16 kHz mono Float32 if needed.
                    guard let floatData = self.convertTo16kHzMono(
                        buffer: buffer,
                        sourceFormat: fileFormat
                    ) else {
                        continuation.resume(throwing: AutoAlignmentError.captureFailed)
                        return
                    }

                    continuation.resume(returning: floatData)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard samples.count >= Int(Config.sampleRate * 1.0) else {
            state.log("capture: only \(samples.count) samples at \(String(format: "%.1f", clampedTime))s (need \(Int(Config.sampleRate)))")
            return nil
        }

        let text = try await transcribe(samples)
        if text.isEmpty {
            state.log("transcribed: (empty/silence)")
        } else {
            let preview = String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            state.log("transcribed: \"\(preview)\"")
        }
        return text.isEmpty ? nil : text
    }

    /// Converts an audio buffer to 16 kHz mono Float32 samples.
    /// Non-isolated so it can be called from the background file-reading queue.
    private nonisolated func convertTo16kHzMono(buffer: AVAudioPCMBuffer,
                                                 sourceFormat: AVAudioFormat) -> [Float]? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        // If the source already matches, copy directly.
        if sourceFormat.sampleRate == Config.sampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            guard let channelData = buffer.floatChannelData else { return nil }
            let count = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }

        // Convert via AVAudioConverter.
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        let inputFrames = buffer.frameLength
        let outputFrames = AVAudioFrameCount(
            Double(inputFrames) * (Config.sampleRate / sourceFormat.sampleRate)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outputFrames
        ) else { return nil }

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        if status == .error || conversionError != nil {
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    // MARK: - WhisperKit

    private func loadWhisperModel() async throws {
        modelUnloadTimer?.invalidate()
        modelUnloadTimer = nil

        if whisperKit != nil { return }

        return try await withCheckedThrowingContinuation { continuation in
            whisperQueue.async {
                Task {
                    do {
                        let wk = try await WhisperKit(model: Config.modelSize)
                        await MainActor.run { [weak self] in
                            self?.whisperKit = wk
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func transcribe(_ audioArray: [Float]) async throws -> String {
        guard !audioArray.isEmpty else { return "" }

        // Capture whisperKit on the main actor before dispatching to the
        // background queue, since it is @MainActor-isolated.
        let wk = whisperKit
        guard let wk else {
            throw AutoAlignmentError.modelNotLoaded
        }

        return try await withCheckedThrowingContinuation { continuation in
            whisperQueue.async {
                Task {
                    let options = DecodingOptions(
                        task: .transcribe,
                        language: "en",
                        temperature: 0.0,
                        suppressBlank: true,
                        chunkingStrategy: .vad
                    )

                    let results = await wk.transcribe(audioArrays: [audioArray],
                                                       decodeOptions: options)

                    let text = results
                        .compactMap { $0?.first?.segments.map(\.text).joined(separator: " ") }
                        .joined(separator: " ")
                        .replacingOccurrences(of: "<\\|[^|]*\\|>",
                                             with: "",
                                             options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)

                    await MainActor.run { [weak self] in
                        self?.scheduleModelUnload()
                    }

                    continuation.resume(returning: text)
                }
            }
        }
    }

    private func scheduleModelUnload() {
        modelUnloadTimer?.invalidate()
        modelUnloadTimer = Timer.scheduledTimer(withTimeInterval: Config.modelKeepAliveSeconds,
                                                  repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.whisperKit?.unloadModels()
                self?.whisperKit = nil
            }
        }
    }

    // MARK: - Text Matching

    /// Finds the best-matching EPUB block for a given transcribed text.
    ///
    /// Uses both full-string Levenshtein similarity and word-level Jaccard
    /// similarity (intersection over union of words), taking the higher score.
    private func findBestMatch(transcribedText: String,
                               candidates: [EPubBlockRecord]) -> (EPubBlockRecord, Double)? {
        let tsWords = wordSet(transcribedText)
        var best: (EPubBlockRecord, Double)?

        for candidate in candidates {
            guard let text = candidate.text, !text.isEmpty else { continue }

            // String-level Levenshtein.
            let stringConf = transcribedText.normalizedLevenshteinSimilarity(to: text)

            // Word-level Jaccard: intersection / union.
            let candWords = wordSet(text)
            let wordConf: Double
            if tsWords.isEmpty || candWords.isEmpty {
                wordConf = 0
            } else {
                let intersection = tsWords.intersection(candWords).count
                let union = tsWords.union(candWords).count
                wordConf = union > 0 ? Double(intersection) / Double(union) : 0
            }

            let confidence = max(stringConf, wordConf)
            if confidence > (best?.1 ?? 0) {
                best = (candidate, confidence)
            }
        }

        guard let result = best, result.1 >= Config.matchThreshold else { return nil }
        return result
    }

    /// Lowercases, strips punctuation, and splits into a Set of words.
    private func wordSet(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 2 }
        return Set(words)
    }

    // MARK: - Block Lookup Helpers

    /// Returns the EPUB block whose timeline item covers the given time,
    /// using the interpolated timeline.
    private func blockAtTime(_ time: TimeInterval,
                             blocks: [EPubBlockRecord]) -> EPubBlockRecord? {
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })

        // Query timeline for items near this time.
        let margin: TimeInterval = 5.0
        guard let timelineItems = try? timelineDAO.items(
            in: (time - margin)...(time + margin),
            audiobookID: audiobookID
        ) else { return nil }

        var bestItem: TimelineItem?
        for item in timelineItems {
            guard item.audioStartTime >= 0,
                  item.epubBlockID != nil else { continue }
            let end = item.audioEndTime ?? (item.audioStartTime + 3600)
            if time >= item.audioStartTime && time < end {
                bestItem = item
                break
            }
        }

        guard let matchedBlockID = bestItem?.epubBlockID else { return nil }
        return blockByID[matchedBlockID]
    }

}

// MARK: - AutoAlignmentError

enum AutoAlignmentError: LocalizedError {
    case modelNotLoaded
    case captureFailed
    case noChapters
    case noBlocks

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Speech recognition model is not loaded."
        case .captureFailed:
            return "Failed to capture audio for transcription."
        case .noChapters:
            return "No chapters found in this audiobook."
        case .noBlocks:
            return "No EPUB text blocks found for this audiobook."
        }
    }
}
