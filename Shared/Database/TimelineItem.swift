import Foundation
import GRDB

enum TimelineItemType: String, Codable {
    case textSegment
    case chapterMarker
    case imageAsset
    case bookmark
    case ankiCard
}

enum GranularityLevel: Int, Codable {
    case chapter = 0
    case paragraph = 1
    case sentence = 2
    case word = 3
}

/// Materialized timeline item for the dual-path feed.
struct TimelineItem: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var itemType: TimelineItemType
    var title: String
    var subtitle: String?
    var textPayload: String?
    var imagePath: String?
    var audioStartTime: TimeInterval
    var audioEndTime: TimeInterval?
    var epubSequenceIndex: Int?
    var granularityLevel: GranularityLevel
    var playlistPosition: TimeInterval?
    var isEnabled: Bool
    var sourceTable: String?
    var sourceRowid: String?
    var metadataJSON: String?
    var createdAt: String?
    var modifiedAt: String?

    static let databaseTableName = "timeline_item"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case itemType = "item_type"
        case title, subtitle
        case textPayload = "text_payload"
        case imagePath = "image_path"
        case audioStartTime = "audio_start_time"
        case audioEndTime = "audio_end_time"
        case epubSequenceIndex = "epub_sequence_index"
        case granularityLevel = "granularity_level"
        case playlistPosition = "playlist_position"
        case isEnabled = "is_enabled"
        case sourceTable = "source_table"
        case sourceRowid = "source_rowid"
        case metadataJSON = "metadata_json"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

extension TimelineItem {
    var effectivePosition: TimeInterval {
        playlistPosition ?? audioStartTime
    }

    var isInstantaneous: Bool {
        audioEndTime == nil
    }
}

// MARK: - Legacy compatibility

extension TimelineItemType {
    /// Maps legacy item types to new unified types for migration support.
    init?(legacyRawValue: String) {
        switch legacyRawValue {
        case "track":       self = .chapterMarker
        case "chapter":     self = .chapterMarker
        case "bookmark":    self = .bookmark
        case "flashcard":   self = .ankiCard
        case "transcription": self = .textSegment
        case "note":        self = .bookmark
        default: return nil
        }
    }
}
