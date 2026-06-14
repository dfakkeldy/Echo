import Foundation
import GRDB

/// GRDB record for the `track` table.
struct TrackRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var title: String
    var duration: TimeInterval
    var filePath: String
    var isEnabled: Bool
    var sortOrder: Int
    var playlistPosition: Double?
    /// The TTS voice that rendered this synthesized track (`narration_voice`
    /// column). `nil` marks a normal, non-synthesized audiobook track.
    var narrationVoice: String? = nil

    static let databaseTableName = "track"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case title
        case duration
        case filePath = "file_path"
        case isEnabled = "is_enabled"
        case sortOrder = "sort_order"
        case playlistPosition = "playlist_position"
        case narrationVoice = "narration_voice"
    }
}
