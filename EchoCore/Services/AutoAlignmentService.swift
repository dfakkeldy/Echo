import AVFoundation
import Accelerate
import Foundation
import GRDB
@preconcurrency import WhisperKit
import os.log

// MARK: - AutoAlignmentService

/// Orchestrates the progressive auto-alignment pipeline that transcribes
/// audio with WhisperKit and matches it against EPUB text to create
/// alignment anchors automatically.
///
/// **Tier 0 — Metadata Title Matching:** Fuzzy-matches audiobook chapter
/// titles (from M4B metadata) against EPUB heading blocks before any
/// transcription. Generic track labels ("Chapter 7", "12") are skipped —
/// they number tracks, not book chapters, so only descriptive titles can
/// bootstrap anchors. Tier 0 anchors are bootstraps, not final answers:
/// content alignment still runs and supersedes them with precise times.
///
/// **Content Alignment (VAD + DTW):** For every chapter, captures bounded
/// audio chunks (`AlignmentChunkPlanner`), transcribes them with word-level
/// timestamps (`AlignmentTranscript`), and aligns transcript tokens against
/// the chapter's EPUB blocks — plus a slack margin of neighbouring-chapter
/// blocks for text mis-binned across the estimated boundary — with
/// `TokenDTW.alignWithBisection`. Only candidates inside a strong match run
/// survive `AnchorSelector`; blocks whose text was never narrated get no
/// anchor at all and are bridged by interpolation instead.
///
/// Each run first deletes anchors created by previous automatic passes
/// (`auto-tier0-` / `auto-dtw-` / `auto-continuous-` prefixes) so
/// re-alignment can correct earlier results. Human-made anchors survive and
/// their blocks are never re-anchored.
@MainActor
final class AutoAlignmentService {
    let logger = Logger(category: "AutoAlignment")

    // MARK: - Dependencies

    let alignmentService: AlignmentService
    let blockDAO: EPubBlockDAO
    let anchorDAO: AlignmentAnchorDAO
    let timelineDAO: TimelineDAO
    let audiobookID: String
    let audioEngine: AudioEngine

    // MARK: - WhisperKit State

    private var whisperKit: WhisperKit?
    var modelUnloadTimer: Timer?

    // MARK: - Progress

    let state: AutoAlignmentState

    // MARK: - Configuration

    private nonisolated enum Config {
        static let matchThreshold: Double = 0.35
        static let modelKeepAliveSeconds: TimeInterval = 120.0
        static let modelSize: String = "base.en"
        static let sampleRate: Double = 16_000
        /// Capture chunk bounds for the planner.
        static let minChunkSeconds: TimeInterval = 15.0
        static let maxChunkSeconds: TimeInterval = 45.0
        /// Blocks borrowed from each neighbouring chapter so text mis-binned
        /// across an estimated chapter boundary can still anchor.
        static let boundarySlackBlockCount = 12
        /// Minimum strong-run length for an anchor to be kept.
        static let minAnchorRunLength = 3
        /// Candidates may land slightly outside the chapter's audio window
        /// (slack blocks near boundaries); anything further out is dropped.
        static let chapterWindowSlack: TimeInterval = 30.0
    }

    // MARK: - Lifecycle

    init(
        db: DatabaseWriter, audiobookID: String, audioEngine: AudioEngine,
        state: AutoAlignmentState
    ) {
        self.alignmentService = AlignmentService(db: db, audiobookID: audiobookID)
        self.blockDAO = EPubBlockDAO(db: db)
        self.anchorDAO = AlignmentAnchorDAO(db: db)
        self.timelineDAO = TimelineDAO(db: db)
        self.audiobookID = audiobookID
        self.audioEngine = audioEngine
        self.state = state
    }

    deinit {
        // Stop the keep-alive timer and release any held model on dealloc, so a
        // dropped service doesn't leave the ~40 MB model resident until the
        // timer fires (CODE_AUDIT.md §3.6). Race-free with the timer because its
        // release path is now synchronous (MainActor.assumeIsolated).
        MainActor.assumeIsolated {
            modelUnloadTimer?.invalidate()
            if whisperKit != nil {
                WhisperSession.shared.release()
                whisperKit = nil
            }
        }
    }

    // MARK: - Public API

    /// Start the full auto-alignment pipeline.
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

        // ── Clear previous automatic runs ──
        // Anchors from earlier automatic passes (pipeline or continuous
        // background) would otherwise survive and block re-anchoring, so a
        // re-run could never correct a bad earlier result.
        let clearedCount = try anchorDAO.deleteAutoPipelineAnchors(for: audiobookID)
        if clearedCount > 0 {
            try alignmentService.recalculateTimeline()
            state.log("Cleared \(clearedCount) anchors from previous automatic runs")
        }

        // ── Tier 0: Metadata Title Matching ──
        // Compare audiobook chapter titles (from M4B metadata) to EPUB
        // heading blocks before doing any expensive transcription. These
        // bootstrap anchors give the timeline rough shape immediately;
        // content alignment refines or supersedes them below.
        state.phase = .matchingTitles
        state.update(
            phase: .matchingTitles, progress: 0.0,
            statusMessage: "Matching chapter titles to EPUB headings…")
        state.log("Tier 0: matching \(chapters.count) chapter titles against EPUB headings…")

        let genericTitleCount = chapters.count { chapter in
            ChapterTitleMatcher.isGenericNumericTitle(chapter.title ?? "")
        }
        if genericTitleCount > 0 {
            state.log(
                "Tier 0: \(genericTitleCount)/\(chapters.count) titles are generic track labels (\"Chapter N\") — no metadata signal there"
            )
        }

        let titleMatches = ChapterTitleMatcher.matchChapterTitles(
            chapters: chapters, blocks: blocks
        )

        var tier0AnchorIDByBlockID: [String: String] = [:]
        if !titleMatches.isEmpty {
            let titleAnchors = createTitleMatchAnchors(matches: titleMatches)
            try alignmentService.insertAnchors(titleAnchors)
            tier0AnchorIDByBlockID = Dictionary(
                uniqueKeysWithValues: titleAnchors.map { ($0.epubBlockID, $0.id) }
            )
            state.log(
                "Tier 0: inserted \(titleAnchors.count) bootstrap anchors — content alignment will refine them"
            )
            state.titleMatchedChapterCount = titleMatches.count
        } else {
            state.log("Tier 0: no title matches — content alignment only")
        }

        guard !Task.isCancelled else { return }

        // ── Load model ──
        state.phase = .loadingModel
        state.update(
            phase: .loadingModel, progress: 0.05,
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

        // ── Content alignment ──
        try await runDTWPipeline(
            chapters: chapters,
            blocks: blocks,
            tier0AnchorIDByBlockID: tier0AnchorIDByBlockID
        )

        guard !Task.isCancelled else { return }

        state.log(
            "═══ Pipeline complete: \(state.anchoredChapterCount) chapters anchored (\(state.titleMatchedChapterCount) title-matched) ═══"
        )
        state.complete()
        scheduleModelUnload()
    }

    // MARK: - Manual Alignment Fine-Tuning

    /// Auto-transcription for manual alignments.
    /// Uses a 10 s window (±5 s) around the specified time to locate the
    /// block's first-word position from real word timestamps.
    func fineTuneManualAlignment(blockID: String, around time: TimeInterval) async throws
        -> TimeInterval?
    {
        let allBlocks = try blockDAO.blocks(for: audiobookID)
        guard let targetBlock = allBlocks.first(where: { $0.id == blockID }) else { return nil }

        try await loadWhisperModel()

        let windowStart = max(0, time - 5.0)
        let duration = 10.0

        state.log(
            "fine-tune: capturing \(duration)s at \(String(format: "%.1f", windowStart))s for block \(blockID)"
        )

        let words = try await captureAndTranscribe(at: windowStart, duration: duration)
        defer { scheduleModelUnload() }
        guard !words.isEmpty else {
            state.log("fine-tune: capture/transcription failed or empty")
            return nil
        }

        let transcript = words.map(\.text).joined(separator: " ")
        guard
            let match = findBestMatch(
                transcribedText: transcript, candidates: [targetBlock], expectedIndex: 0),
            let projected = AlignmentTranscript.projectBlockStart(
                words: words, matchedBlockWindowStart: match.bestWindowStart
            )
        else {
            state.log("fine-tune ✗ no high-confidence match found in window")
            return nil
        }

        state.log(
            "fine-tune ✓ conf: \(String(format: "%.2f", match.confidence)), aligned from \(String(format: "%.1f", time))s to \(String(format: "%.1f", projected))s"
        )
        return projected
    }

    // MARK: - Tier 0: Title Match Anchors

    /// Converts `ChapterTitleMatcher.Match` results into `AlignmentAnchorRecord`
    /// values suitable for batch insertion.
    ///
    /// Each match produces a `chapterStart` anchor at the chapter's `startSeconds`,
    /// pointing to the matched EPUB heading block. These anchors serve as
    /// bootstrap points until content alignment supersedes them.
    private func createTitleMatchAnchors(
        matches: [ChapterTitleMatcher.Match]
    ) -> [AlignmentAnchorRecord] {
        let iso = AlignmentService.isoFormatter
        return matches.map { match in
            AlignmentAnchorRecord(
                id: "auto-tier0-\(UUID().uuidString)",
                audiobookID: audiobookID,
                epubBlockID: match.block.id,
                audioTime: match.chapter.startSeconds,
                audioEndTime: nil,
                anchorKind: AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue,
                source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
                note: "auto: tier0 title match (conf: \(String(format: "%.2f", match.confidence)))",
                createdAt: iso.string(from: Date()),
                modifiedAt: nil
            )
        }
    }

    // MARK: - Content Alignment

    private func runDTWPipeline(
        chapters: [Chapter],
        blocks: [EPubBlockRecord],
        tier0AnchorIDByBlockID: [String: String]
    ) async throws {
        // Blocks anchored by a human are off-limits. Tier 0 anchors are
        // machine bootstraps and may be superseded by a strong content match.
        let existingAnchors = try anchorDAO.anchors(for: audiobookID)
        let protectedBlockIDs = Set(
            existingAnchors
                .filter { anchor in
                    !anchor.id.hasPrefix("auto-tier0-")
                        && !anchor.id.hasPrefix("auto-dtw-")
                        && !anchor.id.hasPrefix("auto-continuous-")
                }
                .map(\.epubBlockID))
        let iso = AlignmentService.isoFormatter

        var workingBlocks = blocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
        if workingBlocks.contains(where: { $0.chapterIndex == nil }),
            let lastChapter = chapters.last
        {
            let duration = lastChapter.endSeconds
            let totalWordCount = workingBlocks.reduce(0) {
                $0 + ($1.wordCount ?? max(1, $1.text?.split(separator: " ").count ?? 1))
            }
            var currentWordCount = 0

            for i in 0..<workingBlocks.count {
                let blockWordCount =
                    workingBlocks[i].wordCount
                    ?? max(1, workingBlocks[i].text?.split(separator: " ").count ?? 1)

                if workingBlocks[i].chapterIndex == nil {
                    let estimatedFraction =
                        totalWordCount > 0 ? Double(currentWordCount) / Double(totalWordCount) : 0
                    let estimatedTime = estimatedFraction * duration
                    if let matched = chapters.first(where: { ch in
                        estimatedTime >= ch.startSeconds && estimatedTime < ch.endSeconds
                    }) {
                        workingBlocks[i].chapterIndex = matched.index
                    }
                }
                currentWordCount += blockWordCount
            }
        }

        let blocksByChapter = Dictionary(grouping: workingBlocks, by: { $0.chapterIndex })

        guard let audioURL = audioEngine.audioFileURL else { return }
        state.update(
            phase: .mappingSilences, progress: 0.0, statusMessage: "Scanning audio for silences...")

        let silenceDetector = SilenceDetectionService(audioURL: audioURL)
        let silences = try await silenceDetector.detectSilences()

        var anchoredBlockIDs = protectedBlockIDs
        var lastGlobalAnchorTime: TimeInterval = 0
        var chapterAnchoredCount = 0
        var totalInserted = 0

        for (idx, chapter) in chapters.enumerated() {
            try Task.checkCancellation()

            state.currentChapterIndex = idx
            let baseProgress = Double(idx) / Double(max(1, chapters.count))
            let progressSlice = 1.0 / Double(max(1, chapters.count))

            state.log("═══ Chapter \(idx + 1) content alignment ═══")

            guard let chapterBlocks = blocksByChapter[chapter.index], !chapterBlocks.isEmpty else {
                state.log("ch\(idx): skip — no visible blocks")
                continue
            }

            let chapterDuration = chapter.endSeconds - chapter.startSeconds
            guard chapterDuration > 5 else {
                state.log("ch\(idx): skip — too short")
                continue
            }

            // Text near an estimated chapter boundary may actually be
            // narrated in the neighbouring track — include a slack margin of
            // blocks so mis-binned boundary text can still anchor here. The
            // run-length gate keeps text that truly belongs elsewhere out.
            let previousBlocks = idx > 0 ? (blocksByChapter[chapters[idx - 1].index] ?? []) : []
            let nextBlocks =
                idx + 1 < chapters.count ? (blocksByChapter[chapters[idx + 1].index] ?? []) : []
            let alignmentBlocks =
                Array(previousBlocks.suffix(Config.boundarySlackBlockCount))
                + chapterBlocks
                + Array(nextBlocks.prefix(Config.boundarySlackBlockCount))

            // 1. Capture + transcribe in bounded chunks.
            let chunks = AlignmentChunkPlanner.plan(
                chapterStart: chapter.startSeconds,
                chapterEnd: chapter.endSeconds,
                silences: silences,
                minChunk: Config.minChunkSeconds,
                maxChunk: Config.maxChunkSeconds
            )
            state.log("ch\(idx): \(chunks.count) capture chunks")

            var words: [TranscribedWord] = []
            for (cIdx, chunk) in chunks.enumerated() {
                try Task.checkCancellation()

                let p = baseProgress + (Double(cIdx) / Double(max(1, chunks.count))) * progressSlice
                state.update(
                    phase: .transcribingAudio, progress: p,
                    statusMessage:
                        "Transcribing chapter \(idx + 1) (chunk \(cIdx + 1)/\(chunks.count))…")

                words += try await captureAndTranscribe(at: chunk.start, duration: chunk.duration)
            }

            guard !words.isEmpty else {
                state.log("ch\(idx): skip — no transcribed text")
                continue
            }

            // 2. Token streams — every audio token carries its word's real
            //    timestamp, so pauses and rate changes cost nothing.
            let audioTokens = words.flatMap { word in
                TokenDTW.normalize(word.text).map {
                    TokenDTW.AudioToken(text: $0, time: word.start)
                }
            }
            var epubTokens: [TokenDTW.EPubToken] = []
            for block in alignmentBlocks {
                guard let text = block.text, !block.isHidden else { continue }
                epubTokens += TokenDTW.normalize(text).map {
                    TokenDTW.EPubToken(text: $0, blockID: block.id)
                }
            }
            guard !audioTokens.isEmpty, !epubTokens.isEmpty else {
                state.log("ch\(idx): skip — no tokens")
                continue
            }

            // 3. Align, then gate to strong, monotonic, in-window anchors.
            state.update(
                phase: .computingAlignment,
                progress: baseProgress + 0.99 * progressSlice,
                statusMessage: "Aligning chapter \(idx + 1)…")

            let candidates = TokenDTW.alignWithBisection(epub: epubTokens, audio: audioTokens)
            let windowStart = chapter.startSeconds - Config.chapterWindowSlack
            let windowEnd = chapter.endSeconds + Config.chapterWindowSlack
            let eligible = candidates.filter { candidate in
                !anchoredBlockIDs.contains(candidate.blockID)
                    && candidate.time >= windowStart
                    && candidate.time <= windowEnd
                    && candidate.time + 0.25 >= lastGlobalAnchorTime
            }
            let selected = AnchorSelector.select(
                candidates: eligible, minRunLength: Config.minAnchorRunLength
            )
            state.log(
                "ch\(idx): \(words.count) words → \(candidates.count) candidates → \(selected.count) anchors (gate: run ≥ \(Config.minAnchorRunLength))"
            )

            guard !selected.isEmpty else { continue }

            // 4. Persist per chapter so alignment improves progressively. A
            //    strong content match supersedes the block's Tier 0 anchor.
            var chapterAnchors: [AlignmentAnchorRecord] = []
            for candidate in selected {
                if let tier0ID = tier0AnchorIDByBlockID[candidate.blockID] {
                    try anchorDAO.delete(id: tier0ID)
                }
                let isFirst = candidate.blockID == chapterBlocks.first?.id
                let isLast = candidate.blockID == chapterBlocks.last?.id
                let kind =
                    isFirst
                    ? AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue
                    : (isLast
                        ? AlignmentAnchorRecord.AnchorKind.chapterEnd.rawValue
                        : AlignmentAnchorRecord.AnchorKind.point.rawValue)

                chapterAnchors.append(
                    AlignmentAnchorRecord(
                        id: "auto-dtw-\(UUID().uuidString)",
                        audiobookID: audiobookID,
                        epubBlockID: candidate.blockID,
                        audioTime: candidate.time,
                        audioEndTime: nil,
                        anchorKind: kind,
                        source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
                        note: "auto: dtw (run \(candidate.exactRunLength))",
                        createdAt: iso.string(from: Date()),
                        modifiedAt: nil
                    ))
                anchoredBlockIDs.insert(candidate.blockID)
            }
            try alignmentService.insertAnchors(chapterAnchors)
            totalInserted += chapterAnchors.count
            chapterAnchoredCount += 1
            lastGlobalAnchorTime = max(
                lastGlobalAnchorTime, selected.map(\.time).max() ?? lastGlobalAnchorTime)
        }

        state.log("Inserted \(totalInserted) anchors total")
        state.anchoredChapterCount = chapterAnchoredCount
    }

    // MARK: - Audio Capture + Transcription

    /// Reads `duration` seconds of audio starting at `time` from the audio
    /// file and transcribes with WhisperKit, returning time-stamped words on
    /// the audio file's clock.
    ///
    /// Uses direct file reading rather than a real-time tap, so it does not
    /// interrupt playback or pick up time-pitch distortion at non-1× speeds.
    func captureAndTranscribe(
        at time: TimeInterval,
        duration: TimeInterval
    ) async throws -> [TranscribedWord] {
        guard let fileURL = audioEngine.audioFileURL else {
            state.log("capture: no audio file loaded")
            return []
        }

        let maxTime = audioEngine.duration ?? 0
        guard maxTime > 0, time < maxTime else {
            state.log(
                "capture: bad time \(String(format: "%.1f", time)) max=\(String(format: "%.1f", maxTime))"
            )
            return []
        }

        let clampedTime = max(0, min(time, maxTime - duration))

        let samples = try await AudioSegmentReader.samples(
            from: fileURL, at: clampedTime, duration: duration
        )
        guard samples.count >= Int(Config.sampleRate * 1.0) else {
            state.log(
                "capture: only \(samples.count) samples at \(String(format: "%.1f", clampedTime))s (need \(Int(Config.sampleRate)))"
            )
            return []
        }

        let words = try await transcribe(samples, captureStart: clampedTime)
        if words.isEmpty {
            state.log("transcribed: (empty/silence)")
        } else {
            let preview = words.prefix(12).map(\.text).joined(separator: " ")
            state.log(
                "transcribed: \"\(preview)…\" first word @ \(String(format: "%.2f", words[0].start))s, \(words.count) words"
            )
        }
        return words
    }

    // MARK: - WhisperKit

    func loadWhisperModel() async throws {
        modelUnloadTimer?.invalidate()
        modelUnloadTimer = nil

        if whisperKit != nil { return }

        self.whisperKit = try await WhisperSession.shared.acquire(model: Config.modelSize)
    }

    /// Transcribes raw samples into time-stamped words. `captureStart` is
    /// the absolute audio-file time of the first sample.
    func transcribe(_ audioArray: [Float], captureStart: TimeInterval) async throws
        -> [TranscribedWord]
    {
        guard !audioArray.isEmpty else { return [] }

        guard let wk = whisperKit else {
            throw AutoAlignmentError.modelNotLoaded
        }

        let words = await AlignmentTranscript.transcribeWords(
            with: wk, samples: audioArray, captureStart: captureStart
        )
        scheduleModelUnload()
        return words
    }

    func scheduleModelUnload() {
        modelUnloadTimer?.invalidate()
        modelUnloadTimer = Timer.scheduledTimer(
            withTimeInterval: Config.modelKeepAliveSeconds,
            repeats: false
        ) { [weak self] _ in
            // Fires on the main run loop (scheduled from a @MainActor context),
            // so release synchronously rather than via a queued Task that could
            // double-release against deinit (CODE_AUDIT.md §3.6).
            MainActor.assumeIsolated {
                WhisperSession.shared.release()
                // Mirror the shared box: once released, the cached handle may
                // point at an unloaded model, so drop it so the next
                // loadWhisperModel() re-acquires instead of early-returning on a
                // stale `whisperKit != nil` (§5.2).
                self?.whisperKit = nil
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
