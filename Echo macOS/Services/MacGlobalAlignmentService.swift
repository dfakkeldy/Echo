import Foundation
import SwiftUI
import os.log
@preconcurrency import WhisperKit
import GRDB

public struct AlignmentAnchorExport: Codable {
    public let blockId: String
    public let timestamp: TimeInterval
    public let confidence: Double
}

public struct TransTokenRecord: Codable, FetchableRecord, PersistableRecord {
    public let sequenceIndex: Int
    public let word: String
    public let timestamp: TimeInterval
    public let duration: TimeInterval
}

@MainActor
@Observable
public class MacGlobalAlignmentService {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "MacGlobalAlignmentService")
    
    public var isAligning: Bool = false
    public var alignmentProgress: Double = 0
    public var alignmentStatus: String = ""
    public var matchThreshold: Double = 0.4
    
    private var whisperKit: WhisperKit?
    
    public init() {}
    
    /// Aligns the EPUB at the given URL by streaming audio through WhisperKit
    /// writing the results to `[AudiobookName].alignment.json`.
    public func alignStreaming(audioURL: URL, epubURL: URL) async throws {
        isAligning = true
        alignmentProgress = 0
        alignmentStatus = "Extracting EPUB text..."
        
        defer {
            isAligning = false
            alignmentProgress = 1.0
            WhisperSession.shared.release()
            self.whisperKit = nil
        }
        
        // 1. Extract EPUB Blocks
        let parser = MacEPUBParser()
        let epubBlocks = try await parser.extractText(from: epubURL)
        guard !epubBlocks.isEmpty else {
            throw NSError(domain: "MacGlobalAlignmentService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No text blocks found in EPUB."])
        }
        
        // 2. Setup SQLite Cache
        alignmentStatus = "Preparing temporary database..."
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("dtw_tokens_\(UUID().uuidString).sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try db.create(table: "transTokenRecord") { t in
                t.column("sequenceIndex", .integer).primaryKey()
                t.column("word", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("duration", .double).notNull()
            }
        }
        defer { try? FileManager.default.removeItem(at: dbURL) }
        
        // 3. Load WhisperKit
        alignmentStatus = "Loading WhisperKit..."
        try await loadModelIfNeeded()
        
        // 4. Stream and Transcribe Audio
        alignmentStatus = "Transcribing audio chunks..."
        let extractor = AudioExtractor(url: audioURL)
        let totalDuration = try await extractor.prepare()
        
        let chunkDuration: TimeInterval = 30.0
        var tokenSequenceIndex = 0
        
        while let (pcmBuffer, chunkStartTime) = try await extractor.readNextChunk(durationInSeconds: chunkDuration) {
            alignmentStatus = "Transcribing \(formatTime(chunkStartTime)) / \(formatTime(totalDuration))..."
            alignmentProgress = (chunkStartTime / totalDuration) * 0.5 // Transcription is 50% of total progress
            
            let capture = try await transcribeChunk(pcmBuffer)
            
            // Generate tokens and insert to DB
            if !capture.text.isEmpty {
                let words = tokenize(capture.text)
                if !words.isEmpty {
                    // Approximate duration per word using the chunk length / words
                    // Note: If WordTimestamps are available via WhisperKit segments, it's better, but we do simple division here as a fallback if not parsed accurately.
                    let durationPerWord = capture.duration / Double(words.count)
                    
                    var records = [TransTokenRecord]()
                    for (i, word) in words.enumerated() {
                        let offset = capture.wordOffset + (Double(i) * durationPerWord)
                        let record = TransTokenRecord(
                            sequenceIndex: tokenSequenceIndex,
                            word: word,
                            timestamp: chunkStartTime + offset, // Note: wordOffset is relative to chunk
                            duration: durationPerWord
                        )
                        records.append(record)
                        tokenSequenceIndex += 1
                    }
                    
                    try await dbQueue.write { db in
                        for record in records {
                            try record.insert(db)
                        }
                    }
                }
            }
            
            // Yield to main thread
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        
        let totalTokens = try await dbQueue.read { db in
            try TransTokenRecord.fetchCount(db)
        }
        
        guard totalTokens > 0 else {
            throw NSError(domain: "MacGlobalAlignmentService", code: 2, userInfo: [NSLocalizedDescriptionKey: "No transcription tokens extracted."])
        }
        
        // 5. DTW Alignment
        alignmentStatus = "Aligning \(epubBlocks.count) blocks with \(totalTokens) audio tokens..."
        
        var exports: [AlignmentAnchorExport] = []
        var searchStartIndex = 0
        let windowSize = 500
        
        for (idx, block) in epubBlocks.enumerated() {
            if idx % 10 == 0 {
                alignmentProgress = 0.5 + (Double(idx) / Double(epubBlocks.count) * 0.5)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            
            let blockTokens = tokenize(block.text)
            guard !blockTokens.isEmpty else { continue }
            
            // Search in a window ahead of our last match
            let endIndex = min(searchStartIndex + windowSize, totalTokens)
            guard searchStartIndex < endIndex else { break }
            
            let searchWindowRecords = try await dbQueue.read { db in
                try TransTokenRecord
                    .filter(Column("sequenceIndex") >= searchStartIndex && Column("sequenceIndex") < endIndex)
                    .order(Column("sequenceIndex"))
                    .fetchAll(db)
            }
            
            if let bestMatch = findBestMatch(blockTokens: blockTokens, in: searchWindowRecords) {
                let confidence = bestMatch.confidence
                if confidence > matchThreshold {
                    let globalIndex = searchStartIndex + bestMatch.windowStart
                    if let matchedRecord = searchWindowRecords.first(where: { $0.sequenceIndex == globalIndex }) {
                        exports.append(AlignmentAnchorExport(
                            blockId: block.id,
                            timestamp: matchedRecord.timestamp,
                            confidence: confidence
                        ))
                        searchStartIndex = globalIndex + blockTokens.count
                    }
                }
            }
        }
        
        // 6. Save Alignment
        alignmentStatus = "Saving alignment..."
        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("alignment.json")
        let didStart = audioURL.startAccessingSecurityScopedResource()
        defer { if didStart { audioURL.stopAccessingSecurityScopedResource() } }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(exports)
        try data.write(to: sidecarURL, options: .atomic)
        
        alignmentStatus = "Alignment complete (\(exports.count) anchors saved)."
        logger.debug("Saved alignment with \(exports.count) anchors to \(sidecarURL.path)")
    }
    
    // MARK: - WhisperKit
    
    private func loadModelIfNeeded() async throws {
        if whisperKit != nil { return }
        self.whisperKit = try await WhisperSession.shared.acquire(model: "base.en")
    }
    
    private func transcribeChunk(_ audioArray: [Float]) async throws -> (text: String, wordOffset: TimeInterval, duration: TimeInterval) {
        guard !audioArray.isEmpty else { return ("", 0, 0) }
        guard let wk = whisperKit else { throw NSError(domain: "MacGlobalAlignmentService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]) }

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
        let duration = TimeInterval((allSegments.last?.words?.last?.end ?? Float(audioArray.count) / 16000.0))

        let text = results
            .compactMap { $0?.first?.segments.map(\.text).joined(separator: " ") }
            .joined(separator: " ")
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return (text, wordOffset, duration)
    }
    
    // MARK: - Utils
    
    private func formatTime(_ time: TimeInterval) -> String {
        let h = Int(time) / 3600
        let m = (Int(time) % 3600) / 60
        let s = Int(time) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
    
    private func tokenize(_ text: String) -> [String] {
        return text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 2 }
    }
    
    private func findBestMatch(blockTokens: [String], in transcriptWindow: [TransTokenRecord]) -> (windowStart: Int, confidence: Double)? {
        guard !blockTokens.isEmpty, !transcriptWindow.isEmpty else { return nil }

        var bestScore: Double = 0
        var bestStart: Int = 0

        // Precompute word array once so we don't allocate a new [String] per window.
        let transcriptWords = transcriptWindow.map { $0.word }
        // Precompute the block token set once — blockTokens is constant across the loop.
        let blockSet = Set(blockTokens)

        let windowSize = blockTokens.count
        let stride = max(1, windowSize / 3)

        var start = 0
        while start < transcriptWords.count {
            let end = min(transcriptWords.count, start + windowSize)
            let s = score(blockSet: blockSet, candidateSlice: transcriptWords[start..<end])
            if s > bestScore {
                bestScore = s
                bestStart = start
            }
            if end == transcriptWords.count { break }
            start += stride
        }

        if bestScore > 0 {
            return (bestStart, bestScore)
        }
        return nil
    }

    /// Jaccard word-overlap score using a precomputed block token set and a
    /// transcript slice.  The slice is converted to a Set on demand so we
    /// don't allocate intermediate arrays.
    private func score(blockSet: Set<String>, candidateSlice: ArraySlice<String>) -> Double {
        let transSet = Set(candidateSlice)
        let intersection = blockSet.intersection(transSet).count
        let union = blockSet.union(transSet).count

        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }
}
