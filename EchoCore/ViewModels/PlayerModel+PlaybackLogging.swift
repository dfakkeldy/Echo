import Foundation

// MARK: - Timeline Event Logging

extension PlayerModel {
    func startPlaybackSessionLogging() {
        let id = UUID().uuidString
        currentPlaybackEventID = id
        eventLogger.startPlaybackSessionLogging(
            id: id,
            databaseService: databaseService,
            folderURL: folderURL,
            currentTime: audioEngine.currentTime,
            currentTitle: currentTitle,
            currentSubtitle: currentSubtitle
        )
    }

    func endPlaybackSessionLogging() {
        guard let id = currentPlaybackEventID else { return }
        eventLogger.endPlaybackSessionLogging(id: id, databaseService: databaseService)
        currentPlaybackEventID = nil
    }

    func logRealTimeEvent(
        type: RealTimeEventType,
        title: String? = nil,
        subtitle: String? = nil,
        timestamp: TimeInterval? = nil,
        sourceItemID: String? = nil,
        sourceItemType: String? = nil
    ) {
        eventLogger.logRealTimeEvent(
            type: type,
            databaseService: databaseService,
            folderURL: folderURL,
            title: title ?? currentTitle,
            subtitle: subtitle,
            timestamp: timestamp,
            sourceItemID: sourceItemID,
            sourceItemType: sourceItemType
        )
    }
}
