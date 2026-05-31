import Foundation
import os.log

/// Handles SQL persistence of audiobooks, tracks, transcripts, and timeline
/// items — extracted from PlayerModel to keep it focused on playback orchestration.
struct TimelineIngestionService {

    private static let logger = Logger(subsystem: "com.orbitaudiobooks", category: "TimelineIngestion")

    // MARK: - Audiobook & Track persistence

    /// Saves the current audiobook and its tracks to SQL so the unified timeline
    /// VIEW returns content. Safe to call on every folder load — uses INSERT OR REPLACE.
    static func persistAudiobook(
        db: DatabaseService,
        folderURL: URL,
        tracks: [Track],
        duration: TimeInterval?
    ) {
        let audiobookID = folderURL.absoluteString
        let title = folderURL.deletingPathExtension().lastPathComponent
        let audiobook = AudiobookRecord(
            id: audiobookID,
            title: title,
            author: nil,
            duration: duration ?? 0,
            fileCount: tracks.count,
            addedAt: Date().ISO8601Format()
        )
        do {
            try AudiobookDAO(db: db.writer).save(audiobook)
            let records = tracks.enumerated().map { (i, track) in
                TrackRecord(
                    id: track.id,
                    audiobookID: audiobookID,
                    title: track.title,
                    duration: 0,
                    filePath: track.url.absoluteString,
                    isEnabled: true,
                    sortOrder: i,
                    playlistPosition: nil
                )
            }
            try TrackDAO(db: db.writer).deleteAll(for: audiobookID)
            try TrackDAO(db: db.writer).insertAll(records, audiobookID: audiobookID)
        } catch {
            logger.error("Failed to persist audiobook to SQL: \(error.localizedDescription)")
        }
    }

    // MARK: - Transcript persistence

    static func persistTranscript(
        db: DatabaseService,
        audiobookID: String,
        transcription: [TranscriptionSegment]
    ) {
        guard !transcription.isEmpty else { return }
        let records = transcription.map { segment in
            TranscriptionRecord(
                id: nil,
                audiobookID: audiobookID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text
            )
        }
        do {
            try TranscriptionDAO(db: db.writer).deleteAll(for: audiobookID)
            try TranscriptionDAO(db: db.writer).insertAll(records, audiobookID: audiobookID)
        } catch {
            logger.error("Failed to persist transcript: \(error.localizedDescription)")
        }
    }

    // MARK: - Timeline ingestion

    /// Ingests timeline items (chapter markers, text segments, etc.) into the
    /// timeline_item table so the unified dual-path feed has data to display.
    static func ingestItems(
        db: DatabaseService,
        audiobookID: String,
        audioURL: URL,
        chapters: [Chapter],
        transcription: [TranscriptionSegment],
        enhancedTranscription: [EnhancedTranscriptionSegment],
        folderURL: URL?
    ) async {
        let hasTranscript = !transcription.isEmpty
        let hasEnhancedTranscript = !enhancedTranscription.isEmpty
        let hasEPUB = (try? EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID).isEmpty) == false
        let strategy = TimelineIngestionFactory.strategy(
            hasTranscript: hasTranscript,
            hasEnhancedTranscript: hasEnhancedTranscript,
            hasEPUB: hasEPUB
        )

        // Load EPUB blocks and anchors if available.
        let epubBlocks: [EPubBlockRecord]? = {
            guard hasEPUB, let folderURL else { return nil }
            return try? EPubBlockDAO(db: db.writer).visibleBlocks(for: folderURL.absoluteString)
        }()
        let alignmentAnchors: [AlignmentAnchorRecord]? = {
            guard hasEPUB, let folderURL else { return nil }
            return try? AlignmentAnchorDAO(db: db.writer).anchors(for: folderURL.absoluteString)
        }()

        do {
            let items = try await strategy.ingest(
                audiobookID: audiobookID,
                audioURL: audioURL,
                chapters: chapters,
                transcript: hasTranscript ? transcription : nil,
                enhancedTranscript: hasEnhancedTranscript ? enhancedTranscription : nil,
                epubBlocks: epubBlocks,
                alignmentAnchors: alignmentAnchors,
                bookmarks: nil,
                flashcards: nil
            )
            guard !items.isEmpty else { return }
            try TimelineDAO(db: db.writer).deleteAll(for: audiobookID)
            try TimelineDAO(db: db.writer).ingest(items)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .timelineItemsIngested,
                    object: nil,
                    userInfo: ["audiobookID": audiobookID]
                )
            }
        } catch {
            logger.error("Failed to ingest timeline items: \(error.localizedDescription)")
        }
    }
}
