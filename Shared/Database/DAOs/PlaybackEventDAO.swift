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
        speed: Double,
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

    /// Opens a listening segment as a self-consistent zero-length row.
    /// Heartbeats and finalize() extend it; a crash leaves valid data.
    func insertOpen(
        audiobookID: String,
        trackID: String?,
        startedAt: Date,
        startPosition: TimeInterval,
        speed: Double,
        source: String
    ) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_event
                    (audiobook_id, track_id, started_at, ended_at, start_position, end_position, speed, event_type, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'play', ?)
                    """,
                arguments: [
                    audiobookID, trackID,
                    startedAt.ISO8601Format(), startedAt.ISO8601Format(),
                    startPosition, startPosition, speed, source
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// Extends an open segment (heartbeat and final close use the same shape).
    func extend(id: Int64, endedAt: Date, endPosition: TimeInterval) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE playback_event SET ended_at = ?, end_position = ? WHERE id = ?",
                arguments: [endedAt.ISO8601Format(), endPosition, id]
            )
        }
    }

    /// Removes a discarded micro-segment (< minimum duration).
    func delete(id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM playback_event WHERE id = ?", arguments: [id])
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
    var speed: Double
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
