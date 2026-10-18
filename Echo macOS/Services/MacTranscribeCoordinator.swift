// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacTranscribeCoordinator.swift
//  Echo macOS
//
//  macOS equivalent of TranscribeBookCoordinator. Owns the audio-only
//  transcription flow for one book: runs WhisperKit, projects the result
//  into the reader tables, and marks provenance so the macOS reader picks
//  it up. Pure @MainActor @Observable, no UIKit.
//

import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class MacTranscribeCoordinator {
    let service: StandaloneTranscriptionService
    private(set) var isFinalizing = false

    @ObservationIgnored private let writer: DatabaseWriter
    private let logger = Logger(category: "MacTranscribeCoordinator")

    init(db: DatabaseWriter) {
        self.writer = db
        self.service = StandaloneTranscriptionService(db: db)
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
        guard await hasTranscriptRows(audiobookID: audiobookID, chapterCount: chapters.count)
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

    /// Deletes the book's raw ASR rows, its materialized reader projection,
    /// and resets progress so a subsequent start(resume:false) produces a
    /// single clean copy.
    func clearTranscript(audiobookID: String) async {
        await service.clearTranscript(audiobookID: audiobookID)
    }

    private func hasTranscriptRows(audiobookID: String, chapterCount: Int) async -> Bool {
        guard chapterCount > 0 else { return false }
        do {
            let chapterIndices = try await writer.read { database in
                try Int.fetchAll(
                    database,
                    sql:
                        "SELECT DISTINCT chapter_index FROM standalone_transcript WHERE audiobook_id = ?",
                    arguments: [audiobookID])
            }
            let availableChapterIndices = Set(chapterIndices)
            return (0..<chapterCount).allSatisfy { availableChapterIndices.contains($0) }
        } catch {
            logger.error("transcription readiness check failed: \(error.localizedDescription)")
            return false
        }
    }
}
