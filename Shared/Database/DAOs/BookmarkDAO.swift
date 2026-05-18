import Foundation
import GRDB

struct BookmarkDAO {
    let db: DatabaseWriter

    func bookmarks(for audiobookID: String) throws -> [BookmarkRecord] {
        try db.read { db in
            try BookmarkRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("media_timestamp"))
                .fetchAll(db)
        }
    }

    func bookmark(id: String) throws -> BookmarkRecord? {
        try db.read { db in try BookmarkRecord.fetchOne(db, key: id) }
    }

    func insert(_ bookmark: BookmarkRecord) throws {
        var bm = bookmark
        try db.write { db in try bm.insert(db) }
    }

    func update(_ bookmark: BookmarkRecord) throws {
        var bm = bookmark
        try db.write { db in try bm.save(db) }
    }

    func delete(id: String) throws {
        try db.write { db in
            try BookmarkRecord.deleteOne(db, key: id)
        }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try BookmarkRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    func count(for audiobookID: String) throws -> Int {
        try db.read { db in
            try BookmarkRecord
                .filter(Column("audiobook_id") == audiobookID)
                .fetchCount(db)
        }
    }
}
