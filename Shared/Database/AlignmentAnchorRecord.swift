import Foundation
import GRDB

/// A user-created or system-generated anchor point that pins an EPUB block
/// to a specific audio timestamp. Anchors are the foundation of the manual
/// alignment system — interpolation fills in timestamps between anchors.
struct AlignmentAnchorRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var epubBlockID: String
    var audioTime: TimeInterval
    var audioEndTime: TimeInterval?
    var anchorKind: String
    var source: String
    var note: String?
    var createdAt: String?
    var modifiedAt: String?

    static let databaseTableName = "alignment_anchor"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case audioTime = "audio_time"
        case audioEndTime = "audio_end_time"
        case anchorKind = "anchor_kind"
        case source
        case note
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

// MARK: - Anchor Kind Constants

extension AlignmentAnchorRecord {
    enum AnchorKind: String {
        case point = "point"
        case chapterStart = "chapterStart"
        case chapterEnd = "chapterEnd"
    }

    enum Source: String {
        case moveToNow = "moveToNow"
        case searchResult = "searchResult"
        case chapterBoundary = "chapterBoundary"
        case imported = "imported"
        case autoAlignment = "autoAlignment"
        case continuousBackground = "continuousBackground"
    }
}
