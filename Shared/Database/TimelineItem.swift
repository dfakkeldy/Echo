import Foundation
import GRDB

enum TimelineItemType: String, Codable {
    case track, chapterMarker, bookmark, ankiCard, textSegment, note, imageAsset
}

/// Controls which items appear in the feed based on playback speed.
/// Chapter-level for scrubbing (>1.5×), sentence-level for normal reading.
enum GranularityLevel: Int, Codable, Comparable {
    case chapter = 0
    case sentence = 2

    static func < (lhs: GranularityLevel, rhs: GranularityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TimelineItem: Identifiable, Equatable, MediaPlayable {
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

    /// Derived granularity based on item type. Chapter markers and tracks are
    /// chapter-level; everything else is sentence-level. Used by the feed VM
    /// to switch between dense and sparse views during scrubbing.
    var granularityLevel: GranularityLevel {
        switch itemType {
        case .track, .chapterMarker: return .chapter
        case .textSegment, .bookmark, .ankiCard, .note, .imageAsset: return .sentence
        }
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
