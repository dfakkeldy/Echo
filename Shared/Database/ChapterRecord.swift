import Foundation
import GRDB

/// GRDB record for the `chapter` table.
struct ChapterRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    var title: String
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval
    var isEnabled: Bool
    var sortOrder: Int
    var playlistPosition: Double?

    static let databaseTableName = "chapter"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case title
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case isEnabled = "is_enabled"
        case sortOrder = "sort_order"
        case playlistPosition = "playlist_position"
    }
}
