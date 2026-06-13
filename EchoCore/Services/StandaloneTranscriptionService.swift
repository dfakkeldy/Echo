import Foundation
import Observation
import GRDB
import os.log
@preconcurrency import WhisperKit

/// Orchestrates the solo transcription pipeline for audiobooks without
/// an EPUB or PDF companion.
///
/// The first chapter is transcribed immediately (foreground priority).
/// Remaining chapters are processed sequentially in a
/// `.background` detached task.
@MainActor
@Observable
final class StandaloneTranscriptionService {
    var progress = StandaloneProgressState()

    private weak var db: DatabaseWriter?
    private var currentTask: Task<Void, Never>?
    private let logger = Logger(category: "StandaloneTranscription")
    private static let isoFormatter = ISO8601DateFormatter()

    init(db: DatabaseWriter) {
        self.db = db
    }

    /// Begins the transcription pipeline.
    ///
    /// - Parameters:
    ///   - audioFileURL: The single audio file for the audiobook.
    ///   - chapters: All chapters to transcribe. Chapter 0 is transcribed
    ///     on the caller's actor; the rest run in the background.
    func start(audioFileURL: URL, chapters: [Chapter]) async {
        guard let db else { return }
        progress.reset()
        progress.chaptersTotal = chapters.count
        progress.isRunning = true

        guard !chapters.isEmpty else {
            progress.isRunning = false
            return
        }

        // Chapter 0: transcribe immediately on the caller's executor.
        await transcribeChapter(
            audioFileURL: audioFileURL,
            chapter: chapters[0],
            chapterIndex: 0,
            db: db
        )
        progress.chaptersComplete = 1

        guard chapters.count > 1, !Task.isCancelled else {
            progress.isRunning = false
            return
        }

        // Remaining chapters: background, one at a time.
        currentTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.progress.isRunning = false
                }
            }
            for i in 1 ..< chapters.count {
                guard !Task.isCancelled else { break }
                await self.transcribeChapter(
                    audioFileURL: audioFileURL,
                    chapter: chapters[i],
                    chapterIndex: i,
                    db: db
                )
                await MainActor.run { self.progress.chaptersComplete = i + 1 }
            }
        }
    }

    /// Pauses (cancels) any background transcription still in progress.
    func pause() {
        currentTask?.cancel()
    }

    /// Cancels the entire pipeline and resets progress state.
    func cancel() {
        currentTask?.cancel()
        progress.isCancelled = true
        progress.isRunning = false
    }

    // MARK: - Private

    /// Transcribes a single chapter by reading its audio window, running
    /// WhisperKit with VAD chunking, and writing the resulting segments
    /// to the `standalone_transcript` table.
    private func transcribeChapter(
        audioFileURL: URL,
        chapter: Chapter,
        chapterIndex: Int,
        db: DatabaseWriter
    ) async {
        let chapterDuration = chapter.endSeconds - chapter.startSeconds
        guard chapterDuration > 0 else {
            logger.debug("Skipping empty chapter \(chapterIndex)")
            return
        }

        do {
            // 1. Read audio for this chapter.
            let samples = try await AudioSegmentReader.samples(
                from: audioFileURL,
                at: chapter.startSeconds,
                duration: chapterDuration
            )
            guard !samples.isEmpty else {
                logger.debug("No audio samples for chapter \(chapterIndex)")
                return
            }

            // 2. Acquire the shared WhisperKit model.
            let wk = try await WhisperSession.shared.acquire()
            defer { WhisperSession.shared.release() }

            // 3. Transcribe with VAD chunking — WhisperKit handles silence
            //    splitting internally so we get one segment per speech burst.
            let options = DecodingOptions(
                task: .transcribe,
                language: "en",
                temperature: 0.0,
                wordTimestamps: true,
                suppressBlank: true,
                chunkingStrategy: .vad
            )
            let results = await wk.transcribe(
                audioArrays: [samples],
                decodeOptions: options
            )

            // 4. Flatten WhisperKit results into DB records.
            let records = buildRecords(
                from: results,
                captureStart: chapter.startSeconds,
                chapterIndex: chapterIndex,
                audiobookID: audioFileURL.absoluteString
            )
            guard !records.isEmpty else {
                logger.debug("No transcribed segments for chapter \(chapterIndex)")
                return
            }

            // 5. Persist in a single transaction (checkpoint on chunk).
            try await db.write { db in
                for var record in records {
                    try record.insert(db)
                }
            }
            logger.info("Saved \(records.count) segments for chapter \(chapterIndex)")
        } catch {
            logger.error("Failed to transcribe chapter \(chapterIndex): \(error.localizedDescription)")
        }
    }

    /// Flattens WhisperKit's per-window results into time-ordered
    /// `StandaloneTranscriptRecord` values, one per VAD segment.
    private func buildRecords(
        from results: [[TranscriptionResult]?],
        captureStart: TimeInterval,
        chapterIndex: Int,
        audiobookID: String
    ) -> [StandaloneTranscriptRecord] {
        let segments = results
            .compactMap { $0 }
            .flatMap { $0 }
            .flatMap { $0.segments }
            .sorted { $0.start < $1.start }

        let now = Self.isoFormatter.string(from: Date())
        var records: [StandaloneTranscriptRecord] = []

        for (index, seg) in segments.enumerated() {
            let text = Self.clean(seg.text)
            guard !text.isEmpty else { continue }

            let wordsJSON: String? = {
                guard let wordTimings = seg.words, !wordTimings.isEmpty else { return nil }
                let words = wordTimings.map { timing in
                    StandaloneTranscribedWord(
                        word: timing.word,
                        start: captureStart + TimeInterval(timing.start),
                        end: captureStart + TimeInterval(timing.end),
                        confidence: timing.probability
                    )
                }
                return String(data: (try? JSONEncoder().encode(words)) ?? Data(), encoding: .utf8)
            }()

            let record = StandaloneTranscriptRecord(
                id: UUID().uuidString,
                audiobookID: audiobookID,
                chapterIndex: chapterIndex,
                segmentIndex: index,
                text: text,
                startTime: captureStart + TimeInterval(seg.start),
                endTime: captureStart + TimeInterval(seg.end),
                wordsJSON: wordsJSON,
                createdAt: now
            )
            records.append(record)
        }

        return records
    }

    /// Strips Whisper special tokens (`<|endoftext|>`, `<|nospeech|>`, etc.)
    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tracks progress of the standalone transcription pipeline across all chapters.
@Observable
final class StandaloneProgressState {
    var chaptersTotal = 0
    var chaptersComplete = 0
    var currentChapterIndex = 0
    var isRunning = false
    var isCancelled = false

    fileprivate func reset() {
        chaptersTotal = 0
        chaptersComplete = 0
        currentChapterIndex = 0
        isRunning = false
        isCancelled = false
    }
}
