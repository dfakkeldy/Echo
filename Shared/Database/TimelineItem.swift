import Foundation
import GRDB

enum TimelineItemType: String, Codable {
    case track, chapter, bookmark, flashcard, transcription
}

struct TimelineItem: Identifiable, Equatable {
    let id: String
    let audiobookID: String
    let itemType: TimelineItemType
    let title: String
    let subtitle: String?
    let mediaTimestamp: TimeInterval
    let isEnabled: Bool
    let playlistPosition: TimeInterval?
    let createdAt: String?
    let modifiedAt: String?

    var effectivePosition: TimeInterval {
        playlistPosition ?? mediaTimestamp
    }
}

extension TimelineItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case itemType = "item_type"
        case title, subtitle
        case mediaTimestamp = "media_timestamp"
        case isEnabled = "is_enabled"
        case playlistPosition = "playlist_position"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

extension TimelineItem: FetchableRecord, TableRecord {
    static let databaseTableName = "timeline"
}
