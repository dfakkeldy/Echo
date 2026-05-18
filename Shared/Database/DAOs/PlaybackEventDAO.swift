import Foundation
import GRDB

struct PlaybackEventDAO {
    let db: DatabaseWriter

    func log(
        audiobookID: String,
        trackID: String?,
        startedAt: Date,
        endedAt: Date?,
        startPosition: TimeInterval,
        endPosition: TimeInterval?,
        speed: Float,
        eventType: String,
        source: String?
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_event
                    (audiobook_id, track_id, started_at, ended_at, start_position, end_position, speed, event_type, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    audiobookID, trackID,
                    startedAt.ISO8601Format(), endedAt?.ISO8601Format(),
                    startPosition, endPosition, speed,
                    eventType, source
                ]
            )
        }
    }

    func events(for audiobookID: String, limit: Int = 100) throws -> [PlaybackEvent] {
        try db.read { db in
            try PlaybackEvent
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("started_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}

/// A single playback session record.
struct PlaybackEvent: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    var trackID: String?
    var startedAt: String
    var endedAt: String?
    var startPosition: TimeInterval
    var endPosition: TimeInterval?
    var speed: Float
    var eventType: String
    var source: String?

    static let databaseTableName = "playback_event"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case trackID = "track_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case startPosition = "start_position"
        case endPosition = "end_position"
        case speed
        case eventType = "event_type"
        case source
    }
}
