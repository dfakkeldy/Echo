import Foundation
import AVFoundation
import GRDB
import os.log
@preconcurrency import WhisperKit

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
    private var ringBuffer: AudioRingBuffer?
    private var timer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    
    // WhisperKit
    private var whisperKit: WhisperKit?
    
    // Configuration
    private nonisolated enum Config {
        static let interval: TimeInterval = 15.0
        static let ringBufferCapacityMultiplier: TimeInterval = 2.0
        static let sampleRate: Double = 16_000
        static let modelSize = "base.en"
        static let matchThreshold = 0.35
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
        
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Config.sampleRate, channels: 1, interleaved: false) else {
            logger.error("Failed to create AVAudioFormat (16 kHz mono Float32) — unsupported PCM configuration on this device. Continuous alignment disabled.")
            isRunning = false
            return
        }
        let buffer = AudioRingBuffer(capacitySeconds: Config.interval * Config.ringBufferCapacityMultiplier, sampleRate: Config.sampleRate)
        self.ringBuffer = buffer
        
        audioEngine.installCaptureTap(format: format, bufferSize: 4096) { pcmBuffer, _ in
            guard let channelData = pcmBuffer.floatChannelData else { return }
            let count = Int(pcmBuffer.frameLength)
            buffer.write(channelData[0], count: count)
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: Config.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.processBufferedAudio()
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
        audioEngine.removeCaptureTap()
        ringBuffer = nil
        
        WhisperSession.shared.release()
        whisperKit = nil
        logger.info("Continuous alignment stopped")
    }
    
    private func processBufferedAudio() {
        guard !isProcessing else {
            logger.info("Skipping buffer processing — previous transcription still in progress")
            return
        }
        guard let ringBuffer else { return }
        let samples = ringBuffer.readAll()
        guard samples.count >= Int(Config.sampleRate * 2.0) else { return } // At least 2 seconds

        let audioTimeOfBufferEnd = audioEngine.currentTime
        let audioTimeOfBufferStart = max(0, audioTimeOfBufferEnd - Double(samples.count) / Config.sampleRate)
        let bufferDuration = Double(samples.count) / Config.sampleRate

        isProcessing = true
        transcriptionTask = Task {
            defer { isProcessing = false }
            do {
                try await loadModelIfNeeded()
                let capture = try await transcribe(samples)
                if !capture.text.isEmpty {
                    await matchAndInsertAnchor(text: capture.text, wordOffset: capture.offset, bufferStartTime: audioTimeOfBufferStart, bufferDuration: bufferDuration)
                }
            } catch {
                logger.error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func loadModelIfNeeded() async throws {
        if whisperKit != nil { return }
        self.whisperKit = try await WhisperSession.shared.acquire(model: Config.modelSize)
    }
    
    private func transcribe(_ audioArray: [Float]) async throws -> (text: String, offset: TimeInterval) {
        guard !audioArray.isEmpty else { return ("", 0) }

        guard let wk = whisperKit else { throw NSError(domain: "ContinuousAlignment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]) }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            wordTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: .vad
        )

        let results = await wk.transcribe(audioArrays: [audioArray], decodeOptions: options)

        let allSegments = results.compactMap { $0?.first?.segments }.flatMap { $0 }
        let wordOffset = TimeInterval(allSegments.first?.words?.first?.start ?? 0)

        let text = results
            .compactMap { $0?.first?.segments.map(\.text).joined(separator: " ") }
            .joined(separator: " ")
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return (text, wordOffset)
    }
    
    private func matchAndInsertAnchor(text: String, wordOffset: TimeInterval, bufferStartTime: TimeInterval, bufferDuration: TimeInterval) async {
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
            if time <= bufferStartTime, time >= bestTime {
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
        
        if let match = AutoAlignmentTextMatcher.findBestMatch(transcribedText: text, candidates: candidates, matchThreshold: Config.matchThreshold) {
            
            let projected = AutoAlignmentTextMatcher.projectedBlockStart(
                windowStart: bufferStartTime,
                firstWordOffset: wordOffset,
                captureDuration: bufferDuration,
                transcriptTokenCount: match.transcriptTokenCount,
                matchedBlockWindowStart: match.bestWindowStart
            )
            
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
}
