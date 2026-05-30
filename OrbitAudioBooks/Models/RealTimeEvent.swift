import Foundation

enum RealTimeEventType: String, Codable, CaseIterable, Sendable {
    case playbackSession = "playback_session"
    case bookmarkCreated = "bookmark_created"
    case flashcardReviewed = "flashcard_reviewed"
    case voiceMemoRecorded = "voice_memo_recorded"
    case noteCreated = "note_created"
    case plannedSessionCompleted = "planned_session_completed"
    case chapterTransition = "chapter_transition"
}

struct RealTimeEvent: Identifiable, Codable, Equatable, Hashable, Sendable {
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
    private static let isoFormatter = ISO8601DateFormatter()

    init(from record: RealTimeEventRecord) {
        self.id = record.id
        self.eventType = RealTimeEventType(rawValue: record.eventType) ?? .playbackSession
        self.audiobookID = record.audiobookID
        self.mediaTimestamp = record.mediaTimestamp
        self.startedAt = Self.isoFormatter.date(from: record.startedAt) ?? Date()
        self.endedAt = record.endedAt.flatMap(Self.isoFormatter.date(from:))
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
