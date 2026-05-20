import Foundation
import GRDB

/// A user-created or auto-generated alignment anchor that locks an EPUB block
/// to a specific audio timestamp. Anchors are the fixed points that
/// interpolation uses to estimate timestamps for blocks between them.
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

extension AlignmentAnchorRecord {
    enum Kind: String {
        case point
        case chapterStart
        case chapterEnd
    }

    enum Source: String {
        case moveToNow
        case searchResult
        case chapterBoundary
        case imported
    }
}
