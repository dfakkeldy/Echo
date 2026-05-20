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

    // MARK: - V5 EPUB Alignment Fields

    /// FK to `epub_block.id` when this timeline item was materialized from an EPUB block.
    var epubBlockID: String?
    /// Source of the timestamp: none, estimated, interpolated, lockedAnchor, transcript.
    var timestampSource: String?
    /// Current alignment state: unaligned, estimated, interpolated, lockedAnchor, omitted.
    var alignmentStatus: String?
    /// Confidence score (0.0–1.0) for the current timestamp; nil when not applicable.
    var alignmentConfidence: Double?

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
        case epubBlockID = "epub_block_id"
        case timestampSource = "timestamp_source"
        case alignmentStatus = "alignment_status"
        case alignmentConfidence = "alignment_confidence"
    }
}

extension TimelineItem {
    var effectivePosition: TimeInterval {
        playlistPosition ?? audioStartTime
    }

    var isInstantaneous: Bool {
        audioEndTime == nil
    }

    /// Whether this item has a valid audio timestamp.
    /// EPUB-only content (images, footnotes, skipped text) sets `audioStartTime` to -1
    /// to indicate it has no corresponding audio. Tapping these items does not seek.
    var isTimestamped: Bool {
        audioStartTime >= 0
    }

    /// Maps the database item type to the UI-facing card type.
    var timelineCardType: TimelineCardType {
        switch itemType {
        case .textSegment:   return .textSegment
        case .chapterMarker: return .chapterMarker
        case .imageAsset:    return .imageAsset
        case .bookmark:      return .bookmark
        case .ankiCard:      return .ankiCard
        }
    }
}

// MARK: - MediaPlayable

extension TimelineItem: MediaPlayable {}

// MARK: - Alignment Enums

/// Describes how a timeline item's `audioStartTime` was determined.
enum TimestampSource: String, Codable {
    /// No timestamp available — block has no audio mapping.
    case none
    /// Rough estimate from chapter boundaries or book duration.
    case estimated
    /// Linearly interpolated between two locked anchors.
    case interpolated
    /// Explicitly set by the user (anchor locked in place).
    case lockedAnchor
    /// Derived from a transcript segment with known word-level timing.
    case transcript
}

/// Describes the alignment state of a timeline item relative to audio.
enum AlignmentStatus: String, Codable {
    /// No alignment has been performed; block is untimestamped.
    case unaligned
    /// Timestamp is estimated from chapter/duration data.
    case estimated
    /// Timestamp was interpolated between locked anchors.
    case interpolated
    /// Timestamp is locked by a user-placed anchor.
    case lockedAnchor
    /// Block has been intentionally hidden from the feed.
    case omitted
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
