// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Coordinates SQL persistence for audiobooks, transcripts, and timeline
/// items. Extracted from PlayerModel so the view model stays focused on
/// playback orchestration rather than database wiring.
final class PlayerTimelinePersistenceService {
    private static let logger = Logger(category: "PlayerTimelinePersistence")

    var databaseService: DatabaseService?
    private var ingestionTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    func cancelPendingIngestion() {
        for pending in ingestionTasks.values { pending.task.cancel() }
        ingestionTasks.removeAll()
    }

    // MARK: - EPUB lookup

    func hasEPUB(for audiobookID: String?) -> Bool {
        guard let db = databaseService, let audiobookID else { return false }
        return (try? EPubBlockDAO(db: db.writer).hasVisibleBlocks(for: audiobookID)) == true
    }

    // MARK: - SQL persistence

    func persistAudiobookToSQL(folderURL: URL, tracks: [Track], duration: TimeInterval?) {
        guard let db = databaseService else { return }
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folderURL, tracks: tracks, duration: duration)
    }

    func persistTranscriptToSQL(audiobookID: String, transcription: [TranscriptionSegment]) {
        guard let db = databaseService else { return }
        TimelineIngestionService.persistTranscript(
            db: db, audiobookID: audiobookID, transcription: transcription)
    }

    func ingestTimelineItems(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcription: [TranscriptionSegment],
        enhancedTranscription: [EnhancedTranscriptionSegment],
        folderURL: URL?
    ) async {
        guard let db = databaseService else { return }
        ingestionTasks[audiobookID]?.task.cancel()
        let requestID = UUID()
        let task = Task {
            await TimelineIngestionService.ingestItems(
                db: db,
                audiobookID: audiobookID,
                audioURL: audioURL,
                chapters: chapters,
                transcription: transcription,
                enhancedTranscription: enhancedTranscription,
                folderURL: folderURL
            )
        }
        ingestionTasks[audiobookID] = (requestID, task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if ingestionTasks[audiobookID]?.id == requestID {
            ingestionTasks[audiobookID] = nil
        }
    }

    // MARK: - Re-ingestion

    func reingestTimelineFromEPUB(
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcription: [TranscriptionSegment],
        enhancedTranscription: [EnhancedTranscriptionSegment],
        folderURL: URL?
    ) async {
        await ingestTimelineItems(
            audiobookID: audiobookID,
            audioURL: audioURL,
            chapters: chapters,
            transcription: transcription,
            enhancedTranscription: enhancedTranscription,
            folderURL: folderURL
        )
    }
}
