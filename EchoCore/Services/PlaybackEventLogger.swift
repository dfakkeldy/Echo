import Foundation
import os.log

/// Extracts real-time playback event logging from PlayerModel into a dedicated
/// stateless service. All database writes are delegated through DatabaseService.
struct PlaybackEventLogger {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "PlaybackEventLogger")

    // MARK: - Session Logging

    func startPlaybackSessionLogging(
        id: String,
        databaseService: DatabaseService?,
        folderURL: URL?,
        currentTime: TimeInterval,
        currentTitle: String,
        currentSubtitle: String
    ) {
        guard let db = databaseService else { return }
        let dao = RealTimeEventDAO(db: db.writer)
        let folderKey = folderURL?.absoluteString
        do {
            try dao.log(
                id: id,
                eventType: RealTimeEventType.playbackSession.rawValue,
                audiobookID: folderKey,
                mediaTimestamp: currentTime,
                startedAt: Date(),
                endedAt: nil,
                title: currentTitle,
                subtitle: currentSubtitle,
                metadataJSON: nil,
                sourceItemID: nil,
                sourceItemType: nil
            )
        } catch {
            logger.error("Failed to log playback session start for \(folderURL?.lastPathComponent ?? "nil"): \(error.localizedDescription)")
        }
    }

    func endPlaybackSessionLogging(
        id: String,
        databaseService: DatabaseService?
    ) {
        guard let db = databaseService else { return }
        let dao = RealTimeEventDAO(db: db.writer)
        do {
            try dao.updateEndedAt(id: id, endedAt: Date())
        } catch {
            logger.error("Failed to log playback session end: \(error.localizedDescription)")
        }
    }

    // MARK: - Real-Time Event Logging

    func logRealTimeEvent(
        type: RealTimeEventType,
        databaseService: DatabaseService?,
        folderURL: URL?,
        title: String,
        subtitle: String?,
        timestamp: TimeInterval?,
        sourceItemID: String?,
        sourceItemType: String?
    ) {
        guard let db = databaseService else { return }
        let dao = RealTimeEventDAO(db: db.writer)
        let folderKey = folderURL?.absoluteString
        do {
            try dao.log(
                eventType: type.rawValue,
                audiobookID: folderKey,
                mediaTimestamp: timestamp,
                startedAt: Date(),
                endedAt: nil,
                title: title,
                subtitle: subtitle,
                metadataJSON: nil,
                sourceItemID: sourceItemID,
                sourceItemType: sourceItemType
            )
        } catch {
            logger.error("Failed to log timeline event \(type.rawValue) for \(folderURL?.lastPathComponent ?? "nil"): \(error.localizedDescription)")
        }
    }
}
