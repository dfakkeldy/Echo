import Foundation
import GRDB

struct TrackDAO {
    let db: DatabaseWriter

    func tracks(for audiobookID: String) throws -> [TrackRecord] {
        try db.read { db in
            try TrackRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("sort_order"))
                .fetchAll(db)
        }
    }

    func insertAll(_ tracks: [TrackRecord], audiobookID: String) throws {
        try db.write { db in
            for var track in tracks {
                try track.insert(db)
            }
        }
    }

    func updateEnabled(id: String, isEnabled: Bool) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE track SET is_enabled = ? WHERE id = ?",
                arguments: [isEnabled, id]
            )
        }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try TrackRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
