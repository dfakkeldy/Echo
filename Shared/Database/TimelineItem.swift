import Foundation
import GRDB

enum TimelineItemType: String, Codable {
    case track, chapterMarker, bookmark, ankiCard, textSegment, note, imageAsset
}

struct TimelineItem: Identifiable, Equatable {
    let databaseID: String
    let audiobookID: String
    let itemType: TimelineItemType

    // MARK: Display
    let title: String
    let subtitle: String?

    // MARK: Time range
    let audioStartTime: TimeInterval
    let audioEndTime: TimeInterval?

    // MARK: Content payloads (intelligently optional)
    let textPayload: String?
    let imagePath: String?
    let epubReference: String?
    let epubSequenceIndex: Int?

    // MARK: Metadata
    let isEnabled: Bool
    let playlistPosition: TimeInterval?
    let createdAt: String?
    let modifiedAt: String?

    /// Composite identity combining item type and raw database ID so
    /// SwiftUI ForEach never conflates items from different tables.
    var id: String { "\(itemType.rawValue)-\(databaseID)" }

    var effectivePosition: TimeInterval {
        playlistPosition ?? audioStartTime
    }
}

extension TimelineItem: Codable {
    enum CodingKeys: String, CodingKey {
        case databaseID = "id"
        case audiobookID = "audiobook_id"
        case itemType = "item_type"
        case title, subtitle
        case audioStartTime = "audio_start_time"
        case audioEndTime = "audio_end_time"
        case textPayload = "text_payload"
        case imagePath = "image_path"
        case epubReference = "epub_reference"
        case epubSequenceIndex = "epub_sequence_index"
        case isEnabled = "is_enabled"
        case playlistPosition = "playlist_position"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

extension TimelineItem: FetchableRecord, TableRecord {
    static let databaseTableName = "timeline"
}
