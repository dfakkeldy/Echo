import Foundation
import GRDB

struct RealTimeEventDAO {
    let db: DatabaseWriter

    // MARK: - Event logging

    func log(
        id: String = UUID().uuidString,
        eventType: String,
        audiobookID: String?,
        mediaTimestamp: TimeInterval?,
        startedAt: Date,
        endedAt: Date?,
        title: String?,
        subtitle: String?,
        metadataJSON: String?,
        sourceItemID: String?,
        sourceItemType: String?
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO real_time_event
                    (id, event_type, audiobook_id, media_timestamp, started_at, ended_at,
                     title, subtitle, metadata_json, source_item_id, source_item_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, eventType, audiobookID, mediaTimestamp,
                    startedAt.ISO8601Format(), endedAt?.ISO8601Format(),
                    title, subtitle, metadataJSON,
                    sourceItemID, sourceItemType
                ]
            )
        }
    }

    func updateEndedAt(id: String, endedAt: Date) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE real_time_event SET ended_at = ? WHERE id = ?",
                arguments: [endedAt.ISO8601Format(), id]
            )
        }
    }

    // MARK: - Range queries (for infinite scroll)

    /// Load events within a real-time window, ordered by started_at.
    func events(in range: ClosedRange<Date>, limit: Int = 200) throws -> [RealTimeEventRecord] {
        try db.read { db in
            try RealTimeEventRecord
                .filter(Column("started_at") >= range.lowerBound.ISO8601Format())
                .filter(Column("started_at") <= range.upperBound.ISO8601Format())
                .order(Column("started_at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Load events after a given date (for forward pagination).
    func events(after date: Date, limit: Int = 100) throws -> [RealTimeEventRecord] {
        try db.read { db in
            try RealTimeEventRecord
                .filter(Column("started_at") > date.ISO8601Format())
                .order(Column("started_at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Load events before a given date (for backward pagination).
    func events(before date: Date, limit: Int = 100) throws -> [RealTimeEventRecord] {
        try db.read { db in
            try RealTimeEventRecord
                .filter(Column("started_at") < date.ISO8601Format())
                .order(Column("started_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Load events for a specific audiobook within a real-time range.
    func events(for audiobookID: String, in range: ClosedRange<Date>, limit: Int = 200) throws -> [RealTimeEventRecord] {
        try db.read { db in
            try RealTimeEventRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("started_at") >= range.lowerBound.ISO8601Format())
                .filter(Column("started_at") <= range.upperBound.ISO8601Format())
                .order(Column("started_at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Load events of a specific type within a range.
    func events(ofType eventType: String, in range: ClosedRange<Date>, limit: Int = 200) throws -> [RealTimeEventRecord] {
        try db.read { db in
            try RealTimeEventRecord
                .filter(Column("event_type") == eventType)
                .filter(Column("started_at") >= range.lowerBound.ISO8601Format())
                .filter(Column("started_at") <= range.upperBound.ISO8601Format())
                .order(Column("started_at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Push-forward logic

    /// Advance uncompleted events whose started_at is before `now` to a new time.
    func pushForwardUncompleted(before now: Date, to newDate: Date) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE real_time_event
                    SET started_at = ?
                    WHERE ended_at IS NULL
                      AND started_at < ?
                    """,
                arguments: [newDate.ISO8601Format(), now.ISO8601Format()]
            )
        }
    }

    // MARK: - Count / Stats

    func count(in range: ClosedRange<Date>) throws -> Int {
        try db.read { db in
            try RealTimeEventRecord
                .filter(Column("started_at") >= range.lowerBound.ISO8601Format())
                .filter(Column("started_at") <= range.upperBound.ISO8601Format())
                .fetchCount(db)
        }
    }

    func count(by eventType: String, in range: ClosedRange<Date>) throws -> Int {
        try db.read { db in
            try RealTimeEventRecord
                .filter(Column("event_type") == eventType)
                .filter(Column("started_at") >= range.lowerBound.ISO8601Format())
                .filter(Column("started_at") <= range.upperBound.ISO8601Format())
                .fetchCount(db)
        }
    }
}
