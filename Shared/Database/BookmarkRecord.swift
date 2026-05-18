import Foundation
import GRDB

// MARK: - Bridging from the app-level Bookmark model

/// GRDB record for the `bookmark` table.
struct BookmarkRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var trackID: String?
    var title: String
    var mediaTimestamp: TimeInterval
    var note: String?
    var voiceMemoPath: String?
    var imagePath: String?
    var isEnabled: Bool
    var playlistPosition: Double?
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "bookmark"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case trackID = "track_id"
        case title
        case mediaTimestamp = "media_timestamp"
        case note
        case voiceMemoPath = "voice_memo_path"
        case imagePath = "image_path"
        case isEnabled = "is_enabled"
        case playlistPosition = "playlist_position"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}

// MARK: - Conversion from app-level Bookmark model (iOS only)

#if os(iOS) || os(macOS)
extension BookmarkRecord {
    init(from model: Bookmark) {
        self.id = model.id.uuidString
        self.audiobookID = model.folderKey ?? ""
        self.trackID = model.trackId
        self.title = model.title
        self.mediaTimestamp = model.timestamp
        self.note = model.note
        self.voiceMemoPath = model.voiceMemoFileName
        self.imagePath = model.bookmarkImageFileName
        self.isEnabled = model.isEnabled
        self.playlistPosition = nil
        self.createdAt = ISO8601DateFormatter().string(from: Date())
        self.modifiedAt = ISO8601DateFormatter().string(from: Date())
    }

    /// Convert to the app-level Bookmark domain model.
    func toModel() -> Bookmark {
        Bookmark(
            id: UUID(uuidString: id) ?? UUID(),
            title: title,
            folderKey: audiobookID,
            trackId: trackID,
            timestamp: mediaTimestamp,
            note: note,
            voiceMemoFileName: voiceMemoPath,
            bookmarkImageFileName: imagePath,
            isEnabled: isEnabled
        )
    }
}
#endif
