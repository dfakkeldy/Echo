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
    /// One progress report from ``align(audiobookID:audioURL:epubURL:dbService:onProgress:)``.
    ///
    /// `fraction` is `nil` for the phases whose duration genuinely cannot be
    /// predicted — downloading and compiling the speech model, the DTW match,
    /// and the timeline rebuild. A `nil` asks the UI for an indeterminate bar,
    /// which reads as "working, duration unknown"; a determinate bar parked at
    /// the same number for ten minutes reads as "hung".
    struct Progress: Equatable, Sendable {
        let fraction: Double?
        let message: String
    }

    private let logger = Logger(category: "MacAlignment")

    var isAligning: Bool = false
    var alignmentProgress: Double = 0
    var alignmentStatus: String = ""
    /// True while the current phase has no meaningful fraction. Mirrors the
    /// `nil` in ``Progress/fraction`` for observers reading the properties
    /// rather than the callback.
    var alignmentIsIndeterminate: Bool = false

    private var whisperKit: WhisperKit?

    /// Aligns an audiobook-EPUB pair, writing anchors into the shared database.
    ///
    /// - Parameter onProgress: Called on the main actor at every phase change
    ///   and once per transcribed chunk. Transcription dominates the run — for
    ///   a full-length audiobook it is the difference between a bar that moves
    ///   for an hour and one that never moves at all — so it reports genuine
    ///   per-chunk progress with an estimate of the time remaining.
    ///
    ///   Non-optional with a no-op default rather than `((Progress) -> Void)?`:
    ///   an optional closure parameter is implicitly `@escaping`, which would
    ///   stop the batch queue from passing its non-escaping progress reporter
    ///   straight through.
    func align(
        audiobookID: String,
        audioURL: URL,
        epubURL: URL,
        dbService: DatabaseService,
        onProgress: (Progress) -> Void = { _ in }
    ) async throws {
        isAligning = true
        alignmentProgress = 0

        /// Publishes one report to both the observable properties and the
        /// caller's callback, so the two can never drift apart.
        func report(_ fraction: Double?, _ message: String) {
            if let fraction { alignmentProgress = fraction }
            alignmentIsIndeterminate = fraction == nil
            alignmentStatus = message
            onProgress(Progress(fraction: fraction, message: message))
        }

        report(0.0, "Reading EPUB text…")

        defer {
            isAligning = false
            alignmentProgress = 1.0
            alignmentIsIndeterminate = false
            WhisperSession.shared.release()
            self.whisperKit = nil
        }

        let (epubDir, cleanupDir) = try await expandEPUBIfNeeded(epubURL)
        defer { if let cleanupDir { try? FileManager.default.removeItem(at: cleanupDir) } }

        let parsed = try parseEPUBBlocks(audiobookID: audiobookID, epubURL: epubDir)
        let alignmentBlocks = CommercialAudioAlignmentSource.blocks(from: parsed.blocks)
        let epubTokens: [TokenDTW.EPubToken] = alignmentBlocks.compactMap { block in
            guard let text = block.text else { return nil }
            return TokenDTW.EPubToken(text: text, blockID: block.id)
        }
        guard !epubTokens.isEmpty else { throw AlignmentError.noTextBlocks }

        // The first run downloads and compiles the model, which can take
        // minutes on its own — hence indeterminate rather than a parked number.
        report(nil, "Preparing the speech model…")
        try await loadModelIfNeeded()

        let extractor = AudioExtractor(url: audioURL)
        let totalDuration = try await extractor.prepare()
        let chunkDuration: TimeInterval = 30.0
        var audioTokens: [TokenDTW.AudioToken] = []
        let transcriptionStart = Date()

        report(Self.transcribeStart, "Transcribing audio…")

        while let (pcmBuffer, chunkStartTime) = try await extractor.readNextChunk(
            durationInSeconds: chunkDuration)
        {
            let heard = totalDuration > 0 ? min(1.0, chunkStartTime / totalDuration) : 0
            report(
                Self.transcribeStart + heard * (Self.transcribeEnd - Self.transcribeStart),
                Self.transcribeMessage(
                    heard: chunkStartTime,
                    total: totalDuration,
                    elapsed: Date().timeIntervalSince(transcriptionStart)))
            let result = try await transcribeChunk(pcmBuffer)
            for token in result.tokens {
                audioTokens.append(
                    TokenDTW.AudioToken(
                        text: token.word, time: chunkStartTime + token.start))
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard !audioTokens.isEmpty else { throw AlignmentError.noAudioTokens }

        // DTW cost scales with tokens × blocks and reports nothing from inside,
        // so name the scale in the message and let the bar go indeterminate.
        report(
            nil,
            """
            Matching \(audioTokens.count) spoken words to \(epubTokens.count) \
            paragraphs — this can take several minutes…
            """)

        // The cancellable variant checks for cancellation between bisection
        // steps, so "Stop and Remove" during the match actually stops instead
        // of burning CPU on a book the user has already removed.
        let selected = try await Task.detached(priority: .utility) {
            AnchorSelector.select(
                candidates: try await TokenDTW.alignWithBisectionCancellable(
                    epub: epubTokens, audio: audioTokens))
        }.value
        guard !selected.isEmpty else { throw AlignmentError.noAnchorsProduced }

        report(Self.saveAnchors, "Saving \(selected.count) anchors…")

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
        // `insertAnchors` already recalculates the timeline AND materializes
        // word timings (it forwards `materializeWordTimings: true` by default),
        // so a follow-up `recalculateTimeline()` would redo that whole pass.
        // Do it once here. Like DTW it is a single opaque call over the whole
        // book, so it reports indeterminate rather than a stuck 95%.
        report(nil, "Building the read-along timeline…")
        try await Task.detached(priority: .utility) {
            try alignmentService.insertAnchors(records)
        }.value

        // Emit the portable `alignment.json` sidecar next to the EPUB so this
        // Mac-produced alignment travels to the user's device (via their synced
        // library) and resolves there on import — block ids are stored as the
        // content-stable `s<i>-b<j>` suffix and re-prefixed on the importing
        // device. Best-effort: a sidecar write must not fail the alignment.
        do {
            let sidecarURL = try AlignmentSidecar.write(
                records,
                sourceBlocks: parsed.blocks,
                forEPUB: epubURL
            )
            logger.info("Wrote alignment sidecar: \(sidecarURL.lastPathComponent)")
        } catch {
            logger.error("Failed to write alignment sidecar: \(error.localizedDescription)")
        }

        report(
            1.0,
            "Alignment complete — \(selected.count) anchors across \(epubTokens.count) blocks.")
        logger.info("Alignment complete: \(selected.count) anchors")
    }

    // MARK: - Progress Phases

    /// Fraction at which transcription begins. Everything before it (EPUB
    /// parse, model load) is fast or indeterminate.
    static let transcribeStart = 0.05
    /// Fraction at which transcription hands over to the DTW match.
    static let transcribeEnd = 0.60
    /// Fraction reported while anchors are written.
    static let saveAnchors = 0.85

    /// The transcription line: how much audio has been heard, and — once
    /// there's enough of a sample to extrapolate from — how much longer it will
    /// take. Pure and `static` so the wording and the estimate are unit-testable
    /// without running WhisperKit.
    static func transcribeMessage(
        heard: TimeInterval,
        total: TimeInterval,
        elapsed: TimeInterval
    ) -> String {
        let position = "Transcribing \(formatTimeHMS(heard)) of \(formatTimeHMS(total))"
        // Below ~2% the sample is too short to extrapolate from, and a wildly
        // wrong "4 hours left" that then collapses is worse than no estimate.
        guard total > 0, elapsed > 0 else { return position + "…" }
        let fraction = heard / total
        guard fraction >= 0.02 else { return position + "…" }
        let remaining = elapsed / fraction - elapsed
        guard remaining.isFinite, remaining >= 1 else { return position + "…" }
        return position + " — about \(approximateDuration(remaining)) left"
    }

    /// A coarse, human duration ("3 min", "1 hr 20 min"). Deliberately rounded:
    /// this is an extrapolation, and second-level precision would overstate how
    /// much it knows.
    static func approximateDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(1, total)) sec" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
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
