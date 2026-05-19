import Foundation
import GRDB

/// GRDB record for the `image_asset` table (Schema_V4).
struct ImageAssetRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var title: String?
    var imagePath: String
    var mediaTimestamp: TimeInterval
    var epubReference: String?
    var isEnabled: Bool
    var playlistPosition: Double?

    static let databaseTableName = "image_asset"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case title
        case imagePath = "image_path"
        case mediaTimestamp = "media_timestamp"
        case epubReference = "epub_reference"
        case isEnabled = "is_enabled"
        case playlistPosition = "playlist_position"
    }
}
