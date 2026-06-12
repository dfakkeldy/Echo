import Accelerate
import AVFoundation
import Foundation
import GRDB
import os.log

@preconcurrency import WhisperKit

// MARK: - AutoAlignmentService

/// Orchestrates the progressive auto-alignment pipeline that transcribes
/// audio with WhisperKit and matches it against EPUB text to create
/// alignment anchors automatically.
///
/// **Tier 0 — Metadata Title Matching:** Fuzzy-matches audiobook chapter
/// titles (from M4B metadata) against EPUB heading blocks before any
/// transcription. Generic track labels ("Chapter 7", "12") are skipped —
/// they number tracks, not book chapters, so only descriptive titles can
/// bootstrap anchors. High-confidence matches skip DTW for that chapter.
///
/// **VAD + DTW Content Alignment:** For remaining chapters, chunks the audio
/// at detected silences, transcribes each chunk, and aligns transcript
/// tokens against the chapter's EPUB blocks with dynamic time warping,
/// inserting `chapterStart`/`point`/`chapterEnd` anchors.
///
/// Each run first deletes anchors created by previous runs (`auto-tier0-`/
/// `auto-dtw-` prefixes) so re-alignment can correct earlier results.
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

        // ── Clear previous pipeline runs ──
        // Anchors from an earlier auto-alignment run would otherwise survive
        // (Tier 0 would stack duplicates; DTW skips already-anchored blocks),
        // so a re-run could never correct a bad earlier result.
        let clearedCount = try anchorDAO.deleteAutoPipelineAnchors(for: audiobookID)
        if clearedCount > 0 {
            try alignmentService.recalculateTimeline()
            state.log("Cleared \(clearedCount) anchors from a previous auto-alignment run")
        }

        // ── Tier 0: Metadata Title Matching ──
        // Compare audiobook chapter titles (from M4B metadata) to EPUB
        // heading blocks before doing any expensive transcription. A
        // strong match lets us skip DTW for that chapter entirely.
        state.phase = .matchingTitles
        state.update(phase: .matchingTitles, progress: 0.0,
                     statusMessage: "Matching chapter titles to EPUB headings…")
        state.log("Tier 0: matching \(chapters.count) chapter titles against EPUB headings…")

        let genericTitleCount = chapters.count { chapter in
            ChapterTitleMatcher.isGenericNumericTitle(chapter.title ?? "")
        }
        if genericTitleCount > 0 {
            state.log("Tier 0: \(genericTitleCount)/\(chapters.count) titles are generic track labels (\"Chapter N\") — those chapters use content alignment instead")
        }

        let titleMatches = ChapterTitleMatcher.matchChapterTitles(
            chapters: chapters, blocks: blocks
        )
        let highConfidenceIndices = Set(titleMatches
            .filter { $0.confidence >= ChapterTitleMatcher.Threshold.highConfidence }
            .map { $0.chapter.index })
        let mediumConfidenceIndices = Set(titleMatches
            .filter { $0.confidence < ChapterTitleMatcher.Threshold.highConfidence }
            .map { $0.chapter.index })

        if !titleMatches.isEmpty {
            state.log("Tier 0: \(titleMatches.count) title matches — \(highConfidenceIndices.count) high-confidence, \(mediumConfidenceIndices.count) medium-confidence")
            let titleAnchors = createTitleMatchAnchors(matches: titleMatches)
            try alignmentService.insertAnchors(titleAnchors)
            state.log("Tier 0: inserted \(titleAnchors.count) title-match anchors")
            state.titleMatchedChapterCount = titleMatches.count
        } else {
            state.log("Tier 0: no title matches — falling through to DTW pipeline")
        }

        guard !Task.isCancelled else { return }

        // ── Load model ──
        state.phase = .loadingModel
        state.update(phase: .loadingModel, progress: 0.05,
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

        // ── VAD Chunking + DTW Alignment ──
        try await runDTWPipeline(
            chapters: chapters,
            blocks: blocks,
            skipChapterIndices: highConfidenceIndices
        )

        guard !Task.isCancelled else { return }

        state.log("═══ Pipeline complete: \(state.anchoredChapterCount) chapters anchored (\(state.titleMatchedChapterCount) via title match) ═══")
        state.complete()
        scheduleModelUnload()
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



    // MARK: - Tier 0: Title Match Anchors

    /// Converts `ChapterTitleMatcher.Match` results into `AlignmentAnchorRecord`
    /// values suitable for batch insertion.
    ///
    /// Each match produces a `chapterStart` anchor at the chapter's `startSeconds`,
    /// pointing to the matched EPUB heading block. These anchors serve as
    /// high-quality bootstrap points for timeline interpolation.
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

    private func runDTWPipeline(
        chapters: [Chapter],
        blocks: [EPubBlockRecord],
        skipChapterIndices: Set<Int> = []
    ) async throws {
        let existingAnchors = try anchorDAO.anchors(for: audiobookID)
        let existingIDs = Set(existingAnchors.map { $0.epubBlockID })
        let iso = AlignmentService.isoFormatter
        
        var workingBlocks = blocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
        if workingBlocks.contains(where: { $0.chapterIndex == nil }), let lastChapter = chapters.last {
            let duration = lastChapter.endSeconds
            let totalWordCount = workingBlocks.reduce(0) { $0 + ($1.wordCount ?? max(1, $1.text?.split(separator: " ").count ?? 1)) }
            var currentWordCount = 0
            
            for i in 0..<workingBlocks.count {
                let blockWordCount = workingBlocks[i].wordCount ?? max(1, workingBlocks[i].text?.split(separator: " ").count ?? 1)
                
                if workingBlocks[i].chapterIndex == nil {
                    let estimatedFraction = totalWordCount > 0 ? Double(currentWordCount) / Double(totalWordCount) : 0
                    let estimatedTime = estimatedFraction * duration
                    if let matched = chapters.first(where: { ch in estimatedTime >= ch.startSeconds && estimatedTime < ch.endSeconds }) {
                        workingBlocks[i].chapterIndex = matched.index
                    }
                }
                currentWordCount += blockWordCount
            }
        }
        
        let blocksByChapter = Dictionary(grouping: workingBlocks, by: { $0.chapterIndex })
        
        guard let audioURL = audioEngine.audioFileURL else { return }
        state.update(phase: .mappingSilences, progress: 0.0, statusMessage: "Scanning audio for silences...")
        
        let silenceDetector = SilenceDetectionService(audioURL: audioURL)
        let silences = try await silenceDetector.detectSilences()
        
        var createdAnchors: [AlignmentAnchorRecord] = []
        var chapterAnchoredCount = 0

        for (idx, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            
            state.currentChapterIndex = idx
            let baseProgress = Double(idx) / Double(max(1, chapters.count))

            // Skip chapters that already have a high-confidence Tier 0 title match.
            if skipChapterIndices.contains(chapter.index) {
                state.log("═══ Chapter \(idx + 1) — skipped (Tier 0 title match) ═══")
                chapterAnchoredCount += 1
                continue
            }

            state.log("═══ Chapter \(idx + 1) DTW Alignment ═══")
            
            guard let chapterBlocks = blocksByChapter[chapter.index], !chapterBlocks.isEmpty else {
                state.log("ch\(idx): skip — no visible blocks")
                continue
            }
            
            let chapterDuration = chapter.endSeconds - chapter.startSeconds
            guard chapterDuration > 5 else {
                state.log("ch\(idx): skip — too short")
                continue
            }
            
            // 1. Generate audio chunks bounded by silence
            var chunks: [(start: TimeInterval, end: TimeInterval)] = []
            var currentChunkStart = chapter.startSeconds
            
            let chapterSilences = silences.filter { $0.end > chapter.startSeconds && $0.start < chapter.endSeconds }
            
            for s in chapterSilences {
                let silenceMid = (s.start + s.end) / 2.0
                if silenceMid - currentChunkStart >= 15.0 {
                    chunks.append((start: currentChunkStart, end: silenceMid))
                    currentChunkStart = silenceMid
                }
            }
            if chapter.endSeconds - currentChunkStart > 5.0 {
                chunks.append((start: currentChunkStart, end: chapter.endSeconds))
            }
            if chunks.isEmpty {
                chunks.append((start: chapter.startSeconds, end: chapter.endSeconds))
            }
            
            state.log("ch\(idx): generated \(chunks.count) VAD chunks")
            
            // 2. Transcribe chunks
            var audioTokens: [TokenDTW.AudioToken] = []
            for (cIdx, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                
                let p = baseProgress + (Double(cIdx) / Double(max(1, chunks.count))) * (1.0 / Double(max(1, chapters.count)))
                state.update(phase: .transcribingAudio, progress: p,
                             statusMessage: "Transcribing chapter \(idx + 1) (chunk \(cIdx + 1)/\(chunks.count))…")
                
                let duration = chunk.end - chunk.start
                guard let capture = try await captureAndTranscribe(at: chunk.start, duration: duration), !capture.text.isEmpty else { continue }
                
                let tokens = TokenDTW.normalize(capture.text)
                guard !tokens.isEmpty else { continue }
                
                let firstWordTime = chunk.start + capture.offset
                let elapsed = duration - capture.offset
                for (tIdx, tStr) in tokens.enumerated() {
                    let tokenTime = firstWordTime + (Double(tIdx) / Double(tokens.count)) * elapsed
                    audioTokens.append(TokenDTW.AudioToken(text: tStr, time: tokenTime))
                }
            }
            
            guard !audioTokens.isEmpty else {
                state.log("ch\(idx): skip — no transcribed text")
                continue
            }
            
            // 3. Prepare EPUB blocks
            state.update(phase: .computingAlignment, progress: baseProgress + 0.99 * (1.0 / Double(max(1, chapters.count))),
                         statusMessage: "Aligning chapter \(idx + 1)…")
            
            var epubTokens: [TokenDTW.EPubToken] = []
            for block in chapterBlocks {
                guard let text = block.text, !block.isHidden else { continue }
                let tokens = TokenDTW.normalize(text)
                for tStr in tokens {
                    epubTokens.append(TokenDTW.EPubToken(text: tStr, blockID: block.id))
                }
            }
            
            // 4. Align with DTW
            let alignment = TokenDTW.align(epub: epubTokens, audio: audioTokens)
            state.log("ch\(idx): DTW aligned \(alignment.count) blocks")
            
            var chapterCreated = 0
            for (blockID, time) in alignment {
                if existingIDs.contains(blockID) { continue }
                
                guard time >= chapter.startSeconds - 5.0 && time <= chapter.endSeconds + 5.0 else { continue }
                
                let clampedTime = max(chapter.startSeconds, min(chapter.endSeconds, time))
                
                let isFirst = blockID == chapterBlocks.first?.id
                let isLast = blockID == chapterBlocks.last?.id
                let kind = isFirst ? AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue :
                           (isLast ? AlignmentAnchorRecord.AnchorKind.chapterEnd.rawValue : AlignmentAnchorRecord.AnchorKind.point.rawValue)
                
                let anchor = AlignmentAnchorRecord(
                    id: "auto-dtw-\(UUID().uuidString)",
                    audiobookID: audiobookID,
                    epubBlockID: blockID,
                    audioTime: clampedTime,
                    audioEndTime: nil,
                    anchorKind: kind,
                    source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
                    note: "auto: dtw mapped",
                    createdAt: iso.string(from: Date()),
                    modifiedAt: nil
                )
                createdAnchors.append(anchor)
                chapterCreated += 1
            }
            
            if chapterCreated > 0 {
                chapterAnchoredCount += 1
            }
        }
        
        if !createdAnchors.isEmpty {
            try alignmentService.insertAnchors(createdAnchors)
            state.log("Inserted \(createdAnchors.count) anchors total")
        }
        state.anchoredChapterCount = chapterAnchoredCount
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
