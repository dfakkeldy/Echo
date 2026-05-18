import Foundation
import GRDB

struct NoteRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var text: String
    var mediaTimestamp: TimeInterval
    var realTimestamp: String?
    var isEnabled: Bool
    var playlistPosition: Double?
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "note"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case text
        case mediaTimestamp = "media_timestamp"
        case realTimestamp = "real_timestamp"
        case isEnabled = "is_enabled"
        case playlistPosition = "playlist_position"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
