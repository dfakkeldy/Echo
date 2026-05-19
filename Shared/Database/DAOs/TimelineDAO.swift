import Foundation
import GRDB

struct TimelineDAO {
    let db: DatabaseWriter

    // MARK: - Range query (push-driven scroll sync)

    /// Items whose [audioStartTime, audioEndTime] overlaps the given range.
    func items(in timeRange: ClosedRange<TimeInterval>,
               audiobookID: String,
               granularity: GranularityLevel? = nil) throws -> [TimelineItem] {
        try db.read { db in
            var query = TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(
                    Column("audio_start_time") <= timeRange.upperBound &&
                    (Column("audio_end_time") == nil ||
                     Column("audio_end_time") >= timeRange.lowerBound)
                )

            if let granularity {
                query = query.filter(Column("granularity_level") <= granularity.rawValue)
            }

            return try query
                .order(
                    Column("playlist_position") ?? Column("audio_start_time"),
                    Column("audio_start_time")
                )
                .fetchAll(db)
        }
    }

    // MARK: - Position-based pagination

    /// Returns a page of items after the given position, ordered by effective position.
    func feedPage(audiobookID: String,
                  after position: TimeInterval? = nil,
                  granularity: GranularityLevel? = nil,
                  limit: Int = 50) throws -> [TimelineItem] {
        try db.read { db in
            var query = TimelineItem
                .filter(Column("audiobook_id") == audiobookID)

            if let position {
                query = query.filter(
                    (Column("playlist_position") ?? Column("audio_start_time")) > position
                )
            }

            if let granularity {
                query = query.filter(Column("granularity_level") <= granularity.rawValue)
            }

            return try query
                .order(
                    Column("playlist_position") ?? Column("audio_start_time"),
                    Column("audio_start_time")
                )
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Returns a window of items centered on the given position.
    func feedWindow(audiobookID: String,
                    around position: TimeInterval,
                    granularity: GranularityLevel? = nil,
                    limit: Int = 100) throws -> [TimelineItem] {
        try db.read { db in
            // Fetch items before the position
            var beforeQuery = TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(
                    (Column("playlist_position") ?? Column("audio_start_time")) <= position
                )

            if let granularity {
                beforeQuery = beforeQuery.filter(Column("granularity_level") <= granularity.rawValue)
            }

            let before = try beforeQuery
                .order(
                    (Column("playlist_position") ?? Column("audio_start_time")).desc,
                    Column("audio_start_time").desc
                )
                .limit(limit / 2)
                .fetchAll(db)

            // Fetch items after the position
            var afterQuery = TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(
                    (Column("playlist_position") ?? Column("audio_start_time")) > position
                )

            if let granularity {
                afterQuery = afterQuery.filter(Column("granularity_level") <= granularity.rawValue)
            }

            let after = try afterQuery
                .order(
                    Column("playlist_position") ?? Column("audio_start_time"),
                    Column("audio_start_time")
                )
                .limit(limit / 2)
                .fetchAll(db)

            return before.reversed() + after
        }
    }

    // MARK: - EPUB structural ordering (alignment failure fallback)

    func items(bySequence audiobookID: String,
               from startIndex: Int? = nil,
               limit: Int? = nil) throws -> [TimelineItem] {
        try db.read { db in
            var query = TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("epub_sequence_index") != nil)
                .order(Column("epub_sequence_index"))

            if let startIndex {
                query = query.filter(Column("epub_sequence_index") >= startIndex)
            }
            if let limit {
                query = query.limit(limit)
            }

            return try query.fetchAll(db)
        }
    }

    // MARK: - Legacy query compatibility

    func items(for audiobookID: String) throws -> [TimelineItem] {
        try db.read { db in
            try TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .order(
                    Column("playlist_position") ?? Column("audio_start_time"),
                    Column("audio_start_time")
                )
                .fetchAll(db)
        }
    }

    func items(for audiobookID: String, types: Set<TimelineItemType>) throws -> [TimelineItem] {
        try db.read { db in
            try TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(types.map(\.rawValue).contains(Column("item_type")))
                .order(
                    Column("playlist_position") ?? Column("audio_start_time")
                )
                .fetchAll(db)
        }
    }

    // MARK: - Ingestion (bulk insert)

    func ingest(_ items: [TimelineItem]) throws {
        guard !items.isEmpty else { return }
        try db.write { db in
            for var item in items {
                try item.insert(db)
            }
        }
    }

    /// Delete all timeline_item rows for an audiobook (re-ingestion prep).
    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    // MARK: - User item mutations

    func insertUserItem(_ item: TimelineItem) throws {
        var mutable = item
        try db.write { db in
            try mutable.insert(db)
        }
    }

    func updateUserItem(_ item: TimelineItem) throws {
        var mutable = item
        try db.write { db in
            try mutable.update(db)
        }
    }

    func deleteUserItem(id: String, audiobookID: String) throws {
        try db.write { db in
            try TimelineItem
                .filter(Column("id") == id)
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    // MARK: - Reorder

    func moveItem(id: String, audiobookID: String, to newPosition: TimeInterval) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE timeline_item
                    SET playlist_position = :position
                    WHERE id = :id AND audiobook_id = :audiobookID
                    """,
                arguments: ["position": newPosition, "id": id, "audiobookID": audiobookID]
            )
        }
    }

    func removeFromPlaylist(id: String, audiobookID: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE timeline_item
                    SET playlist_position = NULL
                    WHERE id = :id AND audiobook_id = :audiobookID
                    """,
                arguments: ["id": id, "audiobookID": audiobookID]
            )
        }
    }
}
