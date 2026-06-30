// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import Foundation
    import GRDB
    import Observation
    import os.log

    /// Owns the audio-only transcription flow for one book: runs the WhisperKit
    /// pipeline, then projects the result into the reader tables and marks the
    /// book's provenance so the reader picks it up. iOS-only: it owns the
    /// `@MainActor` `StandaloneTranscriptionService` consumed by the reader UI.
    @MainActor
    @Observable
    final class TranscribeBookCoordinator {
        let service: StandaloneTranscriptionService
        private(set) var isFinalizing = false

        @ObservationIgnored private let writer: DatabaseWriter
        private let logger = Logger(category: "TranscribeBookCoordinator")

        init(db: DatabaseWriter) {
            writer = db
            service = StandaloneTranscriptionService(db: db)
        }

        /// Runs the pipeline and, on natural completion (not cancellation),
        /// finalizes the book into the reader.
        func transcribe(
            audiobookID: String, audioFileURL: URL, chapters: [Chapter], resume: Bool = true
        ) async {
            await service.start(
                audiobookID: audiobookID, audioFileURL: audioFileURL,
                chapters: chapters, resume: resume)
            // start() returns while the detached tail (chapters 1...n) is still
            // running, so wait for the whole run to settle before finalizing.
            await service.waitUntilFinished()
            // Finalize only on full, uncancelled completion — never a partial run.
            let progress = service.progress
            guard !progress.isCancelled, progress.chaptersTotal > 0,
                progress.chaptersComplete >= progress.chaptersTotal
            else { return }
            await finalize(audiobookID: audiobookID)
        }

        /// Projects raw ASR rows into the reader tables and stamps provenance.
        func finalize(audiobookID: String) async {
            isFinalizing = true
            defer { isFinalizing = false }
            do {
                try TranscriptMaterializer.materialize(audiobookID: audiobookID, writer: writer)
                let dao = AudiobookDAO(db: writer)
                if var book = try dao.get(audiobookID) {
                    book.textOrigin = "transcript"
                    try dao.save(book)
                }
            } catch {
                logger.error("finalize failed: \(error.localizedDescription)")
            }
        }
    }
#endif
