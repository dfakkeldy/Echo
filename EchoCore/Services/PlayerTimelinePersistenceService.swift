import Foundation
import os.log

/// Coordinates SQL persistence for audiobooks, transcripts, and timeline
/// items. Extracted from PlayerModel so the view model stays focused on
/// playback orchestration rather than database wiring.
final class PlayerTimelinePersistenceService {
    private static let logger = Logger(subsystem: "com.orbitaudiobooks", category: "PlayerTimelinePersistence")

    var databaseService: DatabaseService?

    // MARK: - EPUB lookup

    func hasEPUB(for audiobookID: String?) -> Bool {
        guard let db = databaseService, let audiobookID else { return false }
        return (try? EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID).isEmpty) == false
    }

    // MARK: - SQL persistence

    func persistAudiobookToSQL(folderURL: URL, tracks: [Track], duration: TimeInterval?) {
        guard let db = databaseService else { return }
        TimelineIngestionService.persistAudiobook(db: db, folderURL: folderURL, tracks: tracks, duration: duration)
    }

    func persistTranscriptToSQL(audiobookID: String, transcription: [TranscriptionSegment]) {
        guard let db = databaseService else { return }
        TimelineIngestionService.persistTranscript(db: db, audiobookID: audiobookID, transcription: transcription)
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
