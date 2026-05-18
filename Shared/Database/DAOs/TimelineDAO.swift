import Foundation
import GRDB

struct TimelineDAO {
    let db: DatabaseWriter

    func items(for audiobookID: String) throws -> [TimelineItem] {
        try db.read { db in
            try TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .order(
                    Column("playlist_position") ?? Column("media_timestamp"),
                    Column("media_timestamp")
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
                    Column("playlist_position") ?? Column("media_timestamp")
                )
                .fetchAll(db)
        }
    }

    func items(for audiobookID: String, from startTime: TimeInterval, to endTime: TimeInterval) throws -> [TimelineItem] {
        try db.read { db in
            try TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("media_timestamp") >= startTime)
                .filter(Column("media_timestamp") <= endTime)
                .order(Column("media_timestamp"))
                .fetchAll(db)
        }
    }

    func filtered(
        audiobookID: String,
        types: Set<TimelineItemType>? = nil,
        from startTime: TimeInterval? = nil,
        to endTime: TimeInterval? = nil,
        enabledOnly: Bool = false,
        searchText: String? = nil
    ) throws -> [TimelineItem] {
        try db.read { db in
            var query = TimelineItem
                .filter(Column("audiobook_id") == audiobookID)

            if let types, !types.isEmpty {
                query = query.filter(types.map(\.rawValue).contains(Column("item_type")))
            }
            if let startTime {
                query = query.filter(Column("media_timestamp") >= startTime)
            }
            if let endTime {
                query = query.filter(Column("media_timestamp") <= endTime)
            }
            if enabledOnly {
                query = query.filter(Column("is_enabled") == true)
            }
            if let searchText, !searchText.isEmpty {
                query = query.filter(
                    Column("title").like("%\(searchText)%") ||
                    Column("subtitle").like("%\(searchText)%")
                )
            }

            return try query
                .order(
                    Column("playlist_position") ?? Column("media_timestamp"),
                    Column("media_timestamp")
                )
                .fetchAll(db)
        }
    }

    func moveItem(id: String, itemType: TimelineItemType, audiobookID: String, to newPosition: TimeInterval) throws {
        try db.write { db in
            guard let table = tableName(for: itemType) else { return }
            try db.execute(
                sql: """
                    UPDATE \(table)
                    SET playlist_position = :position
                    WHERE id = :id AND audiobook_id = :audiobookID
                    """,
                arguments: ["position": newPosition, "id": id, "audiobookID": audiobookID]
            )
        }
    }

    func removeFromPlaylist(id: String, itemType: TimelineItemType, audiobookID: String) throws {
        try db.write { db in
            guard let table = tableName(for: itemType) else { return }
            try db.execute(
                sql: "UPDATE \(table) SET playlist_position = NULL WHERE id = :id AND audiobook_id = :audiobookID",
                arguments: ["id": id, "audiobookID": audiobookID]
            )
        }
    }

    private func tableName(for type: TimelineItemType) -> String? {
        switch type {
        case .track: return "track"
        case .chapter: return "chapter"
        case .bookmark: return "bookmark"
        case .flashcard: return "flashcard"
        case .transcription: return nil
        }
    }
}
