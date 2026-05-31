import Accelerate
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
    let logger = Logger(subsystem: "com.orbitaudiobooks", category: "AutoAlignment")

    // MARK: - Dependencies

    let alignmentService: AlignmentService
    let blockDAO: EPubBlockDAO
    let anchorDAO: AlignmentAnchorDAO
    let timelineDAO: TimelineDAO
    let audiobookID: String
    let audioEngine: AudioEngine

    // MARK: - WhisperKit State

    var whisperKit: WhisperKit?
    var modelUnloadTimer: Timer?

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
        static let tier3CaptureDuration: TimeInterval = 3.0
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

    func runPipeline(chapters: [Chapter], blocks: [EPubBlockRecord]) async throws {
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

        // ── Tier 0: Silence Mapping ──
        state.phase = .tier1_ChapterSnap // Repurpose tier 1 UI for tier 0
        state.log("═══ Tier 0: Silence Mapping ═══")
        let silenceAnchors = try await runTier0(chapters: chapters, blocks: blocks)
        state.log("Tier 0 done: \(silenceAnchors) tentpole anchors created")
        logger.info("Tier 0 complete — \(silenceAnchors) anchors created")

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

    // MARK: - Block Time Estimation (shared by Tier 1 & Tier 3)

    /// Pre-computes estimated audio-time positions for every visible EPUB block
    /// using proportional word-count within each chapter.  Called once per
    /// pipeline run so Tier 1 and Tier 3 don't duplicate the same O(N) work.
    func estimateBlockTimes(
        blocks: [EPubBlockRecord],
        chapters: [Chapter],
        totalDuration: TimeInterval
    ) -> (allVisible: [EPubBlockRecord], estimatedTimeByBlockID: [String: TimeInterval]) {
        let allVisible = blocks.filter { !$0.isHidden }.sorted { $0.sequenceIndex < $1.sequenceIndex }
        var estimatedTimeByBlockID: [String: TimeInterval] = [:]

        let blocksByChapter = Dictionary(grouping: allVisible, by: { $0.chapterIndex })
        for ch in chapters {
            let chBlocks = blocksByChapter[ch.index] ?? []
            let chTotalWords = chBlocks.reduce(0.0) { $0 + Double(max(1, $1.wordCount ?? 1)) }
            var cumulative: Double = 0
            for block in chBlocks {
                let weight = Double(max(1, block.wordCount ?? 1))
                let midFraction = chTotalWords > 0 ? (cumulative + weight / 2.0) / chTotalWords : 0
                let span = ch.endSeconds - ch.startSeconds
                estimatedTimeByBlockID[block.id] = ch.startSeconds + midFraction * span
                cumulative += weight
            }
        }

        // Fallback for blocks without a chapter index
        let totalWordsGlobal = allVisible.reduce(0.0) { $0 + Double(max(1, $1.wordCount ?? 1)) }
        var cumulativeGlobal: Double = 0
        for block in allVisible {
            let weight = Double(max(1, block.wordCount ?? 1))
            let midFraction = totalWordsGlobal > 0 ? (cumulativeGlobal + weight / 2.0) / totalWordsGlobal : 0
            if estimatedTimeByBlockID[block.id] == nil {
                estimatedTimeByBlockID[block.id] = midFraction * totalDuration
            }
            cumulativeGlobal += weight
        }

        return (allVisible, estimatedTimeByBlockID)
    }

    // MARK: - Manual Alignment Fine-Tuning
    
    /// Auto-transcription for Manual Alignments
    /// Uses a 10s window (+/- 5s) around the specified time to locate the exact anchor position.
    func fineTuneManualAlignment(blockID: String, around time: TimeInterval) async throws -> TimeInterval? {
        let allBlocks = try blockDAO.blocks(for: audiobookID)
        guard let targetBlock = allBlocks.first(where: { $0.id == blockID }) else { return nil }
        
        let windowStart = max(0, time - 5.0)
        let duration = 10.0
        
        state.log("fine-tune: capturing \(duration)s at \(String(format: "%.1f", windowStart))s for block \(blockID)")
        
        guard let capture = try await captureAndTranscribe(at: windowStart, duration: duration), !capture.text.isEmpty else {
            state.log("fine-tune: capture/transcription failed or empty")
            return nil
        }
        
        // Single candidate text matching
        let candidates = [targetBlock]
        if let match = findBestMatch(transcribedText: capture.text, candidates: candidates, expectedIndex: 0) {
            let projected = AutoAlignmentTextMatcher.projectedBlockStart(
                windowStart: windowStart,
                firstWordOffset: capture.offset,
                captureDuration: duration,
                transcriptTokenCount: match.transcriptTokenCount,
                matchedBlockWindowStart: match.bestWindowStart
            )
            state.log("fine-tune ✓ conf: \(String(format: "%.2f", match.confidence)), aligned from \(String(format: "%.1f", time))s to \(String(format: "%.1f", projected))s")
            
            // Unload immediately after fine tuning since it's a one-off
            scheduleModelUnload()
            
            return projected
        } else {
            state.log("fine-tune ✗ no high-confidence match found in window")
            scheduleModelUnload()
            return nil
        }
    }

    // MARK: - Tier 0: Silence Mapping

    func runTier0(chapters: [Chapter],
                          blocks: [EPubBlockRecord]) async throws -> Int {
        guard let audioURL = audioEngine.audioFileURL else { return 0 }
        
        state.update(phase: .tier1_ChapterSnap, progress: 0.0, statusMessage: "Scanning audio for silences...")
        
        let silenceDetector = SilenceDetectionService(audioURL: audioURL)
        let silences = try await silenceDetector.detectSilences()
        
        var createdAnchors: [AlignmentAnchorRecord] = []
        let existingAnchors = try anchorDAO.anchors(for: audiobookID)
        let existingIDs = Set(existingAnchors.map { $0.epubBlockID })
        let iso = AlignmentService.isoFormatter
        let blocksByChapter = Dictionary(grouping: blocks, by: { $0.chapterIndex })
        
        for (idx, chapter) in chapters.enumerated() {
            let progress = Double(idx) / Double(max(1, chapters.count))
            state.update(phase: .tier1_ChapterSnap, progress: progress, statusMessage: "Mapping silence to chapter \(idx + 1)...")
            
            // Expected start is chapter.startSeconds. We allow a little slop.
            // If there's a silence ending within ~5 seconds of chapter.startSeconds, we use it.
            if let matchingSilence = silences.first(where: { abs($0.end - chapter.startSeconds) < 10.0 }) {
                guard let firstBlock = blocksByChapter[chapter.index]?.first else { continue }
                if existingIDs.contains(firstBlock.id) { continue }
                
                let anchor = AlignmentAnchorRecord(
                    id: "auto-silence-\(UUID().uuidString)",
                    audiobookID: audiobookID,
                    epubBlockID: firstBlock.id,
                    audioTime: matchingSilence.end,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue,
                    source: AlignmentAnchorRecord.Source.imported.rawValue,
                    note: "auto: silence mapped chapter start",
                    createdAt: iso.string(from: Date()),
                    modifiedAt: nil
                )
                createdAnchors.append(anchor)
                state.log("ch\(idx) silence ✓ mapped chapter start to \(String(format: "%.1f", matchingSilence.end))s")
            }
        }
        
        if !createdAnchors.isEmpty {
            try alignmentService.insertAnchors(createdAnchors)
        }
        
        return createdAnchors.count
    }

    // MARK: - Tier 1: Chapter Snap

    func runTier1(chapters: [Chapter],
                          blocks: [EPubBlockRecord]) async throws -> Int {
        let existingAnchors = try anchorDAO.anchors(for: audiobookID)
        var createdAnchors: [AlignmentAnchorRecord] = []
        let iso = AlignmentService.isoFormatter

        let (allVisible, estimatedTimeByBlockID) = estimateBlockTimes(
            blocks: blocks, chapters: chapters,
            totalDuration: audioEngine.duration ?? 1.0
        )
        let blocksByChapter = Dictionary(grouping: allVisible, by: { $0.chapterIndex })

        func blocksNear(_ time: TimeInterval, window: TimeInterval, limit: Int, preferredChapterIndex: Int? = nil) -> [EPubBlockRecord] {
            let filtered = allVisible.filter { 
                $0.chapterIndex == preferredChapterIndex || abs((estimatedTimeByBlockID[$0.id] ?? 0) - time) < window 
            }
            return filtered
                .sorted {
                    let c0 = ($0.chapterIndex == preferredChapterIndex) ? 0 : 1
                    let c1 = ($1.chapterIndex == preferredChapterIndex) ? 0 : 1
                    if c0 != c1 { return c0 < c1 }
                    return abs((estimatedTimeByBlockID[$0.id] ?? 0) - time) < abs((estimatedTimeByBlockID[$1.id] ?? 0) - time)
                }
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

                    // Dynamic Sample Sizing: Try larger windows if ambiguous or no match
                    let durations: [TimeInterval] = [Config.chapterStartCaptureDuration, 10.0, 15.0]
                    var finalMatch: AutoAlignmentTextMatcher.Match?
                    var finalCapture: (text: String, offset: TimeInterval)?
                    var finalDuration: TimeInterval = Config.chapterStartCaptureDuration
                    var finalCandidates: [EPubBlockRecord] = []

                    for duration in durations {
                        guard windowStart + duration < chapter.endSeconds - endMargin else { break }
                        
                        guard let capture = try await captureAndTranscribe(
                            at: windowStart, duration: duration
                        ), !capture.text.isEmpty else {
                            continue
                        }

                        // Filter to blocks near this time
                        let candidates = blocksNear(windowStart, window: 300, limit: 30, preferredChapterIndex: chapter.index)
                        
                        // Calculate expectedIndex to boost Locality Bias
                        var expectedIndex: Int?
                        if let bestExpected = candidates.enumerated().min(by: { abs((estimatedTimeByBlockID[$0.element.id] ?? 0) - windowStart) < abs((estimatedTimeByBlockID[$1.element.id] ?? 0) - windowStart) }) {
                            expectedIndex = bestExpected.offset
                        }

                        if let match = findBestMatch(transcribedText: capture.text,
                                                     candidates: candidates,
                                                     expectedIndex: expectedIndex) {
                            finalMatch = match
                            finalCapture = capture
                            finalDuration = duration
                            finalCandidates = candidates
                            break
                        }
                    }

                    guard let match = finalMatch, let capture = finalCapture else {
                        attempt += 1
                        continue
                    }
                    
                    let matched = match.block
                    let confidence = match.confidence
                    let transcribed = capture.text

                    // Anchor placement: if the matched block is the
                    // chapter's first visible block, the chapter audibly
                    // begins right when the audio chapter begins — use
                    // `chapter.startSeconds` directly. Otherwise the
                    // capture landed mid-block, so back-project from the
                    // matcher's window start to the block's first word.
                    let firstBlock = blocksByChapter[chapter.index]?.first
                    let isFirstBlockMatch = firstBlock?.id == matched.id
                    let projected = AutoAlignmentTextMatcher.projectedBlockStart(
                            windowStart: windowStart,
                            firstWordOffset: capture.offset,
                            captureDuration: finalDuration,
                            transcriptTokenCount: match.transcriptTokenCount,
                            matchedBlockWindowStart: match.bestWindowStart
                        )
                        let anchorTime = isFirstBlockMatch
                            ? chapter.startSeconds
                            : max(chapter.startSeconds, projected)
                        let preview = String(matched.text?.prefix(60) ?? "").replacingOccurrences(of: "\n", with: " ")
                        state.log("ch\(idx) start ✓ attempt \(attempt + 1): conf=\(String(format: "%.2f", confidence)) win=\(match.bestWindowStart) tok=\(match.transcriptTokenCount) anchor=\(String(format: "%.1f", anchorTime))s (\(isFirstBlockMatch ? "first-block" : "projected")) → \"\(preview)\"")
                        let anchor = AlignmentAnchorRecord(
                            id: "auto-start-\(UUID().uuidString)",
                            audiobookID: audiobookID,
                            epubBlockID: matched.id,
                            audioTime: anchorTime,
                            audioEndTime: nil,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue,
                            source: AlignmentAnchorRecord.Source.imported.rawValue,
                            note: "auto: ch\(idx) start (attempt \(attempt + 1), conf \(String(format: "%.2f", confidence)))",
                            createdAt: iso.string(from: Date()),
                            modifiedAt: nil
                        )
                        createdAnchors.append(anchor)
                        foundStart = true

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

                    // Dynamic Sample Sizing: Try larger windows if ambiguous or no match
                    let durations: [TimeInterval] = [Config.chapterEndCaptureDuration, 10.0, 15.0]
                    var finalMatch: AutoAlignmentTextMatcher.Match?
                    var finalCapture: (text: String, offset: TimeInterval)?
                    var finalDuration: TimeInterval = Config.chapterEndCaptureDuration

                    for duration in durations {
                        guard windowStart + duration < chapter.endSeconds else { break }
                        
                        guard let capture = try await captureAndTranscribe(
                            at: windowStart, duration: duration
                        ), !capture.text.isEmpty else {
                            continue
                        }

                        let candidates = blocksNear(windowStart, window: 300, limit: 30, preferredChapterIndex: chapter.index)
                        
                        var expectedIndex: Int?
                        if let bestExpected = candidates.enumerated().min(by: { abs((estimatedTimeByBlockID[$0.element.id] ?? 0) - windowStart) < abs((estimatedTimeByBlockID[$1.element.id] ?? 0) - windowStart) }) {
                            expectedIndex = bestExpected.offset
                        }

                        if let match = findBestMatch(transcribedText: capture.text,
                                                     candidates: candidates,
                                                     expectedIndex: expectedIndex) {
                            finalMatch = match
                            finalCapture = capture
                            finalDuration = duration
                            break
                        }
                    }

                    guard let match = finalMatch, let capture = finalCapture else {
                        attempt += 1
                        continue
                    }
                    
                    let matched = match.block
                    let confidence = match.confidence
                        // Chapter-end captures usually land deep inside the
                        // last paragraph, so back-project to that block's
                        // first-word time. Clamp inside chapter bounds.
                        let projected = AutoAlignmentTextMatcher.projectedBlockStart(
                            windowStart: windowStart,
                            firstWordOffset: capture.offset,
                            captureDuration: finalDuration,
                            transcriptTokenCount: match.transcriptTokenCount,
                            matchedBlockWindowStart: match.bestWindowStart
                        )
                        let anchorTime = max(chapter.startSeconds,
                                              min(chapter.endSeconds, projected))
                        let preview = String(matched.text?.prefix(60) ?? "").replacingOccurrences(of: "\n", with: " ")
                        state.log("ch\(idx) end ✓ attempt \(attempt + 1): conf=\(String(format: "%.2f", confidence)) win=\(match.bestWindowStart) tok=\(match.transcriptTokenCount) anchor=\(String(format: "%.1f", anchorTime))s → \"\(preview)\"")
                        let anchor = AlignmentAnchorRecord(
                            id: "auto-end-\(UUID().uuidString)",
                            audiobookID: audiobookID,
                            epubBlockID: matched.id,
                            audioTime: anchorTime,
                            audioEndTime: nil,
                            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterEnd.rawValue,
                            source: AlignmentAnchorRecord.Source.imported.rawValue,
                            note: "auto: ch\(idx) end (attempt \(attempt + 1), conf \(String(format: "%.2f", confidence)))",
                            createdAt: iso.string(from: Date()),
                            modifiedAt: nil
                        )
                        createdAnchors.append(anchor)
                        foundEnd = true

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

    func runTier2(chapters: [Chapter],
                          blocks: [EPubBlockRecord]) async throws -> [Int] {
        var flagged: [Int] = []

        for (idx, chapter) in chapters.enumerated() {
            try Task.checkCancellation()

            state.currentChapterIndex = idx
            let progress = Double(idx) / Double(max(1, chapters.count))
            state.update(phase: .tier2_DriftDetection, progress: progress,
                         statusMessage: "Checking chapter \(idx + 1) of \(chapters.count)…")

            let midpoint = (chapter.startSeconds + chapter.endSeconds) / 2.0
            
            // Find the expected block at this time from the interpolated timeline.
            guard let expectedBlock = blockAtTime(midpoint, blocks: blocks),
                  expectedBlock.text?.isEmpty == false else { continue }
            
            let durations: [TimeInterval] = [Config.driftCheckDuration, 10.0, 15.0]
            var driftDetected = false
            var bestConfidence = 0.0

            for duration in durations {
                guard let capture = try await captureAndTranscribe(at: midpoint, duration: duration),
                      !capture.text.isEmpty else { continue }
                      
                let confidence = AutoAlignmentTextMatcher.findBestMatch(
                    transcribedText: capture.text,
                    candidates: [expectedBlock],
                    matchThreshold: 0,
                    expectedIndex: 0
                )?.confidence ?? 0
                
                bestConfidence = max(bestConfidence, confidence)
                if confidence >= Config.driftConfidenceThreshold {
                    driftDetected = false
                    break // We verified it's clean, stop expanding duration
                } else {
                    driftDetected = true // Temporarily flagged as drifted, try longer sample
                }
            }

            if driftDetected {
                flagged.append(idx)
                state.log("ch\(idx) drift ⚠ conf=\(String(format: "%.2f", bestConfidence)) < threshold \(String(format: "%.2f", Config.driftConfidenceThreshold))")
                logger.warning("Chapter \(idx) drift detected (confidence: \(bestConfidence, privacy: .public))")
            }
        }

        return flagged
    }

    // MARK: - Tier 3: Drift Repair

    func runTier3(flaggedChapters: [Int],
                          chapters: [Chapter],
                          blocks: [EPubBlockRecord]) async throws -> Int {
        var repairAnchors: [AlignmentAnchorRecord] = []
        let iso = AlignmentService.isoFormatter

        let (allVisible, estimatedTimeByBlockID) = estimateBlockTimes(
            blocks: blocks, chapters: chapters,
            totalDuration: audioEngine.duration ?? 1.0
        )

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
                guard let capture = try await captureAndTranscribe(at: cp, duration: Config.tier3CaptureDuration),
                      !capture.text.isEmpty else { continue }
                let transcribed = capture.text

                // Match against blocks near this time, not against the
                // interpolated timeline (which may be way off for drifted chapters).
                let candidates = allVisible.filter {
                    $0.chapterIndex == chapter.index || abs((estimatedTimeByBlockID[$0.id] ?? 0) - cp) < 300
                }
                .sorted {
                    let c0 = ($0.chapterIndex == chapter.index) ? 0 : 1
                    let c1 = ($1.chapterIndex == chapter.index) ? 0 : 1
                    if c0 != c1 { return c0 < c1 }
                    return abs((estimatedTimeByBlockID[$0.id] ?? 0) - cp)
                    < abs((estimatedTimeByBlockID[$1.id] ?? 0) - cp)
                }
                .prefix(30)
                .map { $0 }

                guard let match = findBestMatch(transcribedText: transcribed,
                                                candidates: candidates) else {
                    state.log("ch\(chIdx) repair: no match at \(String(format: "%.0f", cp))s")
                    continue
                }
                let best = match.block

                // Back-project from the checkpoint capture to the matched
                // block's first-word audio time. Clamp inside chapter bounds.
                let projected = AutoAlignmentTextMatcher.projectedBlockStart(
                    windowStart: cp,
                    firstWordOffset: capture.offset,
                    captureDuration: Config.tier3CaptureDuration,
                    transcriptTokenCount: match.transcriptTokenCount,
                    matchedBlockWindowStart: match.bestWindowStart
                )
                let anchorTime = max(chapter.startSeconds,
                                      min(chapter.endSeconds, projected))

                let estimatedPos = estimatedTimeByBlockID[best.id] ?? 0
                let drift = abs(estimatedPos - cp)
                state.log("ch\(chIdx) repair: found \"\(String(best.text?.prefix(40) ?? ""))\" at est \(String(format: "%.0f", estimatedPos))s (drift \(String(format: "%.0f", drift))s) win=\(match.bestWindowStart) anchor=\(String(format: "%.1f", anchorTime))s")

                let anchor = AlignmentAnchorRecord(
                    id: "auto-repair-\(UUID().uuidString)",
                    audiobookID: audiobookID,
                    epubBlockID: best.id,
                    audioTime: anchorTime,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.imported.rawValue,
                    note: "auto: drift repair ch\(chIdx)",
                    createdAt: iso.string(from: Date()),
                    modifiedAt: nil
                )
                repairAnchors.append(anchor)
                state.log("ch\(chIdx) repair ✓ anchor inserted at \(String(format: "%.1f", anchorTime))s")
                driftTime = cp
                break
            }

            if driftTime == nil {
                state.log("ch\(chIdx) repair: no matches found to repair drift")
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
    func captureAndTranscribe(at time: TimeInterval,
                                      duration: TimeInterval) async throws -> (text: String, offset: TimeInterval)? {
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

        let capture = try await transcribe(samples)
        if capture.text.isEmpty {
            state.log("transcribed: (empty/silence)")
        } else {
            let preview = String(capture.text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            state.log("transcribed: \"\(preview)\" offset: \(String(format: "%.2f", capture.offset))s")
        }
        return capture.text.isEmpty ? nil : capture
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

    func loadWhisperModel() async throws {
        modelUnloadTimer?.invalidate()
        modelUnloadTimer = nil

        if whisperKit != nil { return }

        self.whisperKit = try await WhisperSession.shared.acquire(model: Config.modelSize)
    }

    func transcribe(_ audioArray: [Float]) async throws -> (text: String, offset: TimeInterval) {
        guard !audioArray.isEmpty else { return ("", 0) }

        guard let wk = whisperKit else {
            throw AutoAlignmentError.modelNotLoaded
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            wordTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: .vad
        )

        let results = await wk.transcribe(audioArrays: [audioArray],
                                           decodeOptions: options)

        let allSegments = results.compactMap { $0?.first?.segments }.flatMap { $0 }
        let wordOffset = TimeInterval(allSegments.first?.words?.first?.start ?? 0)

        let text = results
            .compactMap { $0?.first?.segments.map(\.text).joined(separator: " ") }
            .joined(separator: " ")
            .replacingOccurrences(of: "<\\|[^|]*\\|>",
                                 with: "",
                                 options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        scheduleModelUnload()

        return (text, wordOffset)
    }

    func scheduleModelUnload() {
        modelUnloadTimer?.invalidate()
        modelUnloadTimer = Timer.scheduledTimer(withTimeInterval: Config.modelKeepAliveSeconds,
                                                  repeats: false) { _ in
            Task { @MainActor in
                WhisperSession.shared.release()
            }
        }
    }

    // MARK: - Text Matching

    /// Finds the best-matching EPUB block for a given transcribed text.
    ///
    /// Uses a windowed text matcher so short transcripts can match inside
    /// long EPUB paragraphs.
    func findBestMatch(
        transcribedText: String,
        candidates: [EPubBlockRecord],
        expectedIndex: Int? = nil
    ) -> AutoAlignmentTextMatcher.Match? {
        AutoAlignmentTextMatcher.findBestMatch(
            transcribedText: transcribedText,
            candidates: candidates,
            matchThreshold: Config.matchThreshold,
            expectedIndex: expectedIndex
        )
    }

    // MARK: - Block Lookup Helpers

    /// Returns the EPUB block whose timeline item covers the given time,
    /// using the interpolated timeline.
    private func blockAtTime(_ time: TimeInterval,
                             blocks: [EPubBlockRecord]) -> EPubBlockRecord? {
        let blockByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })

        // Query timeline for items near this time.
        guard let timelineItems = try? timelineDAO.items(for: audiobookID) else { return nil }

        var bestItem: TimelineItem?
        for item in timelineItems.sorted(by: { $0.audioStartTime < $1.audioStartTime }) {
            guard item.audioStartTime >= 0, item.epubBlockID != nil else { continue }
            if item.audioStartTime <= time {
                bestItem = item
            } else {
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
