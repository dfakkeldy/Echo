// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
@preconcurrency import WhisperKit
import os.log

/// macOS alignment orchestrator using the shared EchoCore pipeline.
///
/// Uses the shared **TokenDTW** (word-timestamp-aware dynamic time warping
/// with bisection), **AnchorSelector** (confidence + monotonicity filtering),
/// and writes anchors to the shared database so timeline recalculation +
/// auto-scroll work immediately, replacing the old sidecar-only approach.
@MainActor
@Observable
final class MacAlignmentService {
    private let logger = Logger(category: "MacAlignment")

    var isAligning: Bool = false
    var alignmentProgress: Double = 0
    var alignmentStatus: String = ""

    private var whisperKit: WhisperKit?

    /// Aligns an audiobook-EPUB pair, writing anchors into the shared database.
    func align(
        audiobookID: String,
        audioURL: URL,
        epubURL: URL,
        dbService: DatabaseService
    ) async throws {
        isAligning = true
        alignmentProgress = 0
        alignmentStatus = "Extracting EPUB text…"

        defer {
            isAligning = false
            alignmentProgress = 1.0
            WhisperSession.shared.release()
            self.whisperKit = nil
        }

        let (epubDir, cleanupDir) = try await expandEPUBIfNeeded(epubURL)
        defer { if let cleanupDir { try? FileManager.default.removeItem(at: cleanupDir) } }

        let parsed = try parseEPUBBlocks(audiobookID: audiobookID, epubURL: epubDir)
        let epubTokens: [TokenDTW.EPubToken] = parsed.blocks.compactMap { block in
            guard let text = block.text, !text.isEmpty else { return nil }
            return TokenDTW.EPubToken(text: text, blockID: block.id)
        }
        guard !epubTokens.isEmpty else { throw AlignmentError.noTextBlocks }

        alignmentStatus = "Loading WhisperKit…"
        try await loadModelIfNeeded()

        alignmentStatus = "Transcribing audio…"
        let extractor = AudioExtractor(url: audioURL)
        let totalDuration = try await extractor.prepare()
        let chunkDuration: TimeInterval = 30.0
        var audioTokens: [TokenDTW.AudioToken] = []

        while let (pcmBuffer, chunkStartTime) = try await extractor.readNextChunk(
            durationInSeconds: chunkDuration)
        {
            alignmentStatus =
                "Transcribing \(formatTimeHMS(chunkStartTime)) / \(formatTimeHMS(totalDuration))…"
            alignmentProgress = (chunkStartTime / totalDuration) * 0.5
            let result = try await transcribeChunk(pcmBuffer)
            for token in result.tokens {
                audioTokens.append(
                    TokenDTW.AudioToken(
                        text: token.word, time: chunkStartTime + token.start))
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard !audioTokens.isEmpty else { throw AlignmentError.noAudioTokens }

        alignmentStatus =
            "Aligning \(epubTokens.count) blocks with \(audioTokens.count) tokens…"
        alignmentProgress = 0.75

        let candidates = TokenDTW.alignWithBisection(epub: epubTokens, audio: audioTokens)
        let selected = AnchorSelector.select(candidates: candidates)
        guard !selected.isEmpty else { throw AlignmentError.noAnchorsProduced }

        alignmentStatus = "Saving \(selected.count) anchors…"
        alignmentProgress = 0.90

        let alignmentService = AlignmentService(
            db: dbService.writer, audiobookID: audiobookID)

        try await dbService.writer.write { db in
            let previous =
                try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("source") == AlignmentAnchorRecord.Source.autoAlignment.rawValue)
                .fetchAll(db)
            for record in previous { try record.delete(db) }
        }

        let now = AlignmentService.isoFormatter.string(from: Date())
        var records: [AlignmentAnchorRecord] = []
        for candidate in selected {
            records.append(
                AlignmentAnchorRecord(
                    id: UUID().uuidString, audiobookID: audiobookID,
                    epubBlockID: candidate.blockID, audioTime: candidate.time,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
                    note: "Mac DTW alignment (TokenDTW + AnchorSelector)",
                    createdAt: now, modifiedAt: nil))
        }
        try alignmentService.insertAnchors(records)

        alignmentStatus = "Recalculating timeline…"
        alignmentProgress = 0.95
        try alignmentService.recalculateTimeline()

        alignmentStatus =
            "Alignment complete — \(selected.count) anchors across \(epubTokens.count) blocks."
        alignmentProgress = 1.0
        logger.info("Alignment complete: \(selected.count) anchors")
    }

    // MARK: - EPUB Extraction

    private func expandEPUBIfNeeded(_ url: URL) async throws -> (dir: URL, cleanup: URL?) {
        guard url.pathExtension.lowercased() == "epub" else { return (url, nil) }
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                proc.terminationStatus == 0
                    ? c.resume()
                    : c.resume(
                        throwing: AlignmentError.unzipFailed(code: Int(proc.terminationStatus)))
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                c.resume(throwing: error)
            }
        }
        let std = tempDir.standardized
        if let enumerator = FileManager.default.enumerator(
            at: tempDir, includingPropertiesForKeys: nil)
        {
            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.standardized.path.hasPrefix(std.path) else {
                    throw AlignmentError.pathTraversal(path: fileURL.path)
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

    private func transcribeChunk(_ audioArray: [Float]) async throws -> TranscriptionResult {
        guard !audioArray.isEmpty else { return TranscriptionResult(tokens: []) }
        guard let wk = whisperKit else { throw AlignmentError.modelNotLoaded }
        let options = DecodingOptions(
            task: .transcribe, language: "en", temperature: 0.0,
            wordTimestamps: true, suppressBlank: true, chunkingStrategy: .vad)
        let results = await wk.transcribe(audioArrays: [audioArray], decodeOptions: options)
        let allSegments = results.compactMap { $0?.first?.segments }.flatMap { $0 }
        var tokens: [WordToken] = []
        for segment in allSegments {
            guard let words = segment.words else { continue }
            for word in words {
                tokens.append(
                    WordToken(
                        word: word.word.trimmingCharacters(in: .punctuationCharacters).lowercased(),
                        start: TimeInterval(word.start), end: TimeInterval(word.end)))
            }
        }
        return TranscriptionResult(tokens: tokens)
    }
}

extension MacAlignmentService {
    struct WordToken {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
    }
    struct TranscriptionResult { let tokens: [WordToken] }
    enum AlignmentError: Error, LocalizedError {
        case noTextBlocks, noAudioTokens, noAnchorsProduced, modelNotLoaded
        case unzipFailed(code: Int)
        case pathTraversal(path: String)
        var errorDescription: String? {
            switch self {
            case .noTextBlocks: return "No text blocks found in EPUB."
            case .noAudioTokens: return "No transcription tokens extracted."
            case .noAnchorsProduced: return "DTW alignment produced no anchors."
            case .modelNotLoaded: return "WhisperKit model not loaded."
            case .unzipFailed(let c): return "Failed to unzip EPUB (exit \(c))."
            case .pathTraversal(let p): return "Path traversal: \(p)"
            }
        }
    }
}
