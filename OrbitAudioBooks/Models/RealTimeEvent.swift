import Foundation

enum RealTimeEventType: String, Codable, CaseIterable {
    case playbackSession = "playback_session"
    case bookmarkCreated = "bookmark_created"
    case flashcardReviewed = "flashcard_reviewed"
    case voiceMemoRecorded = "voice_memo_recorded"
    case noteCreated = "note_created"
    case plannedSessionCompleted = "planned_session_completed"
    case chapterTransition = "chapter_transition"
}

struct RealTimeEvent: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var eventType: RealTimeEventType
    var audiobookID: String?
    var mediaTimestamp: TimeInterval?
    var startedAt: Date
    var endedAt: Date?
    var title: String?
    var subtitle: String?
    var metadataJSON: String?
    var sourceItemID: String?
    var sourceItemType: String?
}

extension RealTimeEvent {
    init(from record: RealTimeEventRecord) {
        let fmt = ISO8601DateFormatter()
        self.id = record.id
        self.eventType = RealTimeEventType(rawValue: record.eventType) ?? .playbackSession
        self.audiobookID = record.audiobookID
        self.mediaTimestamp = record.mediaTimestamp
        self.startedAt = fmt.date(from: record.startedAt) ?? Date()
        self.endedAt = record.endedAt.flatMap(fmt.date(from:))
        self.title = record.title
        self.subtitle = record.subtitle
        self.metadataJSON = record.metadataJSON
        self.sourceItemID = record.sourceItemID
        self.sourceItemType = record.sourceItemType
    }

    func toRecord() -> RealTimeEventRecord {
        RealTimeEventRecord(
            id: id,
            eventType: eventType.rawValue,
            audiobookID: audiobookID,
            mediaTimestamp: mediaTimestamp,
            startedAt: startedAt.ISO8601Format(),
            endedAt: endedAt?.ISO8601Format(),
            title: title,
            subtitle: subtitle,
            metadataJSON: metadataJSON,
            sourceItemID: sourceItemID,
            sourceItemType: sourceItemType
        )
    }
}
