import Foundation
import GRDB
@preconcurrency import WhisperKit
import os.log

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
    private let logger = Logger(category: "MacGlobalAlignmentService")

    public var isAligning: Bool = false
    public var alignmentProgress: Double = 0
    public var alignmentStatus: String = ""
    public var matchThreshold: Double = 0.4

    private var whisperKit: WhisperKit?

    public init() {}

    /// Aligns the EPUB at the given URL by streaming audio through WhisperKit
    /// writing the results to `[AudiobookName].alignment.json`.
    ///
    /// - Parameter audiobookID: Identifier embedded in every block ID via the
    ///   shared `parseEPUBBlocks` formula (`epub-<audiobookID>-s<i>-b<j>`). Must
    ///   match the value the consuming device assigns on import for the anchors
    ///   to resolve (CODE_AUDIT.md §5.1 / Phase A1).
    public func alignStreaming(audiobookID: String, audioURL: URL, epubURL: URL) async throws {
        isAligning = true
        alignmentProgress = 0
        alignmentStatus = "Extracting EPUB text..."

        defer {
            isAligning = false
            alignmentProgress = 1.0
            WhisperSession.shared.release()
            self.whisperKit = nil
        }

        // 1. Extract EPUB blocks via the shared driver — the same driver the
        // iOS importer uses, so these block IDs match the iOS database exactly
        // (CODE_AUDIT.md §5.1 / Phase A1). Anchors below are keyed by these IDs.
        let (epubDir, cleanupDir) = try await expandEPUBIfNeeded(epubURL)
        defer { if let cleanupDir { try? FileManager.default.removeItem(at: cleanupDir) } }

        let epubBlocks: [(id: String, text: String)] =
            try parseEPUBBlocks(audiobookID: audiobookID, epubURL: epubDir).blocks
            .compactMap { block in
                guard let text = block.text, !text.isEmpty else { return nil }
                return (id: block.id, text: text)
            }
        guard !epubBlocks.isEmpty else {
            throw NSError(
                domain: "MacGlobalAlignmentService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No text blocks found in EPUB."])
        }

        // 2. Setup SQLite Cache
        alignmentStatus = "Preparing temporary database..."
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("dtw_tokens_\(UUID().uuidString).sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try await dbQueue.write { db in
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

        while let (pcmBuffer, chunkStartTime) = try await extractor.readNextChunk(
            durationInSeconds: chunkDuration)
        {
            alignmentStatus =
                "Transcribing \(formatTimeHMS(chunkStartTime)) / \(formatTimeHMS(totalDuration))..."
            alignmentProgress = (chunkStartTime / totalDuration) * 0.5  // Transcription is 50% of total progress

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
                            timestamp: chunkStartTime + offset,  // Note: wordOffset is relative to chunk
                            duration: durationPerWord
                        )
                        records.append(record)
                        tokenSequenceIndex += 1
                    }

                    let finalRecords = records
                    try await dbQueue.write { db in
                        for record in finalRecords {
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
            throw NSError(
                domain: "MacGlobalAlignmentService", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No transcription tokens extracted."])
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
            let currentStartIndex = searchStartIndex
            let currentEndIndex = min(currentStartIndex + windowSize, totalTokens)
            guard currentStartIndex < currentEndIndex else { break }

            let searchWindowRecords = try await dbQueue.read { db in
                try TransTokenRecord
                    .filter(
                        Column("sequenceIndex") >= currentStartIndex
                            && Column("sequenceIndex") < currentEndIndex
                    )
                    .order(Column("sequenceIndex"))
                    .fetchAll(db)
            }

            if let bestMatch = findBestMatch(blockTokens: blockTokens, in: searchWindowRecords) {
                let confidence = bestMatch.confidence
                if confidence > matchThreshold {
                    let globalIndex = searchStartIndex + bestMatch.windowStart
                    if let matchedRecord = searchWindowRecords.first(where: {
                        $0.sequenceIndex == globalIndex
                    }) {
                        exports.append(
                            AlignmentAnchorExport(
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

    // MARK: - EPUB extraction

    /// Expands an `.epub` archive to a temporary directory so it can be fed to
    /// the shared `parseEPUBBlocks` driver (which, like the iOS import path,
    /// expects an expanded directory). Returns the directory to parse and, when
    /// extraction happened, the temp directory the caller must clean up.
    ///
    /// Non-`.epub` inputs (e.g. a PDF, or an already-expanded directory) are
    /// returned unchanged; a PDF then fails the container.xml check in
    /// `parseEPUBBlocks` exactly as before — PDF text extraction is not
    /// implemented here.
    private func expandEPUBIfNeeded(_ url: URL) async throws -> (dir: URL, cleanup: URL?) {
        guard url.pathExtension.lowercased() == "epub" else { return (url, nil) }

        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "MacGlobalAlignmentService", code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Failed to unzip EPUB (code \(proc.terminationStatus))"
                            ]))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        // Validate that no extracted file escapes the temp directory (path-traversal prevention).
        let tempDirStandardized = tempDir.standardized
        if let enumerator = FileManager.default.enumerator(
            at: tempDir, includingPropertiesForKeys: nil)
        {
            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.standardized.path.hasPrefix(tempDirStandardized.path) else {
                    throw NSError(
                        domain: "MacGlobalAlignmentService", code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Path traversal detected: extracted file \(fileURL.path) escapes temp directory"
                        ])
                }
            }
        }

        return (tempDir, tempDir)
    }

    // MARK: - WhisperKit

    private func loadModelIfNeeded() async throws {
        if whisperKit != nil { return }
        self.whisperKit = try await WhisperSession.shared.acquire(model: "base.en")
    }

    private func transcribeChunk(_ audioArray: [Float]) async throws -> (
        text: String, wordOffset: TimeInterval, duration: TimeInterval
    ) {
        guard !audioArray.isEmpty else { return ("", 0, 0) }
        guard let wk = whisperKit else {
            throw NSError(
                domain: "MacGlobalAlignmentService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }

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
        let duration = TimeInterval(
            (allSegments.last?.words?.last?.end ?? Float(audioArray.count) / 16000.0))

        let text =
            results
            .compactMap { $0?.first?.segments.map(\.text).joined(separator: " ") }
            .joined(separator: " ")
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return (text, wordOffset, duration)
    }

    // MARK: - Utils

    /// Delegates to `Shared/TextAlignmentUtilities.swift` so both the macOS and
    /// iOS alignment paths use one source of truth.
    private func tokenize(_ text: String) -> [String] {
        tokenizeForAlignment(text)
    }

    private func findBestMatch(blockTokens: [String], in transcriptWindow: [TransTokenRecord]) -> (
        windowStart: Int, confidence: Double
    )? {
        guard !blockTokens.isEmpty, !transcriptWindow.isEmpty else { return nil }

        let transcriptWords = transcriptWindow.map { $0.word }
        let blockSet = Set(blockTokens)
        let windowSize = blockTokens.count
        let stride = max(1, windowSize / 3)

        var bestScore: Double = 0
        var bestStart: Int = 0

        var start = 0
        while start < transcriptWords.count {
            let end = min(transcriptWords.count, start + windowSize)
            let s = jaccardScore(blockSet: blockSet, candidateSlice: transcriptWords[start..<end])
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
}
