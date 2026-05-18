import Foundation

struct Note: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var audiobookID: String
    var text: String
    var mediaTimestamp: TimeInterval
    var realTimestamp: Date?
    var isEnabled: Bool
    var playlistPosition: Double?
    var createdAt: Date
    var modifiedAt: Date
}

extension Note {
    init(from record: NoteRecord) {
        self.id = record.id
        self.audiobookID = record.audiobookID
        self.text = record.text
        self.mediaTimestamp = record.mediaTimestamp
        self.realTimestamp = record.realTimestamp.flatMap(ISO8601DateFormatter().date(from:))
        self.isEnabled = record.isEnabled
        self.playlistPosition = record.playlistPosition
        self.createdAt = ISO8601DateFormatter().date(from: record.createdAt) ?? Date()
        self.modifiedAt = ISO8601DateFormatter().date(from: record.modifiedAt) ?? Date()
    }

    func toRecord() -> NoteRecord {
        NoteRecord(
            id: id,
            audiobookID: audiobookID,
            text: text,
            mediaTimestamp: mediaTimestamp,
            realTimestamp: realTimestamp?.ISO8601Format(),
            isEnabled: isEnabled,
            playlistPosition: playlistPosition,
            createdAt: createdAt.ISO8601Format(),
            modifiedAt: modifiedAt.ISO8601Format()
        )
    }
}
