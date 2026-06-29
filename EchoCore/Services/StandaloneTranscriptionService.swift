// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import Synchronization
@preconcurrency import WhisperKit
import os.log

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
    @ObservationIgnored private nonisolated let currentTask = StandaloneTranscriptionTaskHandle()
    @ObservationIgnored private var lastStartArgs:
        (audiobookID: String, audioFileURL: URL, chapters: [Chapter])?
    private let logger = Logger(category: "StandaloneTranscription")
    private static let isoFormatter = ISO8601DateFormatter()

    init(db: DatabaseWriter) {
        self.db = db
    }

    nonisolated deinit {
        currentTask.cancel()
    }

    /// Begins the transcription pipeline.
    ///
    /// - Parameters:
    ///   - audioFileURL: The single audio file for the audiobook.
    ///   - chapters: All chapters to transcribe. Chapter 0 is transcribed
    ///     on the caller's actor; the rest run in the background.
    func start(
        audiobookID: String, audioFileURL: URL, chapters: [Chapter], resume: Bool = true
    ) async {
        guard let db else { return }
        lastStartArgs = (audiobookID, audioFileURL, chapters)
        progress.reset()
        progress.chaptersTotal = chapters.count
        progress.isRunning = true

        guard !chapters.isEmpty else {
            progress.isRunning = false
            return
        }

        // Chapter 0: transcribe immediately on the caller's executor.
        await transcribeChapter(
            audiobookID: audiobookID,
            audioFileURL: audioFileURL,
            chapter: chapters[0],
            chapterIndex: 0,
            resume: resume,
            db: db
        )
        progress.chaptersComplete = 1

        guard chapters.count > 1, !Task.isCancelled else {
            progress.isRunning = false
            return
        }

        // Remaining chapters: background, one at a time.
        currentTask.set(
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                defer {
                    Task { @MainActor in
                        self.progress.isRunning = false
                    }
                }
                for i in 1..<chapters.count {
                    guard !Task.isCancelled else { break }
                    await self.transcribeChapter(
                        audiobookID: audiobookID,
                        audioFileURL: audioFileURL,
                        chapter: chapters[i],
                        chapterIndex: i,
                        resume: resume,
                        db: db
                    )
                    await MainActor.run { self.progress.chaptersComplete = i + 1 }
                }
            })
    }

    /// Stops the running pipeline without marking it cancelled, so it can be
    /// resumed from the first incomplete chapter via `resume()`.
    func pause() {
        currentTask.cancel()
        progress.isRunning = false
    }

    /// Continues from the first chapter without persisted rows, reusing the
    /// last `start(...)` arguments. No-op if nothing was started yet.
    func resume() {
        guard let args = lastStartArgs else { return }
        Task { @MainActor in
            await self.start(
                audiobookID: args.audiobookID,
                audioFileURL: args.audioFileURL,
                chapters: args.chapters,
                resume: true)
        }
    }

    /// Deletes the book's raw ASR rows and its materialized reader projection,
    /// then resets progress so a subsequent `start(resume:false)`-style run
    /// produces a single clean copy.
    func clearTranscript(audiobookID: String) async {
        guard let db else { return }
        do {
            try await db.write { database in
                try StandaloneTranscriptRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .deleteAll(database)
                try database.execute(
                    sql:
                        "DELETE FROM word_timing WHERE audiobook_id = ? AND epub_block_id LIKE 'transcript-%'",
                    arguments: [audiobookID])
                try database.execute(
                    sql:
                        "DELETE FROM timeline_item WHERE audiobook_id = ? AND source_table = 'standalone_transcript'",
                    arguments: [audiobookID])
                try database.execute(
                    sql: "DELETE FROM epub_block WHERE audiobook_id = ? AND id LIKE 'transcript-%'",
                    arguments: [audiobookID])
            }
            progress.reset()
        } catch {
            logger.error("clearTranscript failed: \(error.localizedDescription)")
        }
    }

    /// Cancels the entire pipeline and resets progress state.
    func cancel() {
        currentTask.cancel()
        progress.isCancelled = true
        progress.isRunning = false
    }

    // MARK: - Private

    /// Transcribes a single chapter by reading its audio window, running
    /// WhisperKit with VAD chunking, and writing the resulting segments
    /// to the `standalone_transcript` table.
    private func transcribeChapter(
        audiobookID: String,
        audioFileURL: URL,
        chapter: Chapter,
        chapterIndex: Int,
        resume: Bool,
        db: DatabaseWriter
    ) async {
        let chapterDuration = chapter.endSeconds - chapter.startSeconds
        guard chapterDuration > 0 else {
            logger.debug("Skipping empty chapter \(chapterIndex)")
            return
        }
        // --- ADD RESUME GUARD HERE ---
        if resume {
            let existing = try? await db.read { database in
                try StandaloneTranscriptRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .filter(Column("chapter_index") == chapterIndex)
                    .fetchCount(database)
            }
            if let existing, existing > 0 {
                logger.debug("Resume: chapter \(chapterIndex) already has rows; skipping")
                return
            }
        }
        // --- END RESUME GUARD ---
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

            // Don't start the (uninterruptible) transcription if cancellation
            // arrived while reading audio or acquiring the model — otherwise a
            // pause()/cancel() still runs a full chapter (CODE_AUDIT.md §3.10).
            guard !Task.isCancelled else { return }

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
                audiobookID: audiobookID
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
            logger.error(
                "Failed to transcribe chapter \(chapterIndex): \(error.localizedDescription)")
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
        let segments =
            results
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

private nonisolated final class StandaloneTranscriptionTaskHandle: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    func set(_ newTask: Task<Void, Never>) {
        task.withLock { currentTask in
            currentTask = newTask
        }
    }

    func cancel() {
        let currentTask = task.withLock { currentTask in
            currentTask
        }
        currentTask?.cancel()
    }
}

/// Tracks progress of the standalone transcription pipeline across all chapters.
@MainActor @Observable
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
